// 冒烟测试：
// 1. AppCard 四种表面样式（桌面分支）可构建
// 2. 共享 AI 设置内容 / 提供商详情页 / 高级页可构建
// 3. 卡片/底部菜单栏/顶部药丸样式的旧值迁移与 JSON 往返
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ads_page.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/pages/credits_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_card.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/mobile_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _harness(AppState state, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('desktop AI submenu and info pages use the shared glass header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c..cardStyle = 'gray');

    for (final page in [
      const MobileAiAdvancedPage(),
      const CreditsPage(),
      const AdsPage(),
    ]) {
      await tester.pumpWidget(_harness(state, page));
      await tester.pumpAndSettle();
      expect(find.byType(GlassTopBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('AppCard 四种样式可构建', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      _harness(
        state,
        SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              for (final style in SurfaceStyle.all)
                AppCard(
                  style: style,
                  radius: 16,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  child: const Text('card'),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('card'), findsNWidgets(SurfaceStyle.all.length));
  });

  testWidgets('共享 AI 设置内容可构建', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    // 用纯色样式避免测试环境里的 GPU shader
    state.updateConfig(
      (c) => c
        ..cardStyle = 'gray'
        ..pillStyle = 'gray'
        ..navStyle = 'gray'
        ..aiEnabled = true
        ..mcpEnabled = false,
    );
    final p1 = AiProfile(
      name: 'OpenAI 默认',
      provider: 'openai',
      model: 'gpt-4o',
    );
    final p2 = AiProfile(
      name: 'Claude',
      provider: 'anthropic',
      model: 'claude-sonnet-5',
    );
    state.updateConfig((c) {
      c.aiProfiles.addAll([p1, p2]);
      c.activeAiProfileId = p2.id;
      return c;
    });

    await tester.pumpWidget(
      _harness(
        state,
        SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Builder(builder: (ctx) => aiSettingsContent(ctx, state)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 一级页只保留「提供商」一个入口，具体列表在二级页。
    expect(find.text('提供商'), findsOneWidget);
    expect(find.text('权限'), findsOneWidget);
    expect(find.text('高级'), findsOneWidget);
    await tester.tap(find.text('提供商'));
    await tester.pumpAndSettle();
    expect(find.text('OpenAI 默认'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('添加提供商'), findsOneWidget);
    // 让配置落盘防抖定时器跑完，避免 Timer pending 断言
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('PC 端 AI 总览：仪表盘布局（状态带 + 提供商管理 + 权限/MCP/高级）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig(
      (c) => c
        ..cardStyle = 'gray'
        ..pillStyle = 'gray'
        ..aiEnabled = true
        ..mcpEnabled = false,
    );
    final p1 = AiProfile(
      name: 'OpenAI 默认',
      provider: 'openai',
      model: 'gpt-4o',
    );
    final p2 = AiProfile(
      name: 'Claude',
      provider: 'anthropic',
      model: 'claude-sonnet-5',
    );
    state.updateConfig((c) {
      c.aiProfiles.addAll([p1, p2]);
      c.activeAiProfileId = p1.id;
      return c;
    });

    Future<void> pumpAt(Size size) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        _harness(
          state,
          SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Builder(builder: (ctx) => aiSettingsContent(ctx, state)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 900 是两列布局的下边界：此时提供商面板退化为单列，不能溢出。
    await pumpAt(const Size(900, 900));
    expect(tester.takeException(), isNull);

    await pumpAt(const Size(1280, 900));
    // AI / MCP 两个总开关沿用同一批 Key，但现在落在「服务」卡内两行选项的
    // Switch 上（不再是状态带右上角两颗大块按钮）。
    expect(find.byKey(const ValueKey('ai_enabled_toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('mcp_enabled_toggle')), findsOneWidget);
    expect(
      tester.widget(find.byKey(const ValueKey('ai_enabled_toggle'))),
      isA<Switch>(),
    );
    expect(find.text('AI 助手'), findsWidgets);
    expect(find.text('AI 助手'), findsOneWidget);
    // MCP 行标题与右栏「MCP 服务」分组卡刻意区分开（避免 find.text 重复命中）。
    expect(find.text('MCP 服务'), findsWidgets);
    // 提供商管理区：标题 + 管理入口 + 两张提供商卡（名称 / 当前徽标）。
    expect(find.text('提供商'), findsOneWidget);
    expect(find.text('管理'), findsOneWidget);
    expect(find.text('OpenAI 默认'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    // 右栏三个分组：MCP 服务 / 权限 / 高级。
    expect(find.text('MCP 服务'), findsOneWidget);
    expect(find.text('权限'), findsOneWidget);
    expect(find.text('高级'), findsOneWidget);

    // 服务卡里的选项行可直接切换：AI 关闭后警告文案出现（状态带 + 卡内）。
    await tester.tap(find.byKey(const ValueKey('ai_enabled_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('AI 助手已停用，提供商不会参与对话'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('ai_enabled_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('AI 助手已停用，提供商不会参与对话'), findsNothing);

    // 快捷入口：点提供商卡直达详情页（不再是「只能进二级列表」）。
    await tester.tap(find.text('Claude'));
    await tester.pumpAndSettle();
    expect(find.byType(MobileAiProviderDetailPage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('提供商详情页（新建 + 编辑）可构建', (tester) async {
    // 详情页是长 ListView（惰性构建）：必须用竖屏手机视口，
    // 否则折叠区之下的字段（如「名称」）根本不会被 build，find 会漏。
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    state.updateConfig(
      (c) => c
        ..cardStyle = 'theme'
        ..pillStyle = 'gray',
    );
    final p = AiProfile(name: '测试提供商', provider: 'openai', model: 'gpt-4o');
    state.updateConfig((c) {
      c.aiProfiles.add(p);
      c.activeAiProfileId = p.id;
      return c;
    });

    // 新建页
    await tester.pumpWidget(
      _harness(state, const MobileAiProviderDetailPage()),
    );
    await tester.pumpAndSettle();
    // 名称字段标签已从「配置名」改为「名称」（ai_settings_mobile.dart 连接卡片）
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('提供商预设（一键填充）'), findsOneWidget);

    // 编辑页
    await tester.pumpWidget(
      _harness(state, MobileAiProviderDetailPage(profileId: p.id)),
    );
    await tester.pumpAndSettle();
    // 详情页顶栏显示提供商名称（沿用设计稿「Name 居中」的结构）。
    // 注意输入框的 EditableText 也会命中 find.text，这里限定在顶栏内。
    expect(
      find.descendant(
        of: find.byType(MobileSubPageTopBar),
        matching: find.text('测试提供商'),
      ),
      findsOneWidget,
    );
    // 名称输入框回显草稿值——与字段顺序无关：详情页有多个 TextField，
    // 「第一个」会随 UI 演化漂移（曾因此误取到别处的默认值 'OpenAI 兼容'）。
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      fields.any((f) => f.controller?.text == '测试提供商'),
      isTrue,
      reason: '应存在一个名称输入框回显草稿值「测试提供商」',
    );
    expect(find.text('设为当前'), findsNothing); // 已是当前，按钮隐藏
    // 让配置落盘防抖定时器跑完，避免 Timer pending 断言
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('高级设置页可构建', (tester) async {
    // 同上：长 ListView 需要竖屏手机视口才能构建到「自定义系统提示词」卡。
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    state.updateConfig(
      (c) => c
        ..cardStyle = 'theme'
        ..pillStyle = 'gray'
        ..aiAutoTitle = true
        ..aiApproveMode = 'ask',
    );
    await tester.pumpWidget(
      _harness(
        state,
        Navigator(
          initialRoute: '/',
          // 与生产一致：路由层关闭 framework 快照（见 lib/app.dart 的 smoothRoute）
          onGenerateRoute: (r) => MaterialPageRoute<void>(
            allowSnapshotting: false,
            builder: (_) => const MobileAiAdvancedPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('图生成模式'), findsOneWidget);
    // 「会话模式」出现 2 次：卡片标题 + 下拉行标签共用 aiApproveModeLabel
    expect(find.text('会话模式'), findsNWidgets(2));
    expect(find.text('自定义系统提示词'), findsOneWidget);
    // 让配置落盘防抖定时器跑完，避免 Timer pending 断言
    await tester.pump(const Duration(milliseconds: 600));
  });

  test('卡片样式旧值迁移', () {
    expect(AppConfig.fromJson({'card_style': 'glass'}).cardStyle, 'liquid');
    expect(AppConfig.fromJson({'card_style': 'flat'}).cardStyle, 'gray');
    expect(AppConfig.fromJson({'card_style': 'blur'}).cardStyle, 'blur');
    expect(AppConfig.fromJson({'card_style': 'theme'}).cardStyle, 'theme');
    expect(AppConfig.fromJson({}).cardStyle, 'liquid');
    expect(AppConfig.fromJson({'nav_style': 'weird'}).navStyle, 'liquid');
    expect(AppConfig.fromJson({'pill_style': 'flat'}).pillStyle, 'gray');
  });

  test('新样式字段 JSON 往返', () {
    final cfg = AppConfig()
      ..cardStyle = 'theme'
      ..navStyle = 'blur'
      ..pillStyle = 'gray';
    final restored = AppConfig.fromJson(cfg.toJson());
    expect(restored.cardStyle, 'theme');
    expect(restored.navStyle, 'blur');
    expect(restored.pillStyle, 'gray');
  });
}
