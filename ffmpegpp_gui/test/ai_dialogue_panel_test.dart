import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_strings.dart';
import 'package:ffmpegpp_gui/widgets/ai_workflow_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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
      expect(find.text('Final answer'), findsOneWidget);
      expect(find.text('Probe metadata'), findsNothing);
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(api!.exportMessages().first['blocks'], isNotEmpty);
      await tester.tap(find.text('Completed · 2 steps'));
      await tester.pump();
      expect(find.text('Final answer'), findsOneWidget);
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
            {'role': 'user', 'content': 'Question $i-abcdefghijklmnopqrstuvwxyz'},
            {'role': 'assistant', 'content': 'Answer $i-abcdefghijklmnopqrstuvwxyz'},
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

    testWidgets('should not show a stale model id that is absent from the provider', (
      tester,
    ) async {
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
    });
  });
}
