// 移动端 AI/MCP 提供商界面冒烟测试：
// 1. 提供商详情页带壁纸背景（修复「提供商界面没有壁纸」）
// 2. 顶部「基本/模型」选项卡使用顶部药丸样式（主题绑定）
// 3. AI 高级设置页 / 移动端 AI 设置内容可构建
//
// 注意：testWidgets 是 FakeAsync 环境，真实文件 IO 与图片解码必须包在
// tester.runAsync 里，否则 await 永不完成（测试 10 分钟超时）。
import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_control_size.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _harness(AppState state, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(useThemeColor: state.config.useThemeColor),
        home: Scaffold(body: child),
      ),
    );

/// 消化 ConfigService.update 的 400ms 防抖保存 Timer，
/// 避免测试收尾报「Pending timers」。
Future<void> _flushSaveTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('MobileAiProviderDetailPage narrow form', () {
    for (final isNew in [true, false]) {
      testWidgets(
        'should size controls and save ${isNew ? "new" : "existing"} provider at 320px',
        (tester) async {
          tester.view.physicalSize = const Size(320, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final state = AppState();
          final profile = AiProfile(id: 'narrow', name: 'Original');
          state.updateConfig(
            (c) => c
              ..language = 'en'
              ..useThemeColor = false
              ..aiProfiles = isNew ? [] : [profile],
          );
          await tester.pumpWidget(
            _harness(
              state,
              MobileAiProviderDetailPage(profileId: isNew ? null : profile.id),
            ),
          );
          await tester.pumpAndSettle();

          final menu = find.byType(OptionMenuBar<String>).first;
          expect(tester.getSize(menu).height, AppControlSize.large.height);
          final scrollable = find
              .descendant(
                of: find.byKey(const ValueKey('ai_provider_config')),
                matching: find.byType(Scrollable),
              )
              .first;

          // 「是否启用」是基本页第一颗开关：先在页首切掉。
          await tester.tap(find.byType(Switch).first);
          await tester.pumpAndSettle();
          expect(
            tester.widget<Switch>(find.byType(Switch).first).value,
            isFalse,
          );
          expect(tester.takeException(), isNull);

          await tester.scrollUntilVisible(
            find.text('Name'),
            180,
            scrollable: scrollable,
          );
          final name = find.byType(TextField).first;
          await tester.ensureVisible(name);
          await tester.enterText(name, 'Narrow provider');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          final fields = find.byType(TextField);
          final inputColor = tester
              .widget<TextField>(fields.first)
              .style!
              .color!;
          expect(inputColor.r, closeTo(inputColor.g, 1 / 255));
          expect(inputColor.g, closeTo(inputColor.b, 1 / 255));
          final nameHeight = tester.getSize(fields.at(0)).height;
          final keyHeight = tester.getSize(fields.at(1)).height;
          expect(nameHeight, greaterThanOrEqualTo(AppControlSize.large.height));
          expect(keyHeight, closeTo(nameHeight, 0.1));
          for (final field in fields.evaluate()) {
            final rect = tester.getRect(find.byWidget(field.widget));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(320));
          }
          // 「管理」卡在首屏之外，ListView 惰性构建：继续向下滚到 Group 再量行高。
          await tester.scrollUntilVisible(
            find.text('Group'),
            180,
            scrollable: scrollable,
          );
          final groupRow = find.ancestor(
            of: find.text('Group'),
            matching: find.byType(InkWell),
          );
          expect(
            tester.getSize(groupRow.first).height,
            greaterThanOrEqualTo(AppControlSize.large.height),
          );
          await tester.scrollUntilVisible(
            find.byType(TextButton).last,
            180,
            scrollable: scrollable,
          );
          expect(
            tester.getSize(find.byType(TextButton).last).height,
            greaterThanOrEqualTo(AppControlSize.large.height),
          );
          expect(tester.takeException(), isNull);

          await tester.tap(find.text('Models'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('ai_provider_models')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Basic'));
          await tester.pumpAndSettle();
          final save = tester.widget<MobileGlassPillAction>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is MobileGlassPillAction &&
                  widget.icon == Icons.check_rounded,
            ),
          );
          save.onTap!();
          await tester.pump();
          await tester.pump(const Duration(seconds: 3));
          expect(state.config.aiProfiles.single.name, 'Narrow provider');
          expect(state.config.aiProfiles.single.enabled, isFalse);
          expect(tester.takeException(), isNull);
          await _flushSaveTimers(tester);
        },
      );
    }
  });
  testWidgets('提供商详情页带壁纸 + 主题化选项卡', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 真实 IO：复制项目里现成的 PNG 作为壁纸文件（唯一文件名避免并行冲突）
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final File png =
        await tester.runAsync<File>(() async {
              final src = File('rele/icon.png');
              final dst = File(
                '${Directory.systemTemp.path}/ai_wall_$stamp.png',
              );
              if (await dst.exists()) await dst.delete();
              return src.copy(dst.path);
            })
            as File;
    addTearDown(
      () => tester.runAsync(() async {
        if (await png.exists()) await png.delete();
      }),
    );

    final state = AppState();
    state.updateConfig(
      (c) => c
        ..backgroundImage = png.path
        ..backgroundOpacity = 0.5
        ..cardStyle = 'gray'
        ..navStyle = 'liquid',
    );

    await tester.pumpWidget(
      _harness(state, const MobileAiProviderDetailPage()),
    );
    // 等真实图片解码完成后重建
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 壁纸：withWallpaper 里铺的壁纸 Image 应存在
    expect(find.byType(Image), findsWidgets);
    // 设计稿改为底部小药丸：分段控件位于内容区下方，不再占用顶部。
    expect(find.byKey(const ValueKey('ai_provider_top_tabs')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('ai_provider_top_tabs'))).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byKey(const ValueKey('ai_provider_config'))).dy,
      ),
    );
    expect(find.text('基本'), findsOneWidget);
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

  testWidgets('request URL preview follows the path while typing', (
    tester,
  ) async {
    final state = AppState();
    final profile = AiProfile(
      name: 'OpenAI',
      provider: 'openai',
      apiKey: 'sk-test',
      apiUrl: 'https://api.openai.com/v1',
      apiPath: '/chat/completions',
    );
    profile.models.add(AiModelEntry(id: 'gpt-6'));
    state.updateConfig((c) {
      c.aiProfiles.add(profile);
      c.activeAiProfileId = profile.id;
      return c;
    });
    await tester.pumpWidget(
      _harness(state, MobileAiProviderDetailPage(profileId: profile.id)),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('https://api.openai.com/v1/chat/completions'),
      findsWidgets,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai_request_path')),
      '/custom',
    );
    await tester.pump();
    expect(
      find.textContaining('https://api.openai.com/v1/custom'),
      findsWidgets,
    );
    await _flushSaveTimers(tester);
  });

  testWidgets('disabling active provider clears the active selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    final active = AiProfile(id: 'active', name: 'Active', enabled: true);
    state.updateConfig(
      (c) => c
        ..aiProfiles = [active]
        ..activeAiProfileId = active.id,
    );
    final fallback = AiProfile(id: 'fallback', name: 'Fallback', enabled: true);
    state.updateConfig((c) => c..aiProfiles.add(fallback));
    await tester.pumpWidget(
      _harness(state, const MobileAiProviderDetailPage(profileId: 'active')),
    );
    await tester.pump();
    await tester.tap(find.text('基本'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(Switch).at(0));
    await tester.pump();
    expect(state.config.activeAiProfileId, active.id);
    final saveAction = tester.widget<MobileGlassPillAction>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MobileGlassPillAction &&
            widget.icon == Icons.check_rounded,
      ),
    );
    saveAction.onTap!();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(state.config.activeAiProfileId, fallback.id);
    expect(
      state.config.aiProfiles.singleWhere((p) => p.id == active.id).enabled,
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await _flushSaveTimers(tester);
  });

  testWidgets('narrow AI/MCP settings fit without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c..mcpEnabled = true);
    await tester.pumpWidget(
      _harness(
        state,
        Builder(
          builder: (ctx) =>
              SingleChildScrollView(child: mobileAiSettingsContent(ctx, state)),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await _flushSaveTimers(tester);
  });

  testWidgets('移动端 AI 设置内容（提供商列表入口）可构建', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c..cardStyle = 'gray');
    await tester.pumpWidget(
      _harness(
        state,
        Builder(
          builder: (ctx) =>
              SingleChildScrollView(child: mobileAiSettingsContent(ctx, state)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(MobileAiProviderDetailPage), findsNothing);
    expect(find.text('提供商'), findsOneWidget);
    await tester.tap(find.text('提供商'));
    await tester.pumpAndSettle();
    expect(find.byType(MobileAiProvidersPage), findsOneWidget);
    await _flushSaveTimers(tester);
  });

  testWidgets('提供商搜索：模型 / 名称 / 加载 / 无结果 / 清空', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    final openAi = AiProfile(
      name: 'OpenAI',
      provider: 'openai',
      model: 'gpt-4o',
    );
    openAi.models.addAll([
      AiModelEntry(id: 'gpt-4o'),
      AiModelEntry(id: 'gpt-4o-mini'),
      AiModelEntry(id: 'o3'),
    ]);
    final claude = AiProfile(
      name: 'Claude',
      provider: 'anthropic',
      model: 'claude-3.5-sonnet',
    );
    claude.models.addAll([
      AiModelEntry(id: 'claude-3.5-sonnet'),
      AiModelEntry(id: 'claude-3-opus'),
    ]);
    final custom = AiProfile(name: '自定义提供商', provider: 'openai');
    custom.models.add(AiModelEntry(id: 'my-model'));
    state.updateConfig((c) {
      c.aiProfiles.addAll([openAi, claude, custom]);
      c.activeAiProfileId = openAi.id;
      c.cardStyle = 'gray';
      c.pillStyle = 'gray';
      return c;
    });

    await tester.pumpWidget(
      _harness(state, MobileAiProvidersPage(state: state)),
    );
    await tester.pumpAndSettle();
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('自定义提供商'), findsOneWidget);
    // 非搜索态不展示模型 chips，保持列表紧凑（对应设计稿的提供商列表页）。
    expect(find.text('gpt-4o'), findsNothing);

    final search = find.byKey(const ValueKey('ai_provider_search'));
    expect(search, findsOneWidget);

    // 模型搜索：输入 gpt4 应命中 gpt-4o（忽略连字符）
    await tester.enterText(search, 'gpt4');
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('正在搜索中...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('搜索结果 (1)'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Claude'), findsNothing);
    expect(find.text('gpt-4o'), findsWidgets);
    expect(find.text('gpt-4o-mini'), findsOneWidget);

    // 名称搜索：模型不匹配但提供商名匹配时仍展示该提供商
    await tester.enterText(search, 'claude');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('OpenAI'), findsNothing);
    expect(find.text('claude-3.5-sonnet'), findsOneWidget);

    // 无结果态 + 清空恢复完整列表
    await tester.enterText(search, 'xyz123');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('未找到相关结果'), findsOneWidget);
    expect(find.text('清空搜索'), findsOneWidget);
    await tester.tap(find.text('清空搜索'));
    await tester.pumpAndSettle();
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('自定义提供商'), findsOneWidget);

    await _flushSaveTimers(tester);
  });
}
