import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/services/pipeline_autosave.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/adaptive_top_bar.dart';
import 'package:ffmpegpp_gui/widgets/mobile_top_bar.dart';
import 'package:ffmpegpp_gui/widgets/mobile_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _toolbarKey = ValueKey('editor-desktop-toolbar');
const _formatKey = ValueKey('editor-desktop-write-format');
const _saveKey = ValueKey('editor-desktop-save');
const _probeTooltip = 'Probe: hover ports to inspect signals';
const _logicTooltip = 'Hide logic (control wires, gates, logic ports)';
typedef _Geometry = ({double width, double textScale});

class _MemoryConfig extends ConfigService {
  AppConfig _config = AppConfig();

  @override
  AppConfig get config => _config;

  @override
  Future<void> update(AppConfig Function(AppConfig) transform) async {
    _config = transform(_config);
  }

  @override
  Future<void> flush() async {}

  @override
  void dispose() {}
}

class _TestState extends AppState {
  final _memoryConfig = _MemoryConfig();

  @override
  ConfigService get configService => _memoryConfig;
}

class _CancelPicker extends FilePickerPlatform {
  int calls = 0;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    return null;
  }
}

final class _DraftDirectoryIO extends IOOverrides {
  _DraftDirectoryIO(this.directory);

  final Directory directory;
  @override
  Directory createDirectory(String path) =>
      path.endsWith('${Platform.pathSeparator}pipeline_autosave')
      ? directory
      : super.createDirectory(path);
}

class _Harness {
  final geometry = ValueNotifier<_Geometry>((width: 1600, textScale: 1));
  final saved = <PipelineGraph>[];
}

Future<_Harness> _mount(
  WidgetTester tester, {
  String language = 'en',
  bool autosave = false,
}) async {
  tester.view.physicalSize = const Size(2000, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final harness = _Harness();
  final state = _TestState();
  state.config
    ..language = language
    ..aiEnabled = false
    ..autosaveEnabled = autosave
    ..nodeMiniMap = false
    ..menuStyle = 'gray'
    ..cardStyle = 'gray'
    ..pillStyle = 'gray';
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
    harness.geometry.dispose();
    state.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(glassEffect: 'none'),
        builder: (context, child) => ValueListenableBuilder<_Geometry>(
          valueListenable: harness.geometry,
          child: child,
          builder: (context, geometry, child) => Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: geometry.width,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(geometry.textScale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
            ),
          ),
        ),
        home: Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () =>
                  Navigator.of(tester.element(find.text('Open editor'))).push(
                    MaterialPageRoute<void>(
                      allowSnapshotting: false,
                      builder: (_) => PipelineEditorPage(
                        video: VideoFile(
                          id: 'desktop-toolbar',
                          filename: 'Template',
                          filepath: autosave
                              ? '/missing/autosave-test.mp4'
                              : '',
                        ),
                        onSave: harness.saved.add,
                      ),
                    ),
                  ),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await _layout(tester);
  return harness;
}

Future<void> _layout(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Finder get _toolbar => find.byKey(_toolbarKey);
Finder get _format => find.byKey(_formatKey);
Finder get _save => find.byKey(_saveKey);
Finder _canvasBar() => find
    .ancestor(
      of: find.text('Node Editor'),
      matching: find.byType(AppTopBarLayout),
    )
    .first;

Future<void> _canvasWidth(
  WidgetTester tester,
  _Harness harness,
  double width, {
  double textScale = 1,
}) async {
  // Re-measure after each resize: window chrome and panel minimums can
  // otherwise round an expanded breakpoint just below the requested width.
  for (var attempt = 0; attempt < 4; attempt++) {
    final current = tester.getSize(_canvasBar()).width;
    final fraction = current / harness.geometry.value.width;
    harness.geometry.value = (
      width: harness.geometry.value.width + (width + 0.05 - current) / fraction,
      textScale: textScale,
    );
    await _layout(tester);
    if ((tester.getSize(_canvasBar()).width - width - 0.05).abs() < 0.01) break;
  }
}

IconButton _icon(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      ),
    );

void main() {
  const channel = MethodChannel('window_manager');
  bool? previousMobile;
  setUp(() {
    previousMobile = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);
  });
  tearDown(() {
    debugIsMobilePlatformOverride = previousMobile;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'expanded toolbar groups consistent targets and localizes format',
    (tester) async {
      await _mount(tester, language: 'zh');
      expect(find.text('旧版'), findsOneWidget);
      expect(find.text('legacy'), findsNothing);
      expect(
        find.byKey(const ValueKey('editor-desktop-edit-actions')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-desktop-view-actions')),
        findsOneWidget,
      );
      final buttons = find.descendant(
        of: _toolbar,
        matching: find.byType(IconButton),
      );
      for (final element in buttons.evaluate()) {
        final size = tester.getSize(find.byWidget(element.widget));
        expect(size.width, inInclusiveRange(32, 36));
        expect(size.height, inInclusiveRange(32, 36));
      }
      expect(tester.getSize(_format).height, inInclusiveRange(32, 36));
      if (!Platform.isWindows) {
        expect(
          find.descendant(of: _save, matching: find.text('保存')),
          findsOneWidget,
        );
        expect(
          tester.getRect(_format).right,
          lessThan(tester.getRect(_save).left),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('format chip updates the actual export dialog selection', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(_format);
    await _layout(tester);
    expect(find.text('New Beta'), findsOneWidget);
    await tester.tap(find.byTooltip('Export Config'));
    await _layout(tester);
    final selector = find.byType(SegmentedButton<String>);
    expect(tester.widget<SegmentedButton<String>>(selector).selected, {'v2'});
    await tester.tap(find.text('Legacy (JSON)'));
    await _layout(tester);
    await tester.tap(find.text('Cancel'));
    await _layout(tester);
    expect(
      find.descendant(of: _format, matching: find.text('Legacy')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'probe and logic toggles retain state through compact transitions',
    (tester) async {
      final harness = await _mount(tester);
      expect(_icon(tester, _probeTooltip).isSelected, isFalse);
      expect(_icon(tester, _logicTooltip).isSelected, isFalse);
      await tester.tap(find.byTooltip(_probeTooltip));
      await tester.tap(find.byTooltip(_logicTooltip));
      await _layout(tester);
      expect(_icon(tester, _probeTooltip).isSelected, isTrue);
      expect(_icon(tester, _logicTooltip).isSelected, isTrue);
      final canvasState = tester.state(find.byType(InteractiveViewer));
      await _canvasWidth(tester, harness, 599);
      expect(
        find.byType(
          Platform.isWindows ? MobilePillTopBar : MobileSubPageTopBar,
        ),
        findsOneWidget,
      );
      await _canvasWidth(tester, harness, 600);
      expect(_icon(tester, _probeTooltip).isSelected, isTrue);
      expect(_icon(tester, _logicTooltip).isSelected, isTrue);
      expect(tester.state(find.byType(InteractiveViewer)), same(canvasState));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'undo and redo still move a dragged node through toolbar actions',
    (tester) async {
      await _mount(tester);
      expect(_icon(tester, 'Undo').onPressed, isNull);
      final nodes = find.descendant(
        of: find.byType(InteractiveViewer),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('node-'),
        ),
      );
      final node = find.byKey(nodes.first.evaluate().single.widget.key!);
      final before = tester.getTopLeft(node);
      await tester.dragFrom(
        before + const Offset(65, 16),
        const Offset(50, 30),
      );
      await _layout(tester);
      final moved = tester.getTopLeft(node);
      expect((moved - before).distance, greaterThan(1));
      expect(_icon(tester, 'Undo').onPressed, isNotNull);
      await tester.tap(find.byTooltip('Undo'));
      await _layout(tester);
      expect((tester.getTopLeft(node) - before).distance, lessThan(1));
      await tester.tap(find.byTooltip('Redo'));
      await _layout(tester);
      expect((tester.getTopLeft(node) - moved).distance, lessThan(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('undo and redo update an already persisted draft', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('editor_undo_draft_'),
    ))!;
    addTearDown(() => tester.runAsync(() => directory.delete(recursive: true)));
    await IOOverrides.runWithIOOverrides(() async {
      await _mount(tester, autosave: true);
      final state = tester
          .element(find.byType(PipelineEditorPage))
          .read<AppState>();
      expect(state.config.autosaveEnabled, isTrue);
      final editor = tester.widget<PipelineEditorPage>(
        find.byType(PipelineEditorPage),
      );
      expect(editor.video.filepath, isNotEmpty);
      final nodeId = state.mcpOnAddNode!('avProcess', 3000, 3000);

      Future<int?> persistedCrf(int expected) async {
        int? actual;
        for (var attempt = 0; attempt < 100; attempt++) {
          // Real IO completions enqueue continuations in the fake widget zone.
          // Alternate the real event loop and pump so pending saves can finish.
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          actual = await tester.runAsync<int?>(() async {
            final json = await PipelineAutosave.load('video:desktop-toolbar');
            if (json == null) return null;
            final node = PipelineGraph.fromJson(
              json,
            ).nodes.where((node) => node.id == nodeId).firstOrNull;
            return node?.params['crf'] as int?;
          });
          if (actual == expected) return actual;
        }
        return actual;
      }

      expect(state.mcpOnModifyNode!(nodeId, {'crf': 23}), isTrue);
      await _layout(tester);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(await persistedCrf(23), 23);

      expect(state.mcpOnModifyNode!(nodeId, {'crf': 31}), isTrue);
      await _layout(tester);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(await persistedCrf(31), 31);

      await tester.tap(find.byTooltip('Undo'));
      await _layout(tester);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(await persistedCrf(23), 23);

      await tester.tap(find.byTooltip('Redo'));
      await _layout(tester);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(await persistedCrf(31), 31);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(tester.takeException(), isNull);
    }, _DraftDirectoryIO(directory));
  });

  testWidgets(
    'format and primary save stay reachable at expanded width limits',
    (tester) async {
      final harness = await _mount(tester);
      for (final scenario in [
        (width: 600.0, scale: 1.0),
        (width: 900.0, scale: 1.5),
      ]) {
        await _canvasWidth(
          tester,
          harness,
          scenario.width,
          textScale: scenario.scale,
        );
        final bounds = tester.getRect(_toolbar);
        expect(_format.hitTestable(), findsOneWidget);
        if (!Platform.isWindows) {
          expect(_save.hitTestable(), findsOneWidget);
          expect(tester.getRect(_save).right, lessThanOrEqualTo(bounds.right));
          expect(
            tester.getRect(_format).right,
            lessThan(tester.getRect(_save).left),
          );
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'compact actions preserve import cancellation and the real save callback',
    (tester) async {
      final harness = await _mount(tester);
      final previousPicker = FilePickerPlatform.instance;
      final picker = _CancelPicker();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previousPicker);
      await _canvasWidth(tester, harness, 599);
      await tester.tap(find.byTooltip('More actions'));
      await _layout(tester);
      await tester.ensureVisible(_format);
      await tester.tap(_format);
      await _layout(tester);
      expect(
        find.descendant(of: _format, matching: find.text('New Beta')),
        findsOneWidget,
      );
      final importAction = find.byTooltip('Load Config');
      await tester.ensureVisible(importAction);
      await tester.tap(importAction);
      await _layout(tester);
      expect(picker.calls, 1);
      expect(find.byType(PipelineEditorPage), findsOneWidget);
      if (!Platform.isWindows) {
        await tester.ensureVisible(_save);
        await tester.tap(_save);
      } else {
        await tester.tap(find.byTooltip('Save'));
      }
      await _layout(tester);
      expect(harness.saved, hasLength(1));
      expect(harness.saved.single.nodes, hasLength(2));
      expect(harness.saved.single.connections, hasLength(1));
      expect(find.byType(PipelineEditorPage), findsNothing);
      expect(find.text('Open editor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
