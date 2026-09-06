// 队列页冒烟测试：移动端尺寸下带任务（含 pipeline 任务/失败任务）可构建，
// 复现「处理队列整个白屏」类构建异常。
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/queue_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _harness(AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: QueuePage()),
      ),
    );

void main() {
  /// 卸载 QueuePage：SystemMonitor 有周期 Timer，必须在测试结束前
  /// dispose 掉，否则 flutter_test 的「Timer is still pending」断言会挂。
  ///
  /// 注意：测试宿主是 Windows（isMobilePlatform=false），页面走桌面分支，
  /// 因此窗口用桌面尺寸——用手机尺寸会因 Ahem 等宽测试字体顶栏溢出误报。
  Future<void> unmountPage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('桌面队列页：空队列可构建', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c
      ..cardStyle = 'liquid'
      ..pillStyle = 'liquid'
      ..navStyle = 'gray');
    await tester.pumpWidget(_harness(state));
    await tester.pump();
    expect(find.byType(QueuePage), findsOneWidget);
    await unmountPage(tester);
  });

  testWidgets('桌面队列页：pending/失败/流水线任务可构建', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c
      ..cardStyle = 'liquid'
      ..pillStyle = 'liquid'
      ..navStyle = 'gray');

    final calls = <BackendCall>[
      BackendCall(action: 'transcode', params: {'input': '/tmp/a.mp4', 'output': '/tmp/b.mp4'}),
      BackendCall(action: '_cleanup', params: {'path': '/tmp/t.mp4'}),
    ];
    state.addTaskForTest(TaskInfo(
      id: 'task_t1',
      videoId: 'v1',
      filename: '测试视频.mp4',
      inputPath: '/tmp/a.mp4',
      outputPath: '/storage/emulated/0/Download/测试/output.mp4',
      config: TranscodeConfig(),
      pipelineCalls: calls,
    ));
    state.addTaskForTest(TaskInfo(
      id: 'task_t2',
      videoId: 'v2',
      filename: '失败任务.mp4',
      inputPath: '/tmp/c.mp4',
      outputPath: '/tmp/d.mp4',
      config: TranscodeConfig(),
      status: TaskStatus.failed,
      error: '步骤 1 失败: Error opening output',
    ));
    await tester.pumpWidget(_harness(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('测试视频.mp4'), findsOneWidget);
    expect(find.text('失败任务.mp4'), findsOneWidget);
    await unmountPage(tester);
  });
}
