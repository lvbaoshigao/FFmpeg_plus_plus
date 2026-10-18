import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/task_card.dart';
import 'package:ffmpegpp_gui/widgets/task_float_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class QueueState extends AppState {
  List<TaskInfo> items = [];
  int version = 0;
  final List<String> stopped = [];
  final List<String> expanded = [];
  @override
  void toggleTaskExpanded(String id) {
    expanded.add(id);
  }

  @override
  List<TaskInfo> get tasks => items;
  @override
  int get tasksVersion => version;
  void replace(List<TaskInfo> tasks) {
    items = tasks;
    version++;
    notifyListeners();
  }

  @override
  void cancelTask(String id) {
    stopped.add(id);
  }

  final List<String> pausedCalls = [];
  final List<String> resumedCalls = [];
  bool pauseResult = true;
  bool resumeResult = true;

  @override
  Future<bool> pauseTask(String id) async {
    pausedCalls.add(id);
    return pauseResult;
  }

  @override
  Future<bool> resumeTask(String id) async {
    resumedCalls.add(id);
    return resumeResult;
  }
}

TaskInfo task(String id, {TaskStatus status = TaskStatus.pending}) => TaskInfo(
  id: id,
  videoId: id,
  filename: '✨_7 clip.mp4',
  inputPath: '/tmp/missing.mp4',
  outputPath: '/tmp/output.mp4',
  config: TranscodeConfig(),
  status: status,
  pipelineCalls: [
    BackendCall(action: 'transcode', params: {}),
    BackendCall(action: '_cleanup', params: {}),
  ],
);

Widget harness(QueueState state, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('TaskFloatLayer', () {
    test('should skip symbols and support Unicode letters and numbers', () {
      expect(taskDockInitial('✨_7 clip.mp4'), '7');
      expect(taskDockInitial('—测试.mp4'), '测');
      expect(taskDockInitial('!éclair.mp4'), 'É');
      expect(taskDockInitial('___'), '?');
    });
    testWidgets('should minimize restore and hide without stopping task', (
      tester,
    ) async {
      final state = QueueState()..replace([task('one')]);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        harness(
          state,
          const Stack(children: [Positioned.fill(child: TaskFloatLayer())]),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('task-minimize-one')));
      await tester.pump();
      expect(find.byKey(const ValueKey('task-dock-one')), findsOneWidget);
      expect(find.byKey(const ValueKey('task-hide-one')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('task-dock-one')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('task-hide-one')));
      await tester.pump();
      expect(find.byKey(const ValueKey('task-dock-one')), findsNothing);
      expect(state.stopped, isEmpty);
      state.replace([task('one', status: TaskStatus.processing)]);
      await tester.pump();
      expect(find.byKey(const ValueKey('task-hide-one')), findsNothing);
    });
    testWidgets('should pass outside taps through and remove terminal tasks', (
      tester,
    ) async {
      final state = QueueState()..replace([task('one')]);
      addTearDown(state.dispose);
      var taps = 0;
      await tester.pumpWidget(
        harness(
          state,
          Stack(
            children: [
              Align(
                alignment: Alignment.bottomLeft,
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text('Underlying'),
                ),
              ),
              const Positioned.fill(child: TaskFloatLayer()),
            ],
          ),
        ),
      );
      await tester.tap(find.text('Underlying'));
      expect(taps, 1);
      state.replace([
        task(
          'one',
          status: TaskStatus.processing,
        ).copyWith(progress: 67, elapsed: '00:12'),
      ]);
      await tester.pump();
      expect(find.text('67%'), findsOneWidget);
      state.replace([task('one', status: TaskStatus.completed)]);
      await tester.pump();
      expect(find.byKey(const ValueKey('task-hide-one')), findsNothing);
      state.replace([task('one')]);
      await tester.pump();
      expect(find.byKey(const ValueKey('task-hide-one')), findsOneWidget);
    });
    testWidgets('should clamp dragging and resizing to layer bounds', (
      tester,
    ) async {
      final state = QueueState()..replace([task('one')]);
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        harness(
          state,
          const Stack(children: [Positioned.fill(child: TaskFloatLayer())]),
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('task-drag-one')),
        const Offset(2000, 2000),
      );
      await tester.pump();
      tester.view.physicalSize = const Size(400, 300);
      await tester.pump();
      final rect = tester.getRect(
        find.byKey(const ValueKey('task-float-position-one')),
      );
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(400));
      expect(rect.bottom, lessThanOrEqualTo(300));
    });
  });
  group('TaskCard', () {
    testWidgets('should retain desktop inline expansion', (tester) async {
      final state = QueueState()..replace([task('one')]);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        harness(
          state,
          TaskCard(task: state.tasks.first, detailsInSheet: false),
        ),
      );
      await tester.tap(find.text('✨_7 clip.mp4'));
      await tester.pump();
      expect(state.expanded, ['one']);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('should open a live mobile sheet without inline expansion', (
      tester,
    ) async {
      final state = QueueState()..replace([task('one')]);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        harness(state, TaskCard(task: state.tasks.first, detailsInSheet: true)),
      );
      await tester.tap(find.text('✨_7 clip.mp4'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(TaskDetails), findsOneWidget);
      expect(state.tasks.first.expanded, isFalse);
      state.replace([
        task('one', status: TaskStatus.processing).copyWith(progress: 42),
      ]);
      await tester.pump();
      expect(find.text('42%'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('should not open a sheet when stop is tapped', (tester) async {
      final state = QueueState()
        ..replace([task('one', status: TaskStatus.processing)]);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        harness(state, TaskCard(task: state.tasks.first, detailsInSheet: true)),
      );
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(state.stopped, ['one']);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('移动端运行卡片同时提供「暂停」和「停止」', (tester) async {
      final state = QueueState()
        ..replace([task('one', status: TaskStatus.processing)]);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        harness(state, TaskCard(task: state.tasks.first, detailsInSheet: true)),
      );
      // 两个按钮都在，且点击不会误开详情面板
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('停止'), findsOneWidget);
      await tester.tap(find.text('暂停'));
      await tester.pump();
      expect(state.pausedCalls, ['one']);
      expect(state.stopped, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('停止'));
      await tester.pump();
      expect(state.stopped, ['one']);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('已暂停任务显示「继续」+「停止」，状态文案与图标不再是处理中', (
      tester,
    ) async {
      final state = QueueState()..replace([
        task('one', status: TaskStatus.paused).copyWith(progress: 55),
      ]);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        harness(state, TaskCard(task: state.tasks.first, detailsInSheet: false)),
      );
      // 折叠卡的展开区也被 AnimatedCrossFade 预先构建，所以状态文案会在
      // 卡片头部 / 概览条 / 图例里各出现一次 —— 用 findsWidgets 断言存在性。
      expect(find.text('已暂停'), findsWidgets);
      expect(find.byIcon(Icons.pause_circle_outline), findsWidgets);
      expect(find.byIcon(Icons.sync), findsNothing);
      expect(find.text('继续'), findsOneWidget);
      // 暂停卡片仍然显示进度条与百分比（冻结在 55%），而不是空进度
      expect(find.text('55%'), findsWidgets);
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(state.resumedCalls, ['one']);
      expect(find.text('继续'), findsOneWidget); // 真实状态未变（测试替身不改列表）
      await tester.pumpWidget(const SizedBox.shrink());
    });

  });

  group('TaskFloatLayer paused', () {
    testWidgets('已暂停任务不会从悬浮层消失，并可在此继续', (tester) async {
      final state = QueueState()..replace([
        task('one', status: TaskStatus.paused).copyWith(progress: 33),
      ]);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        harness(
          state,
          const Stack(children: [Positioned.fill(child: TaskFloatLayer())]),
        ),
      );
      expect(find.byKey(const ValueKey('task-hide-one')), findsOneWidget);
      expect(find.byKey(const ValueKey('task-pause-one')), findsOneWidget);
      expect(find.textContaining('已暂停'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('task-pause-one')));
      await tester.pump();
      expect(state.resumedCalls, ['one']);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
