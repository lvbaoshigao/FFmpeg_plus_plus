import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_strings.dart';
import 'package:ffmpegpp_gui/widgets/ai_workflow_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ai_sdk/flutter_ai_sdk.dart' as ai;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

AiPanelView _testPanel({
  List<Map<String, dynamic>>? initialMessages,
  void Function(AiPanelApi api)? onApiReady,
  bool mobileSheet = false,
  VoidCallback? onCloseRequested,
}) => AiPanelView(
  strings: AppStrings.en,
  existingNodes: const [],
  existingConnections: const [],
  startExpanded: true,
  hideHeader: true,
  initialMessages: initialMessages,
  onApiReady: onApiReady,
  mobileSheet: mobileSheet,
  onCloseRequested: onCloseRequested,
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
);

Future<void> _pumpPanel(WidgetTester tester, AiPanelView panel) async {
  final state = AppState();
  addTearDown(state.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: Scaffold(body: panel)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

/// 冲掉 ConfigService 的 400ms 防抖，避免测试结束时报 pending timer。
Future<void> _teardownPanel(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  group('AiPanelView', () {
    testWidgets('should preserve handoff blocks and show final text once', (
      tester,
    ) async {
      final state = AppState();
      AiPanelApi? api;
      final panel = AiPanelView(
        strings: AppStrings.en,
        existingNodes: const [],
        existingConnections: const [],
        startExpanded: true,
        hideHeader: true,
        onApiReady: (value) => api = value,
        initialMessages: const [
          {
            'role': 'user',
            'content': 'Inspect this file',
            'blocks': [
              {
                'type': 'attachment',
                'name': 'clip.mp4',
                'path': '/local/clip.mp4',
                'size': 12,
                'mimeType': 'application/octet-stream',
              },
            ],
          },
          {
            'role': 'assistant',
            'content': 'Final answer',
            'blocks': [
              {'type': 'thinking', 'thinking': 'Planning'},
              {'type': 'text', 'text': 'Final answer'},
            ],
          },
          {
            'role': 'assistant',
            'content': '[probe] result',
            'blocks': [
              {
                'type': 'tool_result',
                'name': 'probe',
                'content': 'Probe metadata',
              },
            ],
          },
          {'role': 'user', 'content': 'OK'},
        ],
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
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(home: Scaffold(body: panel)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AiWorkflowCard), findsOneWidget);
      // Asymmetric alignment: the user bubble sits to the right, while the
      // assistant workflow card stays left with an avatar gutter and a 4/5 cap.
      final cardRect = tester.getRect(find.byType(AiWorkflowCard));
      final userName = tester.getRect(find.text('Inspect this file'));
      final answer = tester.getRect(find.text('Final answer'));
      expect(userName.center.dx, greaterThan(answer.center.dx));
      expect(cardRect.left, greaterThan(0));
      expect(cardRect.width, lessThan(800 * 0.85));
      final shortUserText = tester.getRect(find.text('OK'));
      expect(shortUserText.right, closeTo(userName.right, 1));
      final userAvatars = find.byIcon(Icons.person);
      expect(userAvatars, findsNWidgets(2));
      expect(
        tester.getRect(userAvatars.first).center.dx,
        closeTo(tester.getRect(userAvatars.last).center.dx, 1),
      );
      final shortUserLabel = find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == 'OK',
      );
      final userTextWidget = tester.widget<SelectableText>(shortUserLabel);
      final scheme = Theme.of(tester.element(shortUserLabel)).colorScheme;
      expect(userTextWidget.style?.color, scheme.onPrimaryContainer);
      expect(find.text('Final answer'), findsOneWidget);
      expect(find.text('Probe metadata'), findsNothing);
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(api!.exportMessages().first['blocks'], isNotEmpty);
      await tester.tap(find.text('Completed · 2 steps'));
      await tester.pump();
      expect(find.text('Final answer'), findsOneWidget);
      // task-9 C：工具卡片默认折叠（只有运行中才自动展开），所以展开工作流
      // 卡片之后结果不会直接铺开，要再点一次工具卡片标题。
      expect(find.text('Probe metadata'), findsNothing);
      expect(find.text('probe · Done'), findsOneWidget);
      await tester.tap(find.text('probe · Done'));
      await tester.pump();
      expect(find.text('Probe metadata'), findsOneWidget);
      final exported = api!.exportMessages();
      api!.importMessages(exported);
      await tester.pump();
      expect(api!.exportMessages(), exported);
      // Avoid automatic session-save filesystem work in this isolated fixture.
      api!.importMessages([]);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('should not force-scroll while the user reads older messages', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      final panel = AiPanelView(
        strings: AppStrings.en,
        existingNodes: const [],
        existingConnections: const [],
        startExpanded: true,
        hideHeader: true,
        initialMessages: [
          for (var i = 0; i < 30; i++) ...[
            {
              'role': 'user',
              'content': 'Question $i-abcdefghijklmnopqrstuvwxyz',
            },
            {
              'role': 'assistant',
              'content': 'Answer $i-abcdefghijklmnopqrstuvwxyz',
            },
          ],
        ],
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
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(home: Scaffold(body: panel)),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final initial = scrollable.position.pixels;
      await tester.drag(find.byType(ListView).first, const Offset(0, 260));
      await tester.pump();
      final afterDrag = scrollable.position.pixels;
      await tester.pump(const Duration(milliseconds: 50));
      expect(afterDrag, lessThan(initial));
      expect(scrollable.position.pixels, closeTo(afterDrag, 1));
    });

    testWidgets(
      'should not show a stale model id that is absent from the provider',
      (tester) async {
        final state = AppState();
        final stale = AiProfile(
          name: 'OpenAI',
          provider: 'openai',
          model: 'gpt-4o',
        );
        stale.models.add(AiModelEntry(id: 'actual-model'));
        stale.enabled = true;
        state.updateConfig((c) {
          c.aiProfiles.add(stale);
          c.activeAiProfileId = stale.id;
          return c;
        });
        final panel = AiPanelView(
          strings: AppStrings.en,
          existingNodes: const [],
          existingConnections: const [],
          startExpanded: true,
          hideHeader: true,
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
        );
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: state,
            child: MaterialApp(home: Scaffold(body: panel)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('gpt-4o'), findsNothing);
        expect(find.textContaining('actual-model'), findsWidgets);
        // Flush ConfigService's 400ms debounce before the test binding disposes.
        await tester.pump(const Duration(milliseconds: 600));
      },
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // AI 对话机制：纯逻辑（离线，不联网）
  // ──────────────────────────────────────────────────────────────────────
  group('AI dialogue mechanics (pure)', () {
    test('request history window never mutates the UI list', () {
      final roles = List<String>.generate(
        150,
        (i) => i.isEven ? 'user' : 'assistant',
      );
      final copy = List<String>.of(roles);
      final start = requestHistoryStartIndex(roles);
      // 只读：构造请求窗口不能像旧实现那样 removeRange 掉 UI 历史。
      expect(roles, copy);
      expect(start, greaterThan(0));
      expect(150 - start, lessThanOrEqualTo(100));
      // 窗口起点对齐到 user，避免 assistant tool_calls 与 tool_result 被拆散。
      expect(roles[start], 'user');
      expect(requestHistoryStartIndex(roles, maxMessages: 1000), 0);
      // 窗口内没有 user 时向更早回退，避免请求以 assistant 开头。
      final assistantOnlyTail = List<String>.filled(120, 'assistant')
        ..[0] = 'user';
      expect(requestHistoryStartIndex(assistantOnlyTail), 0);
    });

    test('request window keeps tool calls paired with their results', () {
      // 两个完整回合，每回合：user / assistant(tool_use) / tool_result / 正文。
      final entries = <AiHistoryEntry>[
        const AiHistoryEntry(role: 'user', estimatedTokens: 10),
        const AiHistoryEntry(
          role: 'assistant',
          hasToolCalls: true,
          estimatedTokens: 10,
        ),
        const AiHistoryEntry(
          role: 'assistant',
          hasToolResults: true,
          estimatedTokens: 10,
        ),
        const AiHistoryEntry(role: 'assistant', estimatedTokens: 10),
        const AiHistoryEntry(role: 'user', estimatedTokens: 10),
        const AiHistoryEntry(
          role: 'assistant',
          hasToolCalls: true,
          estimatedTokens: 10,
        ),
        const AiHistoryEntry(
          role: 'assistant',
          hasToolResults: true,
          estimatedTokens: 10,
        ),
        const AiHistoryEntry(role: 'assistant', estimatedTokens: 10),
      ];
      // 预算只够最后几条时，起点必须退回到该回合的 user：否则窗口会以
      // assistant(tool_calls) 或孤立 tool_result 开头，供应商直接 400。
      final window = requestHistoryIndices(entries, maxMessages: 3);
      expect(window.first, 0); // 首条 user 意图被单独保留
      expect(window, containsAll(<int>[4, 5, 6, 7]));
      expect(entries[window[1]].isUser, isTrue);
      // 条数足够时不裁剪（返回全部下标，顺序不变）。
      expect(requestHistoryIndices(entries, maxMessages: 100), [
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      ]);
      // token 预算生效时同样对齐到 user 回合边界。
      final byTokens = requestHistoryIndices(entries, maxTokens: 20);
      expect(byTokens.first, 0);
      expect(byTokens, containsAll(<int>[4, 5, 6]));
      // 空历史 / 单条历史。
      expect(requestHistoryIndices(const <AiHistoryEntry>[]), isEmpty);
      expect(
        requestHistoryIndices(const [
          AiHistoryEntry(role: 'user', estimatedTokens: 3),
        ]),
        [0],
      );
    });

    test('truncation heuristic only flags obviously unfinished text', () {
      // 未闭合的代码围栏 = 一定被截断。
      expect(looksTruncatedText('\u0060\u0060\u0060dart\nvoid main() {'), isTrue);
      expect(
        looksTruncatedText('\u0060\u0060\u0060dart\nvoid main() {}\n\u0060\u0060\u0060'),
        isFalse,
      );
      // 结尾是「后面还该有内容」的符号。
      expect(looksTruncatedText('第一，'), isTrue);
      expect(looksTruncatedText('a, b,'), isTrue);
      expect(looksTruncatedText('步骤如下：'), isTrue);
      expect(looksTruncatedText('调用 foo('), isTrue);
      // 正常收尾不续写（否则每条回复都会白跑一轮请求）。
      expect(looksTruncatedText('已经说完了。'), isFalse);
      expect(looksTruncatedText('done'), isFalse);
      expect(looksTruncatedText('   '), isFalse);
      expect(looksTruncatedText('(a)'), isFalse);
    });

    test('continuation dedupe removes a repeated prefix', () {
      // 模型把整段又写了一遍：只留新增部分。
      expect(
        stripRepeatedContinuation('Hello world', 'Hello world again'),
        'again',
      );
      // 只重复了尾部若干字符（>= 12）也要剥掉。
      const prev = '这是第一段的完整内容，接下来要讲第二段的具体细节';
      expect(
        stripRepeatedContinuation(prev, '接下来要讲第二段的具体细节，然后继续。'),
        '，然后继续。',
      );
      // 完全新内容原样保留；空输入不崩。
      expect(stripRepeatedContinuation('abc', '完全不同的一段'), '完全不同的一段');
      expect(stripRepeatedContinuation('', 'x'), 'x');
    });

    test('token estimate mirrors the SDK counter', () {
      expect(estimateRequestTokens(''), 0);
      // 4 个非空白字符 ≈ 1 token；空白不计入字符估算。
      expect(estimateRequestTokens('abcd'), greaterThan(0));
      expect(
        estimateRequestTokens('hello world'),
        greaterThanOrEqualTo(estimateRequestTokens('helloworld')),
      );
    });

    test('auto-continue also covers providers without finish_reason', () {
      // 中转 / 自建网关常常整条流都不回 finish_reason：正文看起来被截断才续写。
      final noReason = AiAutoContinuePolicy();
      expect(
        noReason.shouldContinue(
          finishReason: null,
          content: '第一段讲完了，',
          stopRequested: false,
        ),
        isTrue,
      );
      expect(noReason.rounds, 1);
      // 同样缺 finish_reason，但正文已正常收尾 → 不白跑一轮。
      final finished = AiAutoContinuePolicy();
      expect(
        finished.shouldContinue(
          finishReason: ai.FinishReason.unknown,
          content: '已经说完了。',
          stopRequested: false,
        ),
        isFalse,
      );
      // 本轮带工具调用时不叠加续写（工具轮有自己的循环）。
      final toolRound = AiAutoContinuePolicy();
      expect(
        toolRound.shouldContinue(
          finishReason: ai.FinishReason.maxTokens,
          content: 'partial',
          stopRequested: false,
          toolCallsPresent: true,
        ),
        isFalse,
      );
      // 调用方显式给出判断结果时以它为准。
      final explicit = AiAutoContinuePolicy();
      expect(
        explicit.shouldContinue(
          finishReason: null,
          content: '无关内容',
          stopRequested: false,
          contentLooksTruncated: true,
        ),
        isTrue,
      );
    });

    test('auto-continue policy is bounded and ignores empty/stopped turns', () {
      final policy = AiAutoContinuePolicy();
      expect(
        policy.shouldContinue(
          finishReason: ai.FinishReason.maxTokens,
          content: 'partial answer',
          stopRequested: false,
        ),
        isTrue,
      );
      expect(policy.rounds, 1);
      // 空响应绝不续写，否则会无限请求。
      final empty = AiAutoContinuePolicy();
      expect(
        empty.shouldContinue(
          finishReason: ai.FinishReason.maxTokens,
          content: '   ',
          stopRequested: false,
        ),
        isFalse,
      );
      // 用户按停止后不续写。
      expect(
        policy.shouldContinue(
          finishReason: ai.FinishReason.maxTokens,
          content: 'partial answer',
          stopRequested: true,
        ),
        isFalse,
      );
      // 正常 stop 不续写。
      expect(
        policy.shouldContinue(
          finishReason: ai.FinishReason.stop,
          content: 'partial answer',
          stopRequested: false,
        ),
        isFalse,
      );
      // 最多 3 轮，之后永远 false（不会无限续写）。
      final bounded = AiAutoContinuePolicy(maxRounds: 3);
      for (var i = 0; i < 3; i++) {
        expect(
          bounded.shouldContinue(
            finishReason: ai.FinishReason.maxTokens,
            content: 'partial',
            stopRequested: false,
          ),
          isTrue,
        );
      }
      expect(bounded.exhausted, isTrue);
      expect(
        bounded.shouldContinue(
          finishReason: ai.FinishReason.maxTokens,
          content: 'partial',
          stopRequested: false,
        ),
        isFalse,
      );
    });

    test('continuation text merges without losing characters', () {
      expect(mergeContinuationText('', 'abc'), 'abc');
      expect(mergeContinuationText('abc', ''), 'abc');
      // 半句截断：直接拼回去。
      expect(mergeContinuationText('The quick brown f', 'ox'), 'The quick brown fox');
      // 句末 + 下一段无前导空白：补一个空格，避免英文粘字。
      expect(mergeContinuationText('End.', 'Next'), 'End. Next');
      expect(mergeContinuationText('End.', ' Next'), 'End. Next');
    });

    test('tool-round text never shrinks the streamed answer', () {
      expect(mergeToolRoundText(streamed: 'Hello', nonStream: null), 'Hello');
      expect(mergeToolRoundText(streamed: '', nonStream: 'Hello'), 'Hello');
      // 非流式更短：保留已经展示给用户的流式文本。
      expect(
        mergeToolRoundText(streamed: 'Hello world', nonStream: 'Hello'),
        'Hello world',
      );
      // 非流式是流式的超集：采用更完整的文本。
      expect(
        mergeToolRoundText(streamed: 'Hello', nonStream: 'Hello world'),
        'Hello world',
      );
      // 内容分叉：不替换已展示文本。
      expect(
        mergeToolRoundText(streamed: 'Hello world', nonStream: 'Goodbye world'),
        'Hello world',
      );
    });

    test('history token keys are read both ways', () {
      expect(
        historyMessageInputTokens({'in': 11, 'out': 12}),
        11,
      );
      expect(
        historyMessageInputTokens({'inputTokens': 21, 'outputTokens': 22}),
        21,
      );
      expect(historyMessageOutputTokens({'inputTokens': 21}), isNull);
      expect(
        historyMessageOutputTokens({'inputTokens': 21, 'outputTokens': 22}),
        22,
      );
      expect(historyMessageInputTokens({'content': 'x'}), isNull);
    });

    test('assistant blocks keep plain replies on the markdown path', () {
      // 普通回复必须返回 null blocks，否则 _buildMessage 会走纯文本分支，
      // 标题 / 列表 / 代码块 / 表格样式全部丢失。
      expect(
        assistantBlocksForUi(
          thinking: '',
          text: 'plain answer',
          toolCalls: const [],
          elapsedMs: 1,
        ),
        isNull,
      );
      final thinking = assistantBlocksForUi(
        thinking: 'plan',
        text: 'answer',
        toolCalls: const [],
        elapsedMs: 12,
      )!;
      expect(
        thinking.map((block) => block['type']).toList(),
        containsAll(<String>['thinking', 'text']),
      );
      const call = ai.ToolCallContent(
        id: 'call_1',
        name: 'pipeline_tool',
        arguments: {'action': 'undo', 'arguments': <String>[]},
      );
      final tool = assistantBlocksForUi(
        thinking: '',
        text: '',
        toolCalls: [call],
        elapsedMs: 1,
      )!;
      expect(tool.single['type'], 'tool_use');
      expect(tool.single['id'], 'call_1');
      // 跨轮重建：tool_use 块能还原 id / name / args。
      final restored = assistantToolCallsFromBlocks(tool).single;
      expect(restored.id, 'call_1');
      expect(restored.name, 'pipeline_tool');
      expect(restored.arguments['action'], 'undo');
    });

    test('history persistence skips empty streaming placeholders', () {
      // 生成中/停止后残留的空 assistant 占位不能落盘。
      expect(
        shouldPersistHistoryMessage(
          role: 'assistant',
          content: '   ',
          blocks: null,
        ),
        isFalse,
      );
      // 有正文的 assistant / 用户消息保留。
      expect(
        shouldPersistHistoryMessage(
          role: 'assistant',
          content: 'answer',
          blocks: null,
        ),
        isTrue,
      );
      expect(
        shouldPersistHistoryMessage(
          role: 'user',
          content: '',
          blocks: null,
        ),
        isTrue,
      );
      // 工具结果消息正文可能为空，但 blocks 非空，必须保留。
      expect(
        shouldPersistHistoryMessage(
          role: 'assistant',
          content: '',
          blocks: [
            {'type': 'tool_result', 'name': 'undo', 'content': 'ok'},
          ],
        ),
        isTrue,
      );
    });

    test('tool result blocks restore only when a toolCallId exists', () {
      final restored = toolResultMessageFromBlock({
        'type': 'tool_result',
        'name': 'undo',
        'content': 'ok',
        'toolCallId': 'call_9',
      });
      expect(restored, isNotNull);
      expect(restored!.role, ai.MessageRole.tool);
      // 老历史没有 id：必须回退普通文本，不能发孤立 tool 消息（OpenAI 400）。
      expect(
        toolResultMessageFromBlock({
          'type': 'tool_result',
          'name': 'undo',
          'content': 'ok',
        }),
        isNull,
      );
      // 只有 pending 集合里出现过同 id 的 assistant tool_call 才能结构化发回。
      const block = {
        'type': 'tool_result',
        'name': 'undo',
        'content': 'ok',
        'toolCallId': 'call_9',
      };
      expect(
        canRestoreStructuredToolResult(
          pendingToolCallIds: {'call_9'},
          block: block,
        ),
        isTrue,
      );
      expect(
        canRestoreStructuredToolResult(
          pendingToolCallIds: {'call_other'},
          block: block,
        ),
        isFalse,
      );
      expect(
        canRestoreStructuredToolResult(
          pendingToolCallIds: {'call_9'},
          block: const {'type': 'tool_result', 'content': 'ok'},
        ),
        isFalse,
      );
    });

    test('mobile AI sidebar width is comfortable on narrow panels', () {
      // 旧实现 min(340, 86%)：320dp 时只有 275dp，文字被截断。
      expect(mobileAiSidebarWidth(320), closeTo(300.8, 0.001));
      expect(mobileAiSidebarWidth(320), greaterThan(320 * 0.86));
      expect(mobileAiSidebarWidth(0), 0);
      expect(mobileAiSidebarWidth(-8), 0);
      expect(mobileAiSidebarWidth(1000), 400);
    });

    test('mobile AI header metrics keep 320dp from overflowing', () {
      final compact = AiMobileHeaderMetrics.forWidth(320);
      expect(compact.compact, isTrue);
      expect(compact.actionSize, 32);
      expect(compact.actionIconSize, 18);
      expect(compact.modelChipWidth, 88);

      final normal = AiMobileHeaderMetrics.forWidth(412);
      expect(normal.compact, isFalse);
      expect(normal.modelChipWidth, greaterThan(compact.modelChipWidth));

      // 单行 header 固定部分 = 3 个动作按钮 + 机器人图标 + 图标间距 +
      // 模型 chip + pill 横向内边距；必须给「AI 助手」标题留出空间。
      final fixed =
          3 * compact.actionSize + 16 + 6 + compact.modelChipWidth + 8;
      expect(fixed, lessThan(320 - 16));
      expect(320 - 16 - fixed, greaterThan(40));
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  // 对话 UI：历史 / Markdown（离线，不联网）
  // ──────────────────────────────────────────────────────────────────────
  group('AiPanelView history and markdown', () {
    testWidgets('keeps the whole handoff history instead of trimming it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AiPanelApi? api;
      final history = <Map<String, dynamic>>[
        for (var i = 0; i < 120; i++)
          {
            'role': i.isEven ? 'user' : 'assistant',
            'content': 'message $i',
          },
      ];
      await _pumpPanel(
        tester,
        _testPanel(
          initialMessages: history,
          onApiReady: (value) => api = value,
        ),
      );
      expect(api, isNotNull);
      expect(api!.exportMessages().length, 120);
      // 模拟发送时计算请求窗口：只取最近 100 条，但 UI 历史仍是完整的 120。
      final start = requestHistoryStartIndex(
        api!.exportMessages().map((m) => m['role'] as String).toList(),
      );
      expect(start, greaterThan(0));
      expect(api!.exportMessages().length, 120);
      api!.importMessages(api!.exportMessages());
      await tester.pump();
      expect(api!.exportMessages().length, 120);
      api!.importMessages([]);
      await _teardownPanel(tester);
    });

    testWidgets('imports legacy and canonical token keys, exports canonical', (
      tester,
    ) async {
      AiPanelApi? api;
      await _pumpPanel(
        tester,
        _testPanel(
          initialMessages: const [
            {'role': 'user', 'content': 'a', 'in': 3, 'out': 4},
            {
              'role': 'assistant',
              'content': 'b',
              'inputTokens': 5,
              'outputTokens': 6,
            },
          ],
          onApiReady: (value) => api = value,
        ),
      );
      var exported = api!.exportMessages();
      expect(exported[0]['in'], 3);
      expect(exported[0]['out'], 4);
      // 旧键（inputTokens/outputTokens）也必须读出来。
      expect(exported[1]['in'], 5);
      expect(exported[1]['out'], 6);
      // 导出统一使用 in/out，不再写旧键。
      expect(exported[1].containsKey('inputTokens'), isFalse);
      // 交接导入同样双向兼容。
      api!.importMessages([
        {'role': 'user', 'content': 'c', 'inputTokens': 7, 'outputTokens': 8},
      ]);
      await tester.pump();
      exported = api!.exportMessages();
      expect(exported.single['in'], 7);
      expect(exported.single['out'], 8);
      api!.importMessages([]);
      await _teardownPanel(tester);
    });

    testWidgets('wide markdown tables get a horizontal scroll view', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpPanel(
        tester,
        _testPanel(
          initialMessages: const [
            {'role': 'user', 'content': 'show me a table'},
            {
              'role': 'assistant',
              'content':
                  '| Column A | Column B | Column C |\n'
                  '| --- | --- | --- |\n'
                  '| a very long value that cannot fit | another long value | third |',
            },
          ],
        ),
      );
      await tester.pump();
      // flutter_markdown_plus 只在 IntrinsicColumnWidth/FixedColumnWidth 时
      // 给表格套横向 SingleChildScrollView；这是「宽表格不被裁切」的实现依据。
      final horizontalScrolls = find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      );
      expect(horizontalScrolls, findsWidgets);
      expect(find.byType(MarkdownBody), findsWidgets);
      await _teardownPanel(tester);
    });

    testWidgets('plain replies and text blocks both render markdown', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpPanel(
        tester,
        _testPanel(
          initialMessages: const [
            {'role': 'user', 'content': 'plain markdown?'},
            {'role': 'assistant', 'content': '# Heading\n\n- item one'},
            {'role': 'user', 'content': 'block markdown?'},
            {
              'role': 'assistant',
              'content': '# Block Heading',
              'blocks': [
                {'type': 'text', 'text': '# Block Heading'},
              ],
            },
          ],
        ),
      );
      await tester.pump();
      // blocks 为 null 的普通回复 + 带 text 块的回复（老历史）都必须走
      // MarkdownBody，不能退化成 SelectableText 纯文本。
      expect(find.byType(MarkdownBody), findsWidgets);
      await _teardownPanel(tester);
    });

    testWidgets('mobile sheet renders a single-row header + full-height sidebar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpPanel(
        tester,
        _testPanel(mobileSheet: true, onCloseRequested: () {}),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 单行 header：历史 / 标题 / 模型 chip / 工具 / 关闭 在同一颗药丸里，
      // 不再有宿主第二行模型药丸。
      expect(
        find.byKey(const ValueKey('ai-mobile-sheet-header')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ai-mobile-model-chip')),
        findsOneWidget,
      );

      // 侧栏挂在面板根 Stack（全高覆盖层），而不是缩在消息区里的半高抽屉；
      // 分段标签改成竖排 + FittedBox(scaleDown)，窄屏/大字号不出现省略号。
      expect(find.byKey(const ValueKey('ai-mobile-sidebar')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-mobile-sidebar-tabs')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _teardownPanel(tester);
    });
  });
}
