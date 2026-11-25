import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:ffmpegpp_gui/widgets/polygon_morph_loader.dart';
import 'package:ffmpegpp_gui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

TaskInfo _imageTask() => TaskInfo(
  id: 'image-task',
  videoId: 'image',
  filename: 'source.png',
  inputPath: '/tmp/ffpp-progress-missing-source.png',
  outputPath: '/tmp/ffpp-progress-output.webp',
  config: TranscodeConfig(),
  status: TaskStatus.processing,
  progress: 50,
  currentCallIndex: 1,
  pipelineCalls: [
    BackendCall(action: 'image_scale', params: {}),
    BackendCall(action: 'image_convert', params: {}),
  ],
  callProgresses: const [1, 0],
  remaining: '00:03:05',
);

Future<void> _mount(
  WidgetTester tester,
  AppState state,
  Widget child, {
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 600, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late AppState state;

  setUp(() {
    state = AppState()..config.language = 'en';
  });
  tearDown(() => state.dispose());

  testWidgets('image step hides synthetic percent, stale ETA, and bars', (
    tester,
  ) async {
    await _mount(
      tester,
      state,
      TaskCard(task: _imageTask(), detailsInSheet: true),
    );

    expect(find.byType(PolygonMorphLoader), findsOneWidget);
    expect(find.byType(AppProgressBar), findsNothing);
    expect(find.text('50%'), findsNothing);
    expect(find.textContaining('00:03:05'), findsNothing);
    expect(find.text('Step 2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a real current-step sample replaces the loader and computes overall percent',
    (tester) async {
      final task = _imageTask();
      await _mount(tester, state, TaskCard(task: task, detailsInSheet: true));
      expect(find.byType(PolygonMorphLoader), findsOneWidget);

      await _mount(
        tester,
        state,
        TaskCard(
          task: task.copyWith(callProgresses: const [1, 0.4], progress: 40),
          detailsInSheet: true,
        ),
      );

      expect(find.byType(PolygonMorphLoader), findsNothing);
      expect(
        tester.widget<AppProgressBar>(find.byType(AppProgressBar)).value,
        0.4,
      );
      expect(find.text('70%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('paused unknown progress uses a static solid loader', (
    tester,
  ) async {
    await _mount(
      tester,
      state,
      TaskCard(
        task: _imageTask().copyWith(status: TaskStatus.paused),
        detailsInSheet: true,
      ),
    );

    final loader = tester.widget<PolygonMorphLoader>(
      find.byType(PolygonMorphLoader),
    );
    expect(loader.reduceMotion, isTrue);
    expect(loader.hollow, isFalse);
    expect(find.byType(AppProgressBar), findsNothing);
    expect(find.text('50%'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('processing loader preserves the system reduced-motion setting', (
    tester,
  ) async {
    await _mount(
      tester,
      state,
      TaskCard(task: _imageTask(), detailsInSheet: true),
      reducedMotion: true,
    );

    expect(
      tester
          .widget<PolygonMorphLoader>(find.byType(PolygonMorphLoader))
          .reduceMotion,
      isNull,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('completion fills the bar even without a final heartbeat', (
    tester,
  ) async {
    await _mount(
      tester,
      state,
      TaskCard(
        task: _imageTask().copyWith(status: TaskStatus.completed),
        detailsInSheet: true,
      ),
    );

    expect(find.byType(PolygonMorphLoader), findsNothing);
    expect(tester.widget<AppProgressBar>(find.byType(AppProgressBar)).value, 1);
    expect(find.text('100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'expanded details also hide unknown percent and stale remaining time',
    (tester) async {
      await _mount(
        tester,
        state,
        SingleChildScrollView(
          child: TaskDetails(task: _imageTask(), mobile: false),
        ),
      );

      expect(find.text('50%'), findsNothing);
      expect(find.textContaining('00:03:05'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
