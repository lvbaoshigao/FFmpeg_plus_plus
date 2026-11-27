import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _RecordingState extends AppState {
  PipelineGraph? observedGraph;

  @override
  void setCurrentPipeline(PipelineGraph? graph) {
    super.setCurrentPipeline(graph);
    observedGraph = graph?.deepCopy();
  }
}

class _ChatServer {
  _ChatServer(this.server);

  final HttpServer server;
  final started = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  List<Map<String, dynamic>> tools = [];
  String? graphResponse;
  int streamCount = 0;

  String get url => 'http://127.0.0.1:${server.port}/v1/chat/completions';

  Future<void> handle(HttpRequest request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    final response = request.response;
    if (body['stream'] != true) {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'id': 'response',
          'created': 1,
          'model': 'test-model',
          'choices': [
            {
              'message': {
                'content': '',
                'tool_calls': [
                  for (var i = 0; i < tools.length; i++)
                    {
                      'id': 'call-$i',
                      'type': 'function',
                      'function': {
                        'name': 'pipeline_tool',
                        'arguments': jsonEncode(tools[i]),
                      },
                    },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }),
      );
      await response.close();
      return;
    }
    streamCount++;
    response.headers.contentType = ContentType('text', 'event-stream');
    response.bufferOutput = false;
    void chunk(Map<String, dynamic> delta, [String? finish]) {
      response.write(
        'data: ${jsonEncode({
          'choices': [
            {'delta': delta, 'finish_reason': finish},
          ],
        })}\n\n',
      );
    }

    if (streamCount == 1) {
      chunk({'content': graphResponse ?? 'Working '});
      await response.flush();
      if (!started.isCompleted) started.complete();
      await release.future;
      if (tools.isNotEmpty) {
        // Exercise the SDK's native function-call completion path.
        chunk({
          'tool_calls': [
            {
              'function': {'arguments': '{}'},
            },
          ],
        });
        chunk({}, 'tool_calls');
      } else {
        if (graphResponse == null) chunk({'content': 'finished.'});
        chunk({}, 'stop');
      }
    } else {
      chunk({'content': 'Applied.'});
      chunk({}, 'stop');
    }
    response.write('data: [DONE]\n\n');
    await response.close();
    if ((tools.isEmpty || streamCount > 1) && !finished.isCompleted) {
      finished.complete();
    }
  }

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  }
}

PipelineGraph _graph() => PipelineGraph(
  nodes: [
    PipelineNode(id: 'start', type: PipelineStepType.start, x: 2900, y: 3000),
    PipelineNode(
      id: 'encode',
      type: PipelineStepType.avProcess,
      x: 3150,
      y: 3000,
      params: {'crf': 23, 'preset': 'medium'},
    ),
    PipelineNode(id: 'output', type: PipelineStepType.output, x: 3400, y: 3000),
  ],
  connections: [
    PipelineConnection(id: 'a', fromNodeId: 'start', toNodeId: 'encode'),
    PipelineConnection(id: 'b', fromNodeId: 'encode', toNodeId: 'output'),
  ],
);

Future<void> _mount(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(glassEffect: 'none'),
        home: PipelineEditorPage(
          video: VideoFile(id: 'ai-session-regression', filename: 'Template'),
          initialGraph: _graph(),
          onSave: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _open(WidgetTester tester, {bool mobile = false}) async {
  await tester.tap(
    mobile
        ? find.byTooltip('AI Assistant')
        : find.byKey(const ValueKey('ai-drawer-toggle')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _send(WidgetTester tester, _ChatServer server) async {
  final input = find.byKey(const ValueKey('ai-chat-input'));
  await tester.enterText(input, 'Adjust my workflow');
  await tester.pump();
  final button = find.descendant(
    of: find.byTooltip('Send message'),
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );
  await tester.runAsync(() async {
    tester.widget<FilledButton>(button).onPressed!();
    await server.started.future.timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, _ChatServer server) async {
  if (!server.release.isCompleted) server.release.complete();
  await tester.runAsync(() async {
    await server.finished.future.timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 40));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final watch = Stopwatch()..start();
  while (finder.evaluate().isEmpty &&
      watch.elapsed < const Duration(seconds: 20)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsWidgets);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 600));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  const windowChannel = MethodChannel('window_manager');
  late _ChatServer server;
  late _RecordingState state;

  setUp(() async {
    server = _ChatServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server.server.listen((request) => unawaited(server.handle(request)));
    state = _RecordingState();
    state.config
      ..language = 'en'
      ..aiEnabled = true
      ..aiProvider = 'openai'
      ..aiApiKey = 'test-key'
      ..aiApiUrl = server.url
      ..aiModel = 'test-model'
      ..aiMaxTokens = 512
      ..aiContextWindow = 128000
      ..aiAutoTitle = false
      ..aiApproveMode = 'auto'
      ..aiWriteAccess = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
          if (call.method == 'isMaximized') return false;
          return null;
        });
  });

  tearDown(() async {
    debugIsMobilePlatformOverride = null;
    await server.close();
    state.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  testWidgets('collapsed desktop drawer preserves its request and draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _mount(tester, state);
    await _open(tester);
    final session = tester.state(find.byType(AiPanelView));
    await _send(tester, server);
    await tester.enterText(
      find.byKey(const ValueKey('ai-chat-input')),
      'next draft',
    );
    await tester.tap(find.byKey(const ValueKey('ai-drawer-toggle')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AiPanelView), findsNothing);
    expect(
      tester.state(find.byType(AiPanelView, skipOffstage: false)),
      same(session),
    );
    await _finish(tester, server);
    await _open(tester);
    expect(tester.state(find.byType(AiPanelView)), same(session));
    expect(find.text('Working finished.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
          .controller!
          .text,
      'next draft',
    );
    expect(find.byTooltip('Stop generating'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('floating AI minimizes and docks without replacing the session', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _mount(tester, state);
    await _open(tester);
    final session = tester.state(find.byType(AiPanelView));
    await _send(tester, server);
    tester.widget<AiPanelView>(find.byType(AiPanelView)).onInlineFloat!();
    await tester.pump();
    expect(tester.state(find.byType(AiPanelView)), same(session));
    tester.widget<AiPanelView>(find.byType(AiPanelView)).onCollapseRequested!();
    await tester.pump();
    expect(find.byType(AiPanelView), findsNothing);
    expect(
      tester.state(find.byType(AiPanelView, skipOffstage: false)),
      same(session),
    );
    await _finish(tester, server);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pump();
    expect(find.text('Working finished.'), findsOneWidget);
    await tester.tap(find.byTooltip('Dock back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.state(find.byType(AiPanelView)), same(session));
    expect(find.text('Working finished.'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets(
    'composer focuses its outline without an underline or filled field',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _mount(tester, state);
      await _open(tester);
      final composer = find.byKey(const ValueKey('ai-chat-composer'));
      final before =
          (tester.widget<Material>(composer).shape! as RoundedRectangleBorder)
              .side;
      await tester.tap(find.byKey(const ValueKey('ai-chat-input')));
      await tester.pump(const Duration(milliseconds: 200));
      final after =
          (tester.widget<Material>(composer).shape! as RoundedRectangleBorder)
              .side;
      expect(after.color, isNot(before.color));
      expect(after.width, greaterThan(before.width));
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('ai-chat-input')),
      );
      expect(field.decoration!.focusedBorder, InputBorder.none);
      expect(field.decoration!.filled, false);
      expect(field.maxLines, 5);
      await _unmount(tester);
    },
  );

  testWidgets(
    'native node parameters reach the editor with their types intact',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      server.tools = [
        {
          'action': 'modify_node',
          'arguments': [
            'encode',
            jsonEncode({
              'crf': 28,
              'preset': 'slow',
              'subtitle_file': '/tmp/intro,part=2.srt',
              'enabled': true,
              'metadata': {'title': 'A, B=C'},
            }),
          ],
        },
        {
          'action': 'modify_node',
          'arguments': [
            'encode',
            {'crf': 29, 'preset': 'fast'},
          ],
        },
        {
          'action': 'modify_node',
          'arguments': ['encode', 'node_name=Clip, part 2', 'crf=31'],
        },
        {
          'action': 'add_node',
          'arguments': [
            'videoFrameRate',
            '500',
            '100',
            {'fps': 24, 'fps_preset': '24'},
          ],
        },
        {
          'action': 'add_gate',
          'arguments': [
            'time_trigger',
            '750',
            '100',
            {'tt_start': '08:00', 'tt_end': '09:00'},
          ],
        },
      ];
      await _mount(tester, state);
      final encoderId = state.mcpOnListNodes!().singleWhere(
        (node) => node['type'] == 'avProcess',
      )['id'];
      for (final tool in server.tools) {
        final args = tool['arguments'] as List;
        if (args.first == 'encode') args[0] = encoderId;
      }
      await _open(tester);
      await _send(tester, server);
      // Background tool execution must still update the editor after collapse.
      await tester.tap(find.byKey(const ValueKey('ai-drawer-toggle')));
      await tester.pump(const Duration(milliseconds: 250));
      await _finish(tester, server);
      final nodes = state.mcpOnListNodes!();
      final encoder = nodes.singleWhere((node) => node['id'] == encoderId);
      expect(encoder['params'], containsPair('crf', 31));
      expect(encoder['params'], containsPair('preset', 'fast'));
      expect(encoder['params'], containsPair('node_name', 'Clip, part 2'));
      expect(
        encoder['params'],
        containsPair('subtitle_file', '/tmp/intro,part=2.srt'),
      );
      expect(encoder['params'], containsPair('enabled', true));
      expect(encoder['params'], containsPair('metadata', {'title': 'A, B=C'}));
      final frame = nodes.singleWhere(
        (node) => node['type'] == 'videoFrameRate',
      );
      expect(frame['params'], containsPair('fps', 24.0));
      expect(frame['params'], containsPair('fps_preset', '24'));
      final gate = nodes.singleWhere((node) => node['gate'] == 'timeTrigger');
      expect(gate['params'], containsPair('tt_start', '08:00'));
      expect(state.observedGraph!.nodes, hasLength(5));
      await _unmount(tester);
    },
  );

  testWidgets('JSON graph application commits typed parameters to AppState', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server.graphResponse =
        '```json\n${jsonEncode({
          'nodes': [
            {'id': 's', 'type': 'start'},
            {
              'id': 'f',
              'type': 'videoFrameRate',
              'params': {'fps': '25'},
            },
            {
              'id': 'o',
              'type': 'output',
              'params': {'format': 'mp4'},
            },
          ],
          'connections': [
            {'from': 's', 'to': 'f'},
            {'from': 'f', 'to': 'o'},
          ],
        })}\n```';
    await _mount(tester, state);
    await _open(tester);
    await _send(tester, server);
    await _finish(tester, server);
    final graph = state.observedGraph!;
    expect(graph.nodes, hasLength(3));
    expect(
      graph.nodes
          .singleWhere((node) => node.type == PipelineStepType.videoFrameRate)
          .params['fps'],
      25.0,
    );
    expect(graph.connections, hasLength(2));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    'mobile AI stays below pushed dialogs and settings while keeping its stream',
    (tester) async {
      debugIsMobilePlatformOverride = true;
      tester.view.physicalSize = const Size(411, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _mount(tester, state);
      await _open(tester, mobile: true);
      final session = tester.state(find.byType(AiPanelView));
      await _send(tester, server);
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        'keep this draft',
      );
      await tester.pump();
      final aiContext = tester.element(find.byType(AiPanelView));
      var allowed = false;
      unawaited(
        showDialog<void>(
          context: aiContext,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Permission required'),
            actions: [
              FilledButton(
                key: const ValueKey('allow-over-ai'),
                onPressed: () {
                  allowed = true;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Allow permission'),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const ValueKey('allow-over-ai')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('allow-over-ai')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(allowed, isTrue);
      expect(tester.state(find.byType(AiPanelView)), same(session));
      var settingsTapped = false;
      final navigator = Navigator.of(aiContext);
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (settingsContext) => Scaffold(
              appBar: AppBar(title: const Text('Settings over AI')),
              body: Center(
                child: FilledButton(
                  key: const ValueKey('settings-over-ai'),
                  onPressed: () {
                    settingsTapped = true;
                    Navigator.of(settingsContext).pop();
                  },
                  child: const Text('Return to AI'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('settings-over-ai')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.state(find.byType(AiPanelView, skipOffstage: false)),
        same(session),
      );
      await _finish(tester, server);
      await tester.tap(find.byKey(const ValueKey('settings-over-ai')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(settingsTapped, isTrue);
      expect(tester.state(find.byType(AiPanelView)), same(session));
      expect(find.text('Working finished.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
            .controller!
            .text,
        'keep this draft',
      );
      await _unmount(tester);
    },
  );

  testWidgets(
    'native AI permission dialog accepts input above the mobile portal',
    (tester) async {
      debugIsMobilePlatformOverride = true;
      tester.view.physicalSize = const Size(411, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      state.config.aiApproveMode = 'ask';
      state.config.aiAskSkipTools = [];
      await _mount(tester, state);
      final encoderId = state.mcpOnListNodes!().singleWhere(
        (node) => node['type'] == 'avProcess',
      )['id'];
      server.tools = [
        {
          'action': 'modify_node',
          'arguments': [
            encoderId,
            {'crf': 27},
          ],
        },
      ];
      await _open(tester, mobile: true);
      final session = tester.state(find.byType(AiPanelView));
      await _send(tester, server);
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        'after approval',
      );
      server.release.complete();
      await _waitFor(tester, find.text('AI requests to run an action'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Allow').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Allow'));
      await _finish(tester, server);
      expect(tester.state(find.byType(AiPanelView)), same(session));
      expect(
        state.mcpOnListNodes!().singleWhere(
          (node) => node['id'] == encoderId,
        )['params'],
        containsPair('crf', 27),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
            .controller!
            .text,
        'after approval',
      );
      await _unmount(tester);
    },
  );

  testWidgets(
    'closing mobile sheet preserves streaming and Back closes the reopened sheet',
    (tester) async {
      debugIsMobilePlatformOverride = true;
      tester.view.physicalSize = const Size(411, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _mount(tester, state);
      await _open(tester, mobile: true);
      final session = tester.state(find.byType(AiPanelView));
      await _send(tester, server);
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      expect(find.byType(AiPanelView), findsNothing);
      expect(
        tester.state(find.byType(AiPanelView, skipOffstage: false)),
        same(session),
      );
      await _finish(tester, server);
      await _open(tester, mobile: true);
      expect(tester.state(find.byType(AiPanelView)), same(session));
      expect(find.text('Working finished.'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(PipelineEditorPage), findsOneWidget);
      expect(find.byType(AiPanelView), findsNothing);
      await _open(tester, mobile: true);
      // Leaving the editor also owns and releases a currently visible overlay.
      await _unmount(tester);
    },
  );
}
