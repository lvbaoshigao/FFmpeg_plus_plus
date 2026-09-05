// 冒烟测试：
// 1. AppCard 四种表面样式（桌面分支）可构建
// 2. 移动端 AI 设置内容 / 提供商详情页 / 高级页可构建
// 3. 卡片/底部菜单栏/顶部药丸样式的旧值迁移与 JSON 往返
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_card.dart';
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

void main() {
  testWidgets('AppCard 四种样式可构建', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      _harness(
        state,
        SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            for (final style in SurfaceStyle.all)
              AppCard(
                style: style,
                radius: 16,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                child: const Text('card'),
              ),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('card'), findsNWidgets(SurfaceStyle.all.length));
  });

  testWidgets('移动端 AI 设置内容可构建', (tester) async {
    final state = AppState();
    // 用纯色样式避免测试环境里的 GPU shader
    state.updateConfig((c) => c
      ..cardStyle = 'gray'
      ..pillStyle = 'gray'
      ..navStyle = 'gray'
      ..aiEnabled = true
      ..mcpEnabled = false);
    final p1 = AiProfile(name: 'OpenAI 默认', provider: 'openai', model: 'gpt-4o');
    final p2 = AiProfile(name: 'Claude', provider: 'anthropic', model: 'claude-sonnet-5');
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
          child: Builder(
            builder: (ctx) => mobileAiSettingsContent(ctx, state),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('OpenAI 默认'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    // 当前提供商徽标
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('新建提供商'), findsOneWidget);
    expect(find.text('权限'), findsOneWidget);
    expect(find.text('高级'), findsOneWidget);
    // 让配置落盘防抖定时器跑完，避免 Timer pending 断言
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('提供商详情页（新建 + 编辑）可构建', (tester) async {
    final state = AppState();
    state.updateConfig((c) => c
      ..cardStyle = 'theme'
      ..pillStyle = 'gray');
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
    expect(find.text('配置名'), findsOneWidget);
    expect(find.text('提供商预设（一键填充）'), findsOneWidget);

    // 编辑页
    await tester.pumpWidget(
      _harness(state, MobileAiProviderDetailPage(profileId: p.id)),
    );
    await tester.pumpAndSettle();
    expect(find.text('提供商详情'), findsOneWidget);
    // 名称输入框回显草稿值
    final nameField = tester.widget<TextField>(find.byType(TextField).first);
    expect(nameField.controller?.text, '测试提供商');
    expect(find.text('设为当前'), findsNothing); // 已是当前，按钮隐藏
    // 让配置落盘防抖定时器跑完，避免 Timer pending 断言
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('高级设置页可构建', (tester) async {
    final state = AppState();
    state.updateConfig((c) => c
      ..cardStyle = 'theme'
      ..pillStyle = 'gray'
      ..aiAutoTitle = true
      ..aiApproveMode = 'ask');
    await tester.pumpWidget(
      _harness(
        state,
        Navigator(
          initialRoute: '/',
          onGenerateRoute: (r) => MaterialPageRoute<void>(
            builder: (_) => const MobileAiAdvancedPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('图生成模式'), findsOneWidget);
    expect(find.text('会话模式'), findsOneWidget);
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
