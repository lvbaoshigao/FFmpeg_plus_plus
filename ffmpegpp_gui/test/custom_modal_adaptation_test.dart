import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/quick_config_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_alert_dialog.dart';
import 'package:ffmpegpp_gui/widgets/font_picker.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/image_crop_dialog.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/video_crop_step_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> _host(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(320, 640),
  double scale = 1.8,
  double keyboard = 0,
  AppState? state,
  ValueNotifier<double>? scaleController,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  Widget app = MaterialApp(
    theme: AppTheme.dark(),
    builder: (context, child) {
      Widget scaled(double value) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(value)),
        child: child!,
      );
      return scaleController == null
          ? scaled(scale)
          : ValueListenableBuilder<double>(
              valueListenable: scaleController,
              builder: (_, value, _) => scaled(value),
            );
    },
    home: Scaffold(body: child),
  );
  if (state != null) {
    app = ChangeNotifierProvider<AppState>.value(value: state, child: app);
  }
  await tester.pumpWidget(app);
}

void _expectPill(WidgetTester tester, String label) {
  final action = find.ancestor(
    of: find.text(label),
    matching: find.byType(AppDialogAction),
  );
  expect(action, findsOneWidget);
  expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
}

QuickConfig _serialModalConfig() => QuickConfig(
  id: 'serial',
  name: 'Audio settings',
  fileType: QuickFileType.audio,
  nodes: [
    PipelineNode(
      id: 'first',
      type: PipelineStepType.audioQuality,
      params: {'bitrate_mode': 'custom', 'audio_bitrate': 128},
    ),
    PipelineNode(
      id: 'second',
      type: PipelineStepType.audioQuality,
      params: {'bitrate_mode': 'custom', 'audio_bitrate': 192},
    ),
  ],
);

Future<void> _expectQuickReachable(
  WidgetTester tester,
  Finder finder,
  double bottom,
) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(bottom));
}

Future<void> _cacheImage(WidgetTester tester, Iterable<int> widths) async {
  final context = tester.element(find.byType(Scaffold));
  await tester.runAsync(() async {
    for (final width in widths) {
      await precacheImage(
        ResizeImage(FileImage(File('rele/icon.png').absolute), width: width),
        context,
      );
    }
  });
}

void main() {
  testWidgets(
    'font picker remains dismissible with a keyboard and large text',
    (tester) async {
      await _host(
        tester,
        FontPicker(currentFont: 'Arial', onSelected: (_) {}, language: 'en'),
        size: const Size(320, 560),
        keyboard: 220,
      );
      await tester.tap(find.byType(FontPicker));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      _expectPill(tester, 'Cancel');
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets('quick wizard keeps actions reachable in a narrow viewport', (
    tester,
  ) async {
    final state = AppState()..config.language = 'en';
    addTearDown(state.dispose);
    await _host(
      tester,
      QuickConfigPage(
        config: QuickConfig(
          id: 'empty',
          fileType: QuickFileType.audio,
          nodes: [],
        ),
        onSave: (_) async {},
      ),
      state: state,
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final key in ['quick_save', 'quick_close']) {
      final action = find.byKey(ValueKey(key));
      await tester.ensureVisible(action);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
      expect(action.hitTestable(), findsOneWidget);
    }
  });

  testWidgets(
    'quick wizard keeps nodes, editing and actions reachable with large text and IME',
    (tester) async {
      final state = AppState()..config.language = 'en';
      addTearDown(state.dispose);
      QuickConfig? saved;
      await _host(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<QuickConfig>(
              context: context,
              barrierDismissible: false,
              builder: (_) => QuickConfigPage(
                config: _serialModalConfig(),
                onSave: (config) async => saved = config,
              ),
            ),
            child: const Text('Open editor'),
          ),
        ),
        state: state,
        size: const Size(320, 560),
        scale: 2.6,
        keyboard: 300,
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('quick_compact_scroll')),
        findsOneWidget,
      );
      await _expectQuickReachable(
        tester,
        find.text('Quick configuration'),
        260,
      );
      await _expectQuickReachable(
        tester,
        find.byKey(const ValueKey('quick_save')),
        260,
      );
      await _expectQuickReachable(
        tester,
        find.byKey(const ValueKey('quick_close')),
        260,
      );

      final catalog = find.text('Available nodes');
      await _expectQuickReachable(tester, catalog, 260);
      final second = find.byKey(const ValueKey('quick_node_second'));
      await _expectQuickReachable(tester, second, 260);
      await tester.tap(second);
      await tester.pumpAndSettle();
      final field = find.byType(TextField).first;
      expect(tester.widget<TextField>(field).controller!.text, '192');
      await _expectQuickReachable(tester, field, 260);
      await tester.enterText(field, '256');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final save = find.byKey(const ValueKey('quick_save'));
      await _expectQuickReachable(tester, save, 260);
      expect(tester.widget<OutlinedButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved!.nodes![0].params['audio_bitrate'], 128);
      expect(saved!.nodes![1].params['audio_bitrate'], 256);
      expect(find.byType(QuickConfigPage), findsNothing);

      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      final close = find.byKey(const ValueKey('quick_close'));
      await _expectQuickReachable(tester, close, 260);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(QuickConfigPage), findsNothing);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'quick wizard stays editable with a short keyboard viewport at $scale',
      (tester) async {
        final state = AppState()..config.language = 'en';
        addTearDown(state.dispose);
        await _host(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<QuickConfig>(
                context: context,
                barrierDismissible: false,
                builder: (_) => QuickConfigPage(
                  config: _serialModalConfig(),
                  onSave: (_) async {},
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
          state: state,
          size: const Size(390, 640),
          keyboard: 300,
          scale: scale,
        );
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _expectQuickReachable(
          tester,
          find.byKey(const ValueKey('quick_save')),
          340,
        );
        final second = find.byKey(const ValueKey('quick_node_second'));
        await _expectQuickReachable(tester, second, 340);
        await tester.tap(second);
        await tester.pumpAndSettle();
        final field = find.byType(TextField).first;
        expect(tester.widget<TextField>(field).controller!.text, '192');
        await _expectQuickReachable(tester, field, 340);
        await tester.enterText(field, '224');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final save = find.byKey(const ValueKey('quick_save'));
        await _expectQuickReachable(tester, save, 340);
        expect(tester.widget<OutlinedButton>(save).onPressed, isNotNull);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.byType(QuickConfigPage), findsNothing);
      },
    );
  }

  testWidgets(
    'image crop keeps source coordinates and touch-sized paired actions',
    (tester) async {
      debugIsMobilePlatformOverride = true;
      addTearDown(() => debugIsMobilePlatformOverride = null);
      Rect? result;
      await _host(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showImageCropDialog(
              context,
              imagePath: File('rele/icon.png').absolute.path,
              imageSize: const Size(1920, 1080),
              initialRect: const Rect.fromLTWH(0, 0, 1920, 1080),
              isZh: false,
            ),
            child: const Text('Open crop'),
          ),
        ),
      );
      await _cacheImage(tester, [320]);
      await tester.tap(find.text('Open crop'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      _expectPill(tester, 'Cancel');
      _expectPill(tester, 'Apply');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(result, const Rect.fromLTWH(0, 0, 1920, 1080));
    },
  );

  testWidgets('video crop adapts its header and action rows to large text', (
    tester,
  ) async {
    final path = File('rele/icon.png').absolute.path;
    final scale = ValueNotifier<double>(1);
    final params = <String, dynamic>{};
    addTearDown(scale.dispose);
    await _host(
      tester,
      VideoCropStepEditor(
        params: params,
        onChanged: () {},
        videoPath: 'test.mp4',
        videoWidth: 1920,
        videoHeight: 1080,
        fps: 30,
        isZh: false,
        generatePreview: (_, _, {width = 480}) async => path,
        generateFullFrame: (_, _) async => path,
      ),
      size: const Size(390, 844),
      scale: 1,
      scaleController: scale,
    );
    await _cacheImage(tester, [960, 351]);
    await tester.tap(find.text('Extract'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Selection Tool'));
    await tester.pumpAndSettle();
    scale.value = 1.8;
    await tester.pump();

    expect(tester.takeException(), isNull);
    _expectPill(tester, 'Cancel');
    _expectPill(tester, 'Save');
  });
}
