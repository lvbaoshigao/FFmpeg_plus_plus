// 移动端 AI/MCP 提供商界面冒烟测试：
// 1. 提供商详情页带壁纸背景（修复「提供商界面没有壁纸」）
// 2. 底部「配置/模型」选项卡跟随全局导航样式（主题绑定）
// 3. AI 高级设置页 / 移动端 AI 设置内容可构建
//
// 注意：testWidgets 是 FakeAsync 环境，真实文件 IO 与图片解码必须包在
// tester.runAsync 里，否则 await 永不完成（测试 10 分钟超时）。
import 'dart:io';

import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/mobile_bottom_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _harness(AppState state, Widget child) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: child),
      ),
    );

/// 消化 ConfigService.update 的 400ms 防抖保存 Timer，
/// 避免测试收尾报「Pending timers」。
Future<void> _flushSaveTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('提供商详情页带壁纸 + 主题化选项卡', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 真实 IO：复制项目里现成的 PNG 作为壁纸文件（唯一文件名避免并行冲突）
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final File png = await tester.runAsync<File>(() async {
      final src = File('rele/icon.png');
      final dst =
          File('${Directory.systemTemp.path}/ai_wall_$stamp.png');
      if (await dst.exists()) await dst.delete();
      return src.copy(dst.path);
    }) as File;
    addTearDown(() => tester.runAsync(() async {
          if (await png.exists()) await png.delete();
        }));

    final state = AppState();
    state.updateConfig((c) => c
      ..backgroundImage = png.path
      ..backgroundOpacity = 0.5
      ..cardStyle = 'gray'
      ..navStyle = 'liquid');

    await tester.pumpWidget(
        _harness(state, const MobileAiProviderDetailPage()));
    // 等真实图片解码完成后重建
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 壁纸：withWallpaper 里铺的壁纸 Image 应存在
    expect(find.byType(Image), findsWidgets);
    // 底部「配置 / 模型」选项卡跟随全局导航样式渲染
    expect(find.byType(MobileNavStyleTabBar), findsOneWidget);
    expect(find.text('配置'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);

    // 切到「模型」选项卡可构建（内容区标题与选项卡标签都含「模型」二字）
    await tester.tap(find.text('模型'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('模型'), findsWidgets);
    await _flushSaveTimers(tester);
  });

  testWidgets('AI 高级设置页可构建', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c..navStyle = 'gray');
    await tester.pumpWidget(_harness(state, const MobileAiAdvancedPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('高级'), findsOneWidget);
    await _flushSaveTimers(tester);
  });

  testWidgets('移动端 AI 设置内容（提供商列表入口）可构建', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c..cardStyle = 'gray');
    await tester.pumpWidget(_harness(
        state,
        Builder(
          builder: (ctx) => SingleChildScrollView(
              child: mobileAiSettingsContent(ctx, state)),
        )));
    await tester.pump();
    expect(find.byType(MobileAiProviderDetailPage), findsNothing);
    await _flushSaveTimers(tester);
  });
}
