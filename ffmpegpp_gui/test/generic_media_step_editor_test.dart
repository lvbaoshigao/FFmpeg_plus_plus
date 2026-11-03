import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/generic_step_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('generic media type is selected with the shared dropdown', (
    tester,
  ) async {
    final node = PipelineNode(
      id: 'generic',
      type: PipelineStepType.mediaConvert,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GenericMediaStepEditor(node: node, onChanged: () {}),
        ),
      ),
    );

    expect(find.text('媒体类型（必选）'), findsOneWidget);
    expect(find.text('选择媒体类型'), findsOneWidget);
    expect(find.text('请选择'), findsOneWidget);
    expect(find.byType(SegmentedButton<MediaType>), findsNothing);
  });
}
