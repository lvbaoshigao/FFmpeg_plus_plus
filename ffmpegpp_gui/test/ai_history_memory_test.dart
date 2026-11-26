import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _HistoryFile implements File {
  _HistoryFile(this.path, this.data);
  @override
  final String path;
  final Map<String, dynamic> data;
  Stream<List<int>> Function()? summaryStream;
  Completer<String>? pendingRead;
  int fullReads = 0;
  @override
  Future<bool> exists() async => false;
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      summaryStream?.call() ?? Stream.value(utf8.encode(jsonEncode(data)));
  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    fullReads++;
    return pendingRead?.future ?? Future.value(jsonEncode(data));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HistoryDirectory implements Directory {
  _HistoryDirectory(this.path, this.file);
  @override
  final String path;
  final File file;
  @override
  Future<bool> exists() async => true;
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream.value(file);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SavedFile implements File {
  _SavedFile(this.path, this.onWrite);
  @override
  final String path;
  final void Function(String) onWrite;
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    onWrite(contents);
    return this;
  }

  @override
  Future<File> rename(String newPath) async {
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HistoryOverrides extends IOOverrides {
  _HistoryOverrides(this.file);
  final _HistoryFile file;
  Map<String, dynamic>? savedData;
  @override
  Directory createDirectory(String path) => path.endsWith('ai_history')
      ? _HistoryDirectory(path, file)
      : super.createDirectory(path);
  @override
  File createFile(String path) {
    if (path == file.path) return file;
    if (path == '${file.path}.tmp') {
      return _SavedFile(path, (text) {
        savedData = jsonDecode(text) as Map<String, dynamic>;
      });
    }
    return super.createFile(path);
  }
}

Future<AiPanelApi> _pumpPanel(WidgetTester tester) async {
  final state = AppState();
  addTearDown(state.dispose);
  AiPanelApi? api;
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: AiPanelView(
            strings: AppStrings.en,
            existingNodes: const [],
            existingConnections: const [],
            startExpanded: true,
            hideHeader: true,
            mobileSheet: true,
            onApiReady: (value) => api = value,
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
  );
  await tester.pumpAndSettle();
  return api!;
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 600));
}

Map<String, dynamic> _session() => {
  'title': 'Saved history',
  'provider': 'openai',
  'model': 'model-a',
  'total_in': 1001,
  'total_out': 1002,
  'messages': [
    {'role': 'user', 'content': 'Saved question', 'in': 1},
    {
      'role': 'assistant',
      'content': 'Saved answer',
      'out': 2,
      'blocks': [
        {'type': 'thinking', 'thinking': 'Saved reasoning'},
      ],
    },
  ],
};

void main() {
  testWidgets('closing clears loaded summaries before a pending reopen', (
    tester,
  ) async {
    final file = _HistoryFile('/virtual/session.json', _session());
    await IOOverrides.runWithIOOverrides(() async {
      await _pumpPanel(tester);
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      expect(find.text('Saved history'), findsOneWidget);
      expect(file.fullReads, 0);
      await tester.tap(find.byTooltip('Close history'));
      await tester.pumpAndSettle();
      final pending = StreamController<List<int>>();
      file.summaryStream = () => pending.stream;
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      expect(find.text('Saved history'), findsNothing);
      pending.add(utf8.encode(jsonEncode(file.data)));
      await pending.close();
      await tester.pumpAndSettle();
      expect(find.text('Saved history'), findsOneWidget);
      await _teardown(tester);
    }, _HistoryOverrides(file));
  });

  testWidgets(
    'a listing returning after close cannot refill or reopen history',
    (tester) async {
      final first = StreamController<List<int>>();
      final second = StreamController<List<int>>();
      final file = _HistoryFile('/virtual/session.json', _session());
      var opens = 0;
      file.summaryStream = () => ++opens == 1 ? first.stream : second.stream;
      await IOOverrides.runWithIOOverrides(() async {
        await _pumpPanel(tester);
        await tester.tap(find.byTooltip('History'));
        await tester.pumpAndSettle();
        expect(opens, 1);
        await tester.tap(find.byTooltip('Close history'));
        await tester.pumpAndSettle();
        first.add(utf8.encode(jsonEncode(file.data)));
        await tester.pumpAndSettle();
        unawaited(first.close());
        expect(find.byKey(const ValueKey('ai-mobile-sidebar')), findsNothing);
        await tester.tap(find.byTooltip('History'));
        await tester.pumpAndSettle();
        expect(opens, 2);
        expect(find.text('Saved history'), findsNothing);
        second.add(utf8.encode(jsonEncode(file.data)));
        await second.close();
        await tester.pumpAndSettle();
        expect(find.text('Saved history'), findsOneWidget);
        await _teardown(tester);
      }, _HistoryOverrides(file));
    },
  );

  testWidgets('selection loads the body on demand and ignores stale imports', (
    tester,
  ) async {
    final file = _HistoryFile('/virtual/session.json', _session());
    await IOOverrides.runWithIOOverrides(() async {
      final api = await _pumpPanel(tester);
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      expect(file.fullReads, 0);
      expect(api.exportMessages(), isEmpty);
      file.pendingRead = Completer<String>();
      await tester.tap(find.text('Saved history'));
      await tester.pumpAndSettle();
      expect(file.fullReads, 1);
      api.importMessages([
        {'role': 'user', 'content': 'New handoff'},
      ]);
      file.pendingRead!.complete(jsonEncode(file.data));
      await tester.pumpAndSettle();
      expect(api.exportMessages().single['content'], 'New handoff');
      file.pendingRead = null;
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved history'));
      await tester.pumpAndSettle();
      expect(api.exportMessages().map((m) => m['content']), [
        'Saved question',
        'Saved answer',
      ]);
      expect(find.byKey(const ValueKey('ai-mobile-sidebar')), findsNothing);
      api.importMessages([]);
      await _teardown(tester);
    }, _HistoryOverrides(file));
  });

  testWidgets(
    'renaming a summary preserves the saved messages and total tokens',
    (tester) async {
      final file = _HistoryFile('/virtual/session.json', _session());
      final overrides = _HistoryOverrides(file);
      await IOOverrides.runWithIOOverrides(() async {
        await _pumpPanel(tester);
        await tester.tap(find.byTooltip('History'));
        await tester.pumpAndSettle();
        expect(file.fullReads, 0);
        await tester.tap(find.byTooltip('Session actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(field, 'Renamed history');
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(file.fullReads, 1);
        expect(overrides.savedData, isNotNull);
        final saved = overrides.savedData!;
        expect(saved['title'], 'Renamed history');
        expect(saved['messages'], file.data['messages']);
        expect(saved['total_in'], 1001);
        expect(saved['total_out'], 1002);
        await _teardown(tester);
      }, overrides);
    },
  );
}
