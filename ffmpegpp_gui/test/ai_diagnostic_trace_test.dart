import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Real SDK + loopback HTTP: exercise request ownership, stream aggregation and
// tool/continuation branches, without exposing a test-only API on the page.
class _AiServer {
  _AiServer(this.server);
  final HttpServer server;
  final release = Completer<void>();
  int streams = 0;
  int completions = 0;
  int requests = 0;
  final _outputReady = <int, Completer<void>>{};

  Future<void> waitForOutput(int request) =>
      (_outputReady[request] ??= Completer<void>()).future;

  void markOutput(int request) {
    final ready = _outputReady[request] ??= Completer<void>();
    if (!ready.isCompleted) ready.complete();
  }
  bool hold = false;
  bool tools = false;
  bool continuation = false;
  bool fail = false;
  bool holdTitle = false;

  String get url => 'http://127.0.0.1:${server.port}/private-endpoint';

  Future<void> handle(HttpRequest request) async {
    final requestNumber = ++requests;
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    final response = request.response;
    if (fail) {
      response.statusCode = 401;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'error': {'message': 'PRIVATE_ERROR_KEY_PATH'},
        }),
      );
      await response.close();
      markOutput(requestNumber);
      return;
    }
    if (body['stream'] != true) {
      completions++;
      if (holdTitle) await release.future;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'id': 'private-response-id',
          'created': 1,
          'model': 'PRIVATE_MODEL',
          'choices': [
            {
              'message': {
                'content': tools ? '' : 'PRIVATE_TITLE',
                if (tools)
                  'tool_calls': [
                    for (final action in [
                      'add_node',
                      'connect_nodes',
                      'PRIVATE_TOOL',
                    ])
                      {
                        'id': 'private-$action',
                        'type': 'function',
                        'function': {
                          'name': 'pipeline_tool',
                          'arguments': jsonEncode({
                            'action': action,
                            'arguments': action == 'add_node'
                                ? ['avProcess']
                                : ['private-a', 'private-b'],
                          }),
                        },
                      },
                  ],
              },
              'finish_reason': tools ? 'tool_calls' : 'stop',
            },
          ],
        }),
      );
      await response.close();
      markOutput(requestNumber);
      return;
    }
    streams++;
    response.headers.contentType = ContentType('text', 'event-stream');
    response.bufferOutput = false;
    void chunk(Map<String, Object?> delta, [String? finish]) {
      response.write(
        'data: ${jsonEncode({
          'choices': [
            {'delta': delta, 'finish_reason': finish},
          ],
        })}\n\n',
      );
    }

    if (tools && streams == 1) {
      chunk({
        'tool_calls': [
          {
            'function': {'arguments': '{}'},
          },
        ],
      });
      chunk({}, 'tool_calls');
    } else {
      for (var i = 0; i < 8; i++) {
        chunk({'content': 'x' * 10});
      }
      await response.flush();
      markOutput(requestNumber);
      if (hold) await release.future;
      chunk({}, continuation && streams == 1 ? 'length' : 'stop');
    }
    response.write('data: [DONE]\n\n');
    await response.close();
    markOutput(requestNumber);
  }

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  }
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < const Duration(seconds: 30)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(
    condition(),
    isTrue,
    reason: 'AI request did not reach the expected state',
  );
}

List<String> _trace(AppState state) => state.logEntries
    .where((entry) => entry.category == 'trace')
    .map((entry) => entry.message)
    .toList();

Future<void> _mount(
  WidgetTester tester,
  AppState state, {
  VoidCallback? onAdd,
}) async {
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
            initialMessages: const [
              {
                'role': 'user',
                'content': 'PRIVATE_HISTORY',
                'blocks': [
                  {
                    'type': 'attachment',
                    'name': 'PRIVATE_FILE',
                    'path': 'PRIVATE_PATH',
                    'size': 12,
                    'mimeType': 'application/octet-stream',
                  },
                ],
              },
              {'role': 'assistant', 'content': 'PRIVATE_ANSWER'},
            ],
            onApplyGraph: (_, connections) {},
            onMergeGraph: (_, connections) {},
            onModifyNodeParams: (_, params) => true,
            onClearAll: () {},
            onUndo: () {},
            onRedo: () {},
            onSave: () {},
            onAddNode: (_, x, y) {
              onAdd?.call();
              return 'private-node';
            },
            onAddGate: (_, x, y) => 'private-gate',
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
  await tester.pump();
}

Future<void> _send(WidgetTester tester, _AiServer server) async {
  final requestNumber = server.requests + 1;
  final input = find.byKey(const ValueKey('ai-chat-input'));
  await tester.enterText(input, 'PRIVATE_PROMPT');
  // Start the callback in the real async zone so loopback HTTP can advance.
  await tester.runAsync(() async {
    tester.widget<TextField>(input).onSubmitted!('PRIVATE_PROMPT');
    await server.waitForOutput(requestNumber).timeout(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late _AiServer server;
  late AppState state;

  setUp(() async {
    server = _AiServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    server.server.listen((request) => unawaited(server.handle(request)));
    state = AppState();
    state.config
      ..aiProvider = 'PRIVATE_PROVIDER'
      ..aiApiKey = 'PRIVATE_KEY'
      ..aiApiUrl = server.url
      ..aiModel = 'PRIVATE_MODEL'
      ..aiMaxTokens = 512
      ..aiContextWindow = 128000
      ..aiAutoTitle = false
      ..aiApproveMode = 'auto'
      ..aiWriteAccess = true;
    state.config.veryVerboseLogs = true;
    state.diagnosticTrace.setEnabled(true);
  });
  tearDown(() async {
    await server.close();
    state.dispose();
  });

  testWidgets(
    'aggregates stream counts and keeps every diagnostic value private',
    (tester) async {
      await _mount(tester, state);
      await _send(tester, server);
      await _until(
        tester,
        () => find.byTooltip('Stop generating').evaluate().isEmpty,
      );
      final logs = _trace(state);
      expect(
        logs,
        contains(
          allOf(contains('ai.request.start'), contains('protocol=openai')),
        ),
      );
      expect(
        logs,
        contains(
          allOf(
            contains('ai.request.attempt'),
            contains('messageCount=4'),
            contains('attachmentCount=1'),
            contains('maxTokens=512'),
          ),
        ),
      );
      expect(
        logs.where((line) => line.contains('ai.stream.summary')),
        hasLength(1),
      );
      expect(
        logs,
        contains(
          allOf(
            contains('ai.stream.summary'),
            contains('textChunks=8'),
            contains('responseChars=80'),
            matches(r'firstTokenMs=\d+'),
          ),
        ),
      );
      expect(
        logs.where((line) => line.contains('ai.request.result')),
        hasLength(1),
      );
      expect(
        logs,
        contains(
          allOf(
            contains('ai.request.result'),
            contains('success=true'),
            contains('cancelled=false'),
          ),
        ),
      );
      expect(
        logs.length,
        lessThan(12),
        reason: 'No per-token diagnostic events',
      );
      expect(logs.join(), isNot(contains('PRIVATE')));
      expect(logs.join(), isNot(contains('127.0.0.1')));
      expect(logs.join(), isNot(contains('xxxxxxxx')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabled diagnostics do not change ordinary streaming', (
    tester,
  ) async {
    state.config.veryVerboseLogs = false;
    state.diagnosticTrace.setEnabled(false);
    await _mount(tester, state);
    await _send(tester, server);
    await _until(
      tester,
      () => find.byTooltip('Stop generating').evaluate().isEmpty,
    );
    expect(server.streams, 1);
    expect(_trace(state), isEmpty);
    expect(find.text('x' * 80), findsOneWidget);
  });

  testWidgets('records continuation reason and total stream characters', (
    tester,
  ) async {
    server.continuation = true;
    await _mount(tester, state);
    await _send(tester, server);
    await _until(
      tester,
      () => find.byTooltip('Stop generating').evaluate().isEmpty,
    );
    expect(server.streams, 2);
    final logs = _trace(state);
    expect(
      logs,
      contains(
        allOf(
          contains('ai.request.continue'),
          contains('reason=max_tokens'),
          contains('continuation=1'),
        ),
      ),
    );
    expect(
      logs,
      contains(
        allOf(
          contains('ai.request.result'),
          contains('continuations=1'),
          contains('responseChars=160'),
        ),
      ),
    );
  });

  testWidgets(
    'records tool completion attempts and graph counts without arguments',
    (tester) async {
      server.tools = true;
      var additions = 0;
      await _mount(tester, state, onAdd: () => additions++);
      await _send(tester, server);
      await _until(
        tester,
        () => find.byTooltip('Stop generating').evaluate().isEmpty,
      );
      expect(additions, 1);
      expect(server.completions, 1);
      final logs = _trace(state);
      expect(
        logs,
        contains(
          allOf(
            contains('ai.request.retry'),
            contains('reason=tool_call_completion'),
            contains('attempt=2'),
          ),
        ),
      );
      expect(
        logs,
        contains(
          allOf(
            contains('ai.tools.summary'),
            contains('toolCalls=3'),
            contains('graphOperations=2'),
            contains('blocked=1'),
          ),
        ),
      );
      expect(
        logs,
        contains(
          allOf(
            contains('ai.request.result'),
            contains('toolCalls=3'),
            contains('graphOperations=2'),
          ),
        ),
      );
      expect(logs.join(), isNot(contains('PRIVATE')));
      expect(logs.join(), isNot(contains('private-node')));
      expect(logs.join(), isNot(contains('private-a')));
    },
  );

  for (final dispose in [false, true]) {
    testWidgets(
      'pairs a streaming ${dispose ? 'dispose' : 'cancel'} exactly once',
      (tester) async {
        server.hold = true;
        await _mount(tester, state);
        await _send(tester, server);
        await _until(tester, () => find.text('x' * 80).evaluate().isNotEmpty);
        if (dispose) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.tap(find.byTooltip('Stop generating'));
        }
        await _until(
          tester,
          () => _trace(state).any((line) => line.contains('ai.request.result')),
        );
        final result = _trace(
          state,
        ).singleWhere((line) => line.contains('ai.request.result'));
        expect(
          result,
          allOf(
            contains('cancelled=true'),
            contains('success=false'),
            contains('responseChars=80'),
            contains('reason=${dispose ? 'dispose' : 'user'}'),
          ),
        );
        server.release.complete();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
        expect(
          _trace(state).where((line) => line.contains('ai.request.result')),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancel then immediately resend keeps each span paired', (
    tester,
  ) async {
    server.hold = true;
    await _mount(tester, state);
    await _send(tester, server);
    await _until(tester, () => find.text('x' * 80).evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Stop generating'));
    await tester.pump();
    server.hold = false;
    await _send(tester, server);
    await _until(
      tester,
      () =>
          _trace(
            state,
          ).where((line) => line.contains('ai.request.result')).length ==
          2,
    );
    final logs = _trace(state);
    final starts = logs
        .where((line) => line.contains('ai.request.start'))
        .toList();
    final results = logs
        .where((line) => line.contains('ai.request.result'))
        .toList();
    expect(starts, hasLength(2));
    final idPattern = RegExp(r'opId=([0-9]+)');
    expect(
      starts.map((line) => idPattern.firstMatch(line)!.group(1)),
      results.map((line) => idPattern.firstMatch(line)!.group(1)),
    );
    expect(results.first, contains('cancelled=true'));
    expect(results.last, contains('success=true'));
    server.release.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(
      _trace(state).where((line) => line.contains('ai.request.result')),
      hasLength(2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabling then enabling suppresses the old stream result', (
    tester,
  ) async {
    server.hold = true;
    await _mount(tester, state);
    await _send(tester, server);
    await _until(tester, () => find.text('x' * 80).evaluate().isNotEmpty);
    final count = _trace(state).length;
    state.diagnosticTrace.setEnabled(false);
    state.diagnosticTrace.setEnabled(true);
    server.release.complete();
    await _until(
      tester,
      () => find.byTooltip('Stop generating').evaluate().isEmpty,
    );
    expect(_trace(state), hasLength(count));
  });

  testWidgets('title requests record numeric summaries without title text', (
    tester,
  ) async {
    state.config.aiAutoTitle = true;
    await _mount(tester, state);
    await _send(tester, server);
    await _until(
      tester,
      () =>
          server.completions == 1 &&
          _trace(state).any((line) => line.contains('ai.title.result')),
    );
    expect(
      _trace(state),
      contains(allOf(contains('ai.title.start'), contains('protocol=openai'))),
    );
    expect(
      _trace(state),
      contains(
        allOf(
          contains('ai.title.result'),
          contains('success=true'),
          contains('responseChars=13'),
        ),
      ),
    );
    expect(_trace(state).join(), isNot(contains('PRIVATE')));
  });

  testWidgets('disposing pairs an in-flight title request', (tester) async {
    state.config.aiAutoTitle = true;
    server.holdTitle = true;
    await _mount(tester, state);
    await _send(tester, server);
    await _until(tester, () => server.completions == 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      _trace(state),
      contains(
        allOf(
          contains('ai.title.result'),
          contains('success=false'),
          contains('cancelled=true'),
        ),
      ),
    );
    server.release.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    expect(
      _trace(state).where((line) => line.contains('ai.title.result')),
      hasLength(1),
    );
  });

  testWidgets('failure emits only error type and the actual attempt', (
    tester,
  ) async {
    server.fail = true;
    await _mount(tester, state);
    await _send(tester, server);
    await _until(
      tester,
      () => find.byTooltip('Stop generating').evaluate().isEmpty,
    );
    final logs = _trace(state);
    expect(
      logs,
      contains(
        allOf(
          contains('ai.request.result'),
          contains('success=false'),
          contains('errorType='),
          contains('attempts=1'),
        ),
      ),
    );
    expect(logs.join(), isNot(contains('PRIVATE')));
    expect(logs.where((line) => line.contains('ai.request.retry')), isEmpty);
  });
}
