// 队列「真实暂停 / 继续」的聚焦测试。
//
// 覆盖三块：
//   1) AppState.pauseTask / resumeTask 的状态机 —— 关键点是「没有可冻结进程时
//      绝不允许把状态改成 paused」（不产生假暂停）；
//   2) 恢复持久化任务时 paused 的安全落点（normalizeRestoredTask 纯函数）；
//   3) 移动端详情顶部 RunningNodeViewport 的「类地图」行为：放大到正在处理的
//      节点，且视野必须包含所有运行中的节点；以及 基本信息/高级 两栏布局。
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

TaskInfo _task(
  String id, {
  TaskStatus status = TaskStatus.processing,
  double progress = 0,
  String speed = '',
  List<double> callProgresses = const [],
  int currentCallIndex = 0,
  List<BackendCall>? pipelineCalls,
}) => TaskInfo(
  id: id,
  videoId: 'v-$id',
  filename: '暂停测试.mp4',
  inputPath: '/tmp/in.mp4',
  outputPath: '/tmp/out.mp4',
  config: TranscodeConfig(),
  status: status,
  progress: progress,
  speed: speed,
  callProgresses: callProgresses,
  currentCallIndex: currentCallIndex,
  pipelineCalls: pipelineCalls,
);

/// 只用于 TaskDetails / 视图测试的轻量 AppState 替身。
class _DetailState extends AppState {
  @override
  List<TaskInfo> get tasks => const [];
  @override
  int get tasksVersion => 0;
}

Widget _detailHarness(AppState state, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('AppState 真实暂停', () {
    test('没有可冻结进程时拒绝暂停，且不改状态（不产生假暂停）', () async {
      final state = AppState();
      addTearDown(state.dispose);
      var signalOk = false;
      state.pauseSignalForTest = (id, pause) async => signalOk;
      state.addTaskForTest(_task('t1'));

      expect(await state.pauseTask('t1'), isFalse);
      expect(state.tasks.single.status, TaskStatus.processing);
      signalOk = true;
      expect(await state.pauseTask('t1'), isTrue);
      expect(state.tasks.single.status, TaskStatus.paused);
    });

    test('暂停 → 继续 回到处理中，重复暂停/继续被拒绝', () async {
      final state = AppState();
      addTearDown(state.dispose);
      final signals = <String>[];
      state.pauseSignalForTest = (id, pause) async {
        signals.add('$id:${pause ? 'pause' : 'resume'}');
        return true;
      };
      state.addTaskForTest(_task('t1'));

      expect(await state.pauseTask('t1'), isTrue);
      expect(state.tasks.single.status, TaskStatus.paused);
      // 已经暂停：再次暂停不重复发信号
      expect(await state.pauseTask('t1'), isFalse);
      expect(await state.resumeTask('t1'), isTrue);
      expect(state.tasks.single.status, TaskStatus.processing);
      // 已经在跑：resume 无效
      expect(await state.resumeTask('t1'), isFalse);
      expect(signals, ['t1:pause', 't1:resume']);
    });

    test('暂停中的任务可被取消 / 移除，且立即从运行槽位释放', () async {
      final state = AppState();
      addTearDown(state.dispose);
      state.pauseSignalForTest = (id, pause) async => true;
      state.addTaskForTest(_task('t1'));
      await state.pauseTask('t1');

      state.cancelTask('t1');
      expect(state.tasks.single.status, TaskStatus.cancelled);

      final s2 = AppState();
      addTearDown(s2.dispose);
      s2.pauseSignalForTest = (id, pause) async => true;
      s2.addTaskForTest(_task('t2'));
      await s2.pauseTask('t2');
      s2.removeTask('t2');
      expect(s2.tasks, isEmpty);
    });

    test('暂停中的任务仍占运行槽位：顺序队列不会多拉一个 pending', () async {
      final state = AppState();
      addTearDown(state.dispose);
      state.config.maxConcurrentTasks = 1;
      state.pauseSignalForTest = (id, pause) async => true;
      state.addTaskForTest(_task('run'));
      state.markTaskRunningForTest('run');
      expect(await state.pauseTask('run'), isTrue);
      expect(state.tasks.single.status, TaskStatus.paused);
      // 暂停仍算「处理中」：顶部按钮/并发预算都以它为准
      expect(state.processing, isTrue);

      state.addTaskForTest(_task('queued', status: TaskStatus.pending));
      await state.processNextTask();
      expect(
        state.tasks.firstWhere((t) => t.id == 'queued').status,
        TaskStatus.pending,
        reason: '并发上限 1 已被暂停任务占住，不得再开新任务',
      );
    });

    test('pending / 终态任务不能暂停', () async {
      final state = AppState();
      addTearDown(state.dispose);
      state.pauseSignalForTest = (id, pause) async => true;
      state.addTaskForTest(_task('p', status: TaskStatus.pending));
      state.addTaskForTest(_task('c', status: TaskStatus.completed));
      expect(await state.pauseTask('p'), isFalse);
      expect(await state.pauseTask('c'), isFalse);
      expect(state.tasks.map((t) => t.status),
          [TaskStatus.pending, TaskStatus.completed]);
    });
  });

  group('恢复持久化任务的 paused 落点', () {
    test('paused 恢复为 pending：清空冻结心跳，保留其余数据', () {
      final t = _task(
        't1',
        status: TaskStatus.paused,
        progress: 87,
        speed: '12.5x',
        callProgresses: const [1.0, 0.4],
        currentCallIndex: 1,
        pipelineCalls: [BackendCall(action: 'transcode', params: {})],
      );
      final r = normalizeRestoredTask(t, zh: true);
      // 绝不能恢复成 paused：进程已不存在，resume 会找不到任何目标。
      expect(r.status, TaskStatus.pending);
      expect(r.progress, 0);
      expect(r.speed, '');
      expect(r.callProgresses, isEmpty);
      expect(r.currentCallIndex, 0);
      // 数据不丢
      expect(r.id, 't1');
      expect(r.filename, '暂停测试.mp4');
      expect(r.inputPath, '/tmp/in.mp4');
      expect(r.pipelineCalls, isNotEmpty);
    });

    test('processing 恢复为 cancelled 并注明中断', () {
      final r = normalizeRestoredTask(
        _task('t1', progress: 50, speed: '2x'),
        zh: true,
      );
      expect(r.status, TaskStatus.cancelled);
      expect(r.progress, 0);
      expect(r.speed, '');
      expect(r.error, '应用退出，处理中断');
    });

    test('其它状态原样返回', () {
      for (final st in [
        TaskStatus.pending,
        TaskStatus.completed,
        TaskStatus.failed,
        TaskStatus.cancelled,
      ]) {
        final t = _task('x', status: st, progress: 10);
        expect(identical(normalizeRestoredTask(t, zh: true), t), isTrue);
      }
    });
  });

  group('RunningNodeViewport（类地图视口）', () {
    List<BackendCall> calls(int n) =>
        [for (int i = 0; i < n; i++) BackendCall(action: 'transcode', params: {})];

    Widget host(Widget child, {double width = 360}) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: child)),
      ),
    );

    testWidgets('单个运行节点被放大并居中在视野内', (tester) async {
      final progresses = List<double>.filled(10, 0.0)..[7] = 0.4;
      await tester.pumpWidget(
        host(
          RunningNodeViewport(
            calls: calls(10),
            progresses: progresses,
            currentIndex: 7,
            status: TaskStatus.processing,
            zh: true,
          ),
        ),
      );
      final viewport = tester.getRect(find.byType(RunningNodeViewport));
      final node = tester.getRect(find.byKey(const ValueKey('viewport-node-7')));
      // 放大：单节点时接近 1.25× 的 46dp 世界尺寸
      expect(node.width, greaterThan(45));
      // 居中
      expect(node.center.dx, closeTo(viewport.center.dx, 24));
      expect(node.left, greaterThanOrEqualTo(viewport.left - 0.5));
      expect(node.right, lessThanOrEqualTo(viewport.right + 0.5));
    });

    testWidgets('多个运行节点全部落在视野内（自动缩小）', (tester) async {
      final progresses = List<double>.filled(12, 0.0)
        ..[2] = 0.3
        ..[7] = 0.6;
      await tester.pumpWidget(
        host(
          RunningNodeViewport(
            calls: calls(12),
            progresses: progresses,
            currentIndex: 7,
            status: TaskStatus.processing,
            zh: true,
          ),
        ),
      );
      final viewport = tester.getRect(find.byType(RunningNodeViewport));
      final first = tester.getRect(find.byKey(const ValueKey('viewport-node-2')));
      final last = tester.getRect(find.byKey(const ValueKey('viewport-node-7')));
      expect(first.left, greaterThanOrEqualTo(viewport.left - 0.5));
      expect(last.right, lessThanOrEqualTo(viewport.right + 0.5));
      // 视野包含两个运行节点 → 比单节点时更小（zoom out）
      expect(first.width, lessThan(45));
    });

    testWidgets('暂停态在视口里用暂停图标而非「处理中」图标', (tester) async {
      await tester.pumpWidget(
        host(
          RunningNodeViewport(
            calls: calls(3),
            progresses: const [1.0, 0.4, 0.0],
            currentIndex: 1,
            status: TaskStatus.paused,
            zh: true,
          ),
        ),
      );
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
      expect(find.text('已暂停'), findsOneWidget);
    });
  });

  group('移动端详情布局', () {
    testWidgets('顶部运行节点视口 + 基本信息/高级两栏，字段不丢', (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = _DetailState();
      addTearDown(state.dispose);
      final detailTask = _task(
        't1',
        progress: 42,
        callProgresses: const [1.0, 0.4],
        currentCallIndex: 1,
        pipelineCalls: [
          BackendCall(action: 'transcode', params: {}),
          BackendCall(action: '_cleanup', params: {}),
        ],
      ).copyWith(
        command: const ['ffmpeg', '-i', '/tmp/in.mp4', '/tmp/out.mp4'],
        logLines: const ['frame=1 fps=24'],
        duration: 12.5,
        fps: '24',
        bitrate: '1200k',
        outputSize: 1024 * 1024,
      );
      await tester.pumpWidget(
        _detailHarness(
          state,
          SingleChildScrollView(child: TaskDetails(task: detailTask, mobile: true)),
        ),
      );
      await tester.pump();
      expect(find.byType(RunningNodeViewport), findsOneWidget);
      expect(find.text('基本信息'), findsOneWidget);
      expect(find.text('高级'), findsOneWidget);
      expect(find.text('文件信息'), findsOneWidget);
      expect(find.text('技术参数'), findsOneWidget);
      expect(find.text('处理流水线'), findsOneWidget);
      expect(find.text('高级信息'), findsOneWidget);
      expect(find.text('输入'), findsOneWidget);
      expect(find.text('输出'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('360dp 窄屏：两栏布局不溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = _DetailState();
      addTearDown(state.dispose);
      final detailTask = _task(
        't3',
        progress: 66,
        callProgresses: const [1.0, 0.6],
        currentCallIndex: 1,
        pipelineCalls: [
          BackendCall(action: 'transcode', params: {}),
          BackendCall(action: '_cleanup', params: {}),
        ],
      ).copyWith(
        command: const ['ffmpeg', '-i', '/tmp/in.mp4', '/tmp/out.mp4'],
        logLines: const ['frame=1 fps=24'],
        fps: '24',
        bitrate: '1200k',
        outputSize: 1024 * 1024,
        duration: 9,
      );
      await tester.pumpWidget(
        _detailHarness(
          state,
          SingleChildScrollView(child: TaskDetails(task: detailTask, mobile: true)),
        ),
      );
      await tester.pump();
      expect(find.text('基本信息'), findsOneWidget);
      expect(find.text('高级'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('桌面（mobile: false）保持单列内联展开，不出现视口', (tester) async {
      final state = _DetailState();
      addTearDown(state.dispose);
      final detailTask = _task(
        't2',
        progress: 10,
        pipelineCalls: [BackendCall(action: 'transcode', params: {})],
      );
      await tester.pumpWidget(
        _detailHarness(
          state,
          SingleChildScrollView(
            child: TaskDetails(task: detailTask, mobile: false),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(RunningNodeViewport), findsNothing);
      expect(find.text('基本信息'), findsNothing);
      expect(find.text('文件信息'), findsOneWidget);
    });
  });
}
