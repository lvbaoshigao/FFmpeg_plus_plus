import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _longTitle =
    'Review a very long video conversion conversation with multiple output formats and preserved audio tracks';
const _longModel = 'a-very-long-provider-model-name-with-a-version-and-suffix';

class _SessionFile implements File {
  _SessionFile(this.path, this.data);

  @override
  final String path;
  Map<String, dynamic> data;
  int fullReads = 0;

  @override
  Future<bool> exists() async => true;

  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      Stream.value(utf8.encode(jsonEncode(data)));

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    fullReads++;
    return jsonEncode(data);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HistoryDirectory implements Directory {
  _HistoryDirectory(this.path, this.files);

  @override
  final String path;
  final List<_SessionFile> files;

  @override
  Future<bool> exists() async => true;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream.fromIterable(files);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TemporaryFile implements File {
  _TemporaryFile(this.path, this.files);

  @override
  final String path;
  final List<_SessionFile> files;
  String? contents;

  @override
  Future<File> writeAsString(
    String text, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    contents = text;
    return this;
  }

  @override
  Future<File> rename(String newPath) async {
    final saved = jsonDecode(contents!) as Map<String, dynamic>;
    final file = files.firstWhere((file) => file.path == newPath);
    file.data = saved;
    return file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HistoryOverrides extends IOOverrides {
  _HistoryOverrides(this.files);

  final List<_SessionFile> files;

  @override
  Directory createDirectory(String path) => path.endsWith('ai_history')
      ? _HistoryDirectory(path, files)
      : super.createDirectory(path);

  @override
  File createFile(String path) {
    for (final file in files) {
      if (path == file.path) return file;
    }
    if (path.endsWith('.json.tmp')) return _TemporaryFile(path, files);
    return super.createFile(path);
  }
}

_SessionFile _session(int index, {String? title, String model = _longModel}) =>
    _SessionFile('/virtual/session_${1700000000000 + index}.json', {
      'title': title ?? 'Session $index',
      'provider': 'openai',
      'model': model,
      'messages': [
        {'role': 'user', 'content': 'Saved question $index'},
        {'role': 'assistant', 'content': 'Saved answer $index'},
      ],
    });

Future<void> _mount(
  WidgetTester tester, {
  double width = 440,
  double height = 600,
  double textScale = 1,
  bool mobile = false,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState()..config.language = 'en';
  addTearDown(state.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: height,
              child: AiPanelView(
                strings: AppStrings.en,
                existingNodes: const [],
                existingConnections: const [],
                startExpanded: true,
                hideHeader: false,
                mobileSheet: mobile,
                onApplyGraph: (_, connections) {},
                onMergeGraph: (_, connections) {},
                onModifyNodeParams: (_, params) => true,
                onClearAll: () {},
                onUndo: () {},
                onRedo: () {},
                onSave: () {},
                onAddNode: (_, x, y) => 'node',
                onAddGate: (_, x, y) => 'gate',
                onSetGateParams: (_, params) => true,
                onDeleteNode: (_) {},
                onConnectNodes: (_, to) => true,
                onDisconnectNodes: (_) => true,
                onCancelTasks: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _openHistory(tester);
}

Future<void> _openHistory(WidgetTester tester) async {
  await tester.tap(find.byTooltip('History'));
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 600));
}

Finder get _desktopSidebar => find.byKey(const ValueKey('ai-desktop-history'));
Finder get _desktopList =>
    find.byKey(const ValueKey('ai-desktop-history-list'));

void main() {
  setUp(() => debugIsMobilePlatformOverride = false);
  tearDown(() => debugIsMobilePlatformOverride = null);

  for (final brightness in Brightness.values) {
    testWidgets('desktop history is opaque and grouped in $brightness', (
      tester,
    ) async {
      await IOOverrides.runWithIOOverrides(() async {
        await _mount(tester, brightness: brightness);
        final surface = tester.widget<Material>(_desktopSidebar);
        final scheme = Theme.of(tester.element(_desktopSidebar)).colorScheme;
        expect(surface.color, scheme.surfaceContainerLow);
        expect(surface.color!.a, 1);
        expect(surface.clipBehavior, Clip.antiAlias);
        expect(tester.getSize(_desktopSidebar).width, 288);
        expect(
          find.descendant(
            of: _desktopSidebar,
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        expect(
          find.descendant(of: _desktopSidebar, matching: find.byType(Divider)),
          findsOneWidget,
        );
        expect(find.text('No history yet'), findsOneWidget);
        expect(find.byTooltip('History actions').hitTestable(), findsOneWidget);
        expect(find.byTooltip('Close history').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      }, _HistoryOverrides([]));
    });
  }

  testWidgets(
    'long desktop titles stay compact with separate reachable actions',
    (tester) async {
      final session = _session(0, title: _longTitle);
      await IOOverrides.runWithIOOverrides(() async {
        await _mount(tester);
        final titleFinder = find.text(_longTitle);
        final title = tester.widget<Text>(titleFinder);
        final tile = find.ancestor(
          of: titleFinder,
          matching: find.byType(ListTile),
        );
        final action = find.byTooltip('Session actions');
        expect(title.maxLines, 1);
        expect(title.overflow, TextOverflow.ellipsis);
        expect(
          tester.renderObject<RenderParagraph>(titleFinder).didExceedMaxLines,
          isTrue,
        );
        expect(find.byTooltip(_longTitle), findsOneWidget);
        expect(tester.getSize(tile).height, lessThanOrEqualTo(60));
        expect(
          tester.getRect(titleFinder).right,
          lessThan(tester.getRect(action).left),
        );
        expect(action.hitTestable(), findsOneWidget);
        expect(session.fullReads, 0);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.text('Rename'), findsOneWidget);
        expect(find.text('Delete chat'), findsOneWidget);
        expect(_desktopSidebar, findsOneWidget);
        expect(session.fullReads, 0);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      }, _HistoryOverrides([session]));
    },
  );

  testWidgets(
    'narrow desktop history supports large text without covering dismiss area',
    (tester) async {
      await IOOverrides.runWithIOOverrides(() async {
        await _mount(tester, width: 300, textScale: 2);
        final sidebar = tester.getRect(_desktopSidebar);
        final panel = tester.getRect(find.byType(AiPanelView));
        expect(sidebar.right, lessThanOrEqualTo(panel.right - 24));
        expect(find.byTooltip('Session actions').hitTestable(), findsOneWidget);
        expect(find.byTooltip('Close history').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tapAt(Offset(panel.right - 8, sidebar.center.dy));
        await tester.pumpAndSettle();
        expect(_desktopSidebar, findsNothing);
        await _unmount(tester);
      }, _HistoryOverrides([_session(0, title: _longTitle)]));
    },
  );

  testWidgets(
    'scrolling long history keeps its heading and close action fixed',
    (tester) async {
      await IOOverrides.runWithIOOverrides(() async {
        await _mount(tester, height: 480);
        final heading = find.byKey(
          const ValueKey('ai-desktop-history-heading'),
        );
        final before = tester.getRect(heading);
        await tester.drag(_desktopList, const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(find.text('Session 0').hitTestable(), findsOneWidget);
        expect(tester.getRect(heading), before);
        expect(find.byTooltip('Close history').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      }, _HistoryOverrides(List.generate(25, _session)));
    },
  );

  testWidgets(
    'loading a session closes history and highlights it when reopened',
    (tester) async {
      await IOOverrides.runWithIOOverrides(() async {
        await _mount(tester);
        await tester.tap(find.text('Session 0'));
        await tester.pumpAndSettle();
        expect(_desktopSidebar, findsNothing);
        expect(find.text('Saved question 0'), findsOneWidget);
        await _openHistory(tester);
        final tileFinder = find.ancestor(
          of: find.text('Session 0'),
          matching: find.byType(ListTile),
        );
        final tile = tester.widget<ListTile>(tileFinder);
        final scheme = Theme.of(tester.element(tileFinder)).colorScheme;
        final title = tester.widget<Text>(find.text('Session 0'));
        expect(tile.selected, isTrue);
        expect(tile.selectedTileColor, scheme.secondaryContainer);
        expect(title.style!.color, scheme.onSecondaryContainer);
        expect(title.style!.fontWeight, FontWeight.w600);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      }, _HistoryOverrides([_session(0)]));
    },
  );

  testWidgets(
    'mobile history retains two-line titles and touch-sized actions',
    (tester) async {
      await IOOverrides.runWithIOOverrides(() async {
        await _mount(tester, width: 360, mobile: true);
        final title = tester.widget<Text>(find.text(_longTitle));
        final action = find.byTooltip('Session actions');
        expect(title.maxLines, 2);
        expect(tester.getSize(action), const Size(44, 44));
        expect(_desktopSidebar, findsNothing);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      }, _HistoryOverrides([_session(0, title: _longTitle)]));
    },
  );
}
