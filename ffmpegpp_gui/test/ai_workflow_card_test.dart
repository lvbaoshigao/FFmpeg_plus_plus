import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/ai_workflow_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  group('AiWorkflowCard', () {
    testWidgets('should show process while active and collapse when finished', (
      tester,
    ) async {
      final state = AppState();
      Widget build(bool active) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: AiWorkflowCard(
              active: active,
              summary: 'Workflow',
              style: 'gray',
              process: const Text('Thinking and tools'),
              answer: const Text('Final answer'),
            ),
          ),
        ),
      );
      await tester.pumpWidget(build(true));
      expect(find.text('Thinking and tools'), findsOneWidget);
      expect(find.text('Final answer'), findsOneWidget);
      await tester.pumpWidget(build(false));
      expect(find.text('Thinking and tools'), findsNothing);
      expect(find.text('Final answer'), findsOneWidget);
      await tester.tap(find.text('Workflow'));
      await tester.pump();
      expect(find.text('Thinking and tools'), findsOneWidget);
      expect(find.text('Final answer'), findsOneWidget);
    });
  });
}
