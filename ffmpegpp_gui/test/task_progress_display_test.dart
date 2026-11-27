import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/task_progress_display.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:ffmpegpp_gui/widgets/polygon_morph_loader.dart';
import 'package:ffmpegpp_gui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

TaskInfo _task({
  TaskStatus status = TaskStatus.processing,
  double progress = 0,
  List<BackendCall>? calls,
  List<double> callProgresses = const [],
  int currentCallIndex = 0,
  String elapsed = '',
  String remaining = '',
  String speed = '',
  int frame = 0,
}) => TaskInfo(
  id: 'progress-task',
  videoId: 'video',
  filename: 'input.png',
  inputPath: 'input.png',
  outputPath: 'output.webp',
  config: TranscodeConfig(),
  status: status,
  progress: progress,
  pipelineCalls: calls,
  callProgresses: callProgresses,
  currentCallIndex: currentCallIndex,
  elapsed: elapsed,
  remaining: remaining,
  speed: speed,
  frame: frame,
);

List<BackendCall> _calls(String first, [String? second]) => [
  BackendCall(action: first, params: const {}),
  if (second != null) BackendCall(action: second, params: const {}),
];

void main() {
  group('TaskProgressDisplay', () {
    test('does not infer a percentage from unknown-duration telemetry', () {
      final task = _task(
        elapsed: '00:00:08',
        remaining: '00:00:10',
        speed: '1.2x',
        frame: 80,
      );

      expect(TaskProgressDisplay.modeFor(task), TaskProgressMode.indeterminate);
      expect(TaskProgressDisplay.hasProgressSignal(task), isFalse);
      expect(TaskProgressDisplay.showsPercentage(task), isFalse);
      expect(TaskProgressDisplay.showsRemaining(task), isFalse);
      expect(TaskProgressDisplay.currentStepValue(task), isNull);
      expect(TaskProgressDisplay.overallValue(task), 0);
    });

    test('uses a real single-task percentage and remaining estimate', () {
      final task = _task(progress: 42, remaining: '00:10');

      expect(TaskProgressDisplay.modeFor(task), TaskProgressMode.determinate);
      expect(TaskProgressDisplay.showsPercentage(task), isTrue);
      expect(TaskProgressDisplay.showsRemaining(task), isTrue);
      expect(TaskProgressDisplay.currentStepValue(task), closeTo(0.42, 0.0001));
      expect(TaskProgressDisplay.overallValue(task), closeTo(0.42, 0.0001));
    });

    test('ignores synthetic overall progress after a prior pipeline step', () {
      final task = _task(
        calls: _calls('image_convert', 'image_scale'),
        currentCallIndex: 1,
        callProgresses: const [1.0, 0.0],
        progress: 50,
        elapsed: '00:03:05',
        remaining: '00:04:00',
        speed: '2x',
        frame: 120,
      );

      expect(TaskProgressDisplay.modeFor(task), TaskProgressMode.indeterminate);
      expect(TaskProgressDisplay.hasProgressSignal(task), isFalse);
      expect(TaskProgressDisplay.showsPercentage(task), isFalse);
      expect(TaskProgressDisplay.showsRemaining(task), isFalse);
      expect(TaskProgressDisplay.currentStepValue(task), isNull);
      expect(TaskProgressDisplay.overallValue(task), closeTo(0.5, 0.0001));
    });

    test('aggregates a non-first pipeline progress sample', () {
      final task = _task(
        calls: _calls('image_convert', 'transcode'),
        currentCallIndex: 1,
        callProgresses: const [1.0, 0.37],
        // Local ffmpeg parsing stores the current-call percentage here.
        progress: 37,
        remaining: '00:09',
      );

      expect(TaskProgressDisplay.modeFor(task), TaskProgressMode.determinate);
      expect(TaskProgressDisplay.currentStepValue(task), closeTo(0.37, 0.0001));
      expect(TaskProgressDisplay.overallValue(task), closeTo(0.685, 0.0001));
      expect(TaskProgressDisplay.showsRemaining(task), isTrue);
    });

    test('does not classify image-to-video by action name alone', () {
      final task = _task(
        calls: _calls('image_sequence'),
        callProgresses: const [0.25],
        progress: 25,
      );

      expect(TaskProgressDisplay.modeFor(task), TaskProgressMode.determinate);
      expect(TaskProgressDisplay.currentStepValue(task), 0.25);
    });

    test('paused tasks stay static with or without measured progress', () {
      final unknown = _task(
        status: TaskStatus.paused,
        calls: _calls('image_convert'),
      );
      expect(TaskProgressDisplay.modeFor(unknown), TaskProgressMode.paused);
      expect(TaskProgressDisplay.showsLoader(unknown), isTrue);
      expect(TaskProgressDisplay.animatesLoader(unknown), isFalse);

      final measured = _task(
        status: TaskStatus.paused,
        calls: _calls('transcode'),
        callProgresses: const [0.4],
        progress: 40,
      );
      expect(TaskProgressDisplay.modeFor(measured), TaskProgressMode.paused);
      expect(TaskProgressDisplay.showsLoader(measured), isFalse);
      expect(TaskProgressDisplay.currentStepValue(measured), 0.4);
      expect(TaskProgressDisplay.animatesLoader(measured), isFalse);
    });

    test('completed tasks are determinate even without a heartbeat', () {
      final task = _task(
        status: TaskStatus.completed,
        calls: _calls('image_convert', 'image_scale'),
      );

      expect(TaskProgressDisplay.modeFor(task), TaskProgressMode.determinate);
      expect(TaskProgressDisplay.showsPercentage(task), isTrue);
      expect(TaskProgressDisplay.currentStepValue(task), 1.0);
      expect(TaskProgressDisplay.overallValue(task), 1.0);
    });
    test('video to image returns to loader despite stale video telemetry', () {
      final video = _task(
        calls: _calls('transcode', 'image_convert'),
        progress: 20,
        callProgresses: const [0.4, 0],
        remaining: '00:20',
        speed: '2x',
        frame: 240,
      );
      expect(TaskProgressDisplay.showsDeterminate(video), isTrue);
      final image = video.copyWith(
        currentCallIndex: 1,
        callProgresses: const [1, 0],
        progress: 50,
      );
      expect(
        TaskProgressDisplay.modeFor(image),
        TaskProgressMode.indeterminate,
      );
      expect(TaskProgressDisplay.showsPercentage(image), isFalse);
      expect(TaskProgressDisplay.showsRemaining(image), isFalse);
    });

    test('uses expanded execution count and excludes cleanup stages', () {
      final task = _task(
        calls: _calls('transcode', '_cleanup'),
        currentCallIndex: 2,
        callProgresses: const [1, 1, 0.4],
        progress: 40,
      );
      expect(TaskProgressDisplay.overallValue(task), closeTo(0.8, 0.0001));
      expect(TaskProgressDisplay.currentStepValue(task), 0.4);
    });

    test(
      'execution logs do not create progress without a computed fraction',
      () {
        final task = _task().copyWith(
          command: ['ffmpeg', '-i', 'in.mp4', 'out.mp4'],
        );
        expect(TaskProgressDisplay.showsLoader(task), isTrue);
        expect(
          TaskProgressDisplay.showsDeterminate(task.copyWith(progress: 12)),
          isTrue,
        );
      },
    );

    test('invalid percentages and node indexes remain indeterminate', () {
      for (final value in [double.nan, double.infinity, -0.5, 0.0, 1.0]) {
        final task = _task(calls: _calls('transcode'), callProgresses: [value]);
        expect(TaskProgressDisplay.hasProgressSignal(task), isFalse);
      }
      expect(
        TaskProgressDisplay.hasProgressSignal(
          _task(
            calls: _calls('transcode'),
            currentCallIndex: -1,
            callProgresses: [0.4],
          ),
        ),
        isFalse,
      );
      expect(
        TaskProgressDisplay.hasProgressSignal(
          _task(
            calls: _calls('transcode'),
            currentCallIndex: 2,
            callProgresses: [0.4],
          ),
        ),
        isFalse,
      );
      for (final status in [
        TaskStatus.pending,
        TaskStatus.failed,
        TaskStatus.cancelled,
      ]) {
        expect(TaskProgressDisplay.showsLoader(_task(status: status)), isFalse);
        expect(
          TaskProgressDisplay.animatesLoader(_task(status: status)),
          isFalse,
        );
      }
    });

    testWidgets(
      'card switches loader to measured bar and returns for image step',
      (tester) async {
        final state = AppState();
        state.config.language = 'en';
        addTearDown(state.dispose);
        Widget host(TaskInfo task) => ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(body: TaskCard(task: task, detailsInSheet: true)),
          ),
        );
        final task = _task(calls: _calls('transcode', 'image_convert'));
        await tester.pumpWidget(host(task));
        expect(find.byType(PolygonMorphLoader), findsOneWidget);
        expect(find.byType(AppProgressBar), findsNothing);
        expect(find.textContaining('%'), findsNothing);
        expect(find.textContaining('Remaining'), findsNothing);
        expect(
          tester
              .widget<PolygonMorphLoader>(find.byType(PolygonMorphLoader))
              .reduceMotion,
          isNull,
        );

        await tester.pumpWidget(
          host(
            task.copyWith(
              progress: 20,
              callProgresses: [0.4, 0],
              remaining: '00:10',
            ),
          ),
        );
        expect(find.byType(PolygonMorphLoader), findsNothing);
        expect(find.byType(AppProgressBar), findsOneWidget);
        expect(
          tester.widget<AppProgressBar>(find.byType(AppProgressBar)).value,
          0.4,
        );
        expect(find.text('20%'), findsOneWidget);
        expect(find.textContaining('Remaining'), findsOneWidget);

        await tester.pumpWidget(
          host(
            task.copyWith(
              currentCallIndex: 1,
              progress: 50,
              callProgresses: [1, 0],
              remaining: '00:10',
            ),
          ),
        );
        expect(find.byType(PolygonMorphLoader), findsOneWidget);
        expect(find.byType(AppProgressBar), findsNothing);
        expect(find.textContaining('%'), findsNothing);
        expect(find.textContaining('Remaining'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('paused unknown card is static and completed card is full', (
      tester,
    ) async {
      final state = AppState();
      state.config.language = 'en';
      addTearDown(state.dispose);
      Widget host(TaskInfo task) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: TaskCard(task: task, detailsInSheet: true)),
        ),
      );
      final task = _task(
        calls: _calls('image_convert'),
        status: TaskStatus.paused,
      );
      await tester.pumpWidget(host(task));
      expect(
        tester
            .widget<PolygonMorphLoader>(find.byType(PolygonMorphLoader))
            .reduceMotion,
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(
        host(task.copyWith(status: TaskStatus.completed)),
      );
      expect(find.byType(PolygonMorphLoader), findsNothing);
      expect(find.text('100%'), findsOneWidget);
      expect(
        tester.widget<AppProgressBar>(find.byType(AppProgressBar)).value,
        1.0,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('detail summary has no fictitious percentage or remaining', (
      tester,
    ) async {
      final state = AppState();
      state.config.language = 'en';
      addTearDown(state.dispose);
      final task = _task(
        calls: _calls('image_convert', 'image_scale'),
        progress: 50,
        currentCallIndex: 1,
        callProgresses: [1, 0],
        remaining: '00:15',
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: TaskDetails(task: task, mobile: true),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(PolygonMorphLoader), findsOneWidget);
      expect(find.text('50%'), findsNothing);
      expect(find.textContaining('Remaining'), findsNothing);
      final currentNodeTooltip = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .where(
            (tooltip) => tooltip.message?.startsWith('Image Scale') == true,
          );
      expect(currentNodeTooltip, isNotEmpty);
      expect(
        currentNodeTooltip.every((tooltip) => !tooltip.message!.contains('0%')),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
