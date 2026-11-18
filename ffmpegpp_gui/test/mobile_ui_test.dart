// 移动端统一设计语言冒烟测试：
// 主界面基准顶栏（MobilePillTopBar）/ 二级页顶栏（MobileSubPageTopBar）/
// 统一分段控件（MobileSegmentedPills）/ 搜索药丸（MobileSearchPill）
// 在折叠与展开两种状态下都能构建，且尺寸令牌与主界面基准一致。
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:ffmpegpp_gui/widgets/mobile_top_bar.dart';
import 'package:ffmpegpp_gui/widgets/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _harness(AppState state, Widget child, {double width = 412}) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

AppState _state() {
  final state = AppState();
  // 纯色样式：避开测试环境里的 GPU shader 路径
  state.updateConfig((c) => c
    ..cardStyle = 'gray'
    ..pillStyle = 'gray'
    ..navStyle = 'gray');
  return state;
}

/// 消化配置落盘的 400ms 防抖 Timer，避免「Pending timers」断言。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('主界面基准顶栏：标题 + 动作药丸可构建且高度为 44', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = _state();
    await tester.pumpWidget(_harness(
      state,
      MobilePillTopBar(
        title: const Text('项目'),
        actions: [
          MobileGlassPillAction(
            icon: Icons.search,
            tooltip: 'search',
            color: Colors.white,
            onTap: () {},
          ),
          MobileGlassPillAction(
            icon: Icons.add,
            tooltip: 'add',
            color: Colors.white,
            bg: Colors.blue,
            onTap: () {},
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('项目'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);

    // 标题药丸与操作药丸都是基准高度 44
    final pills = tester
        .widgetList<MobileGlassPill>(find.byType(MobileGlassPill))
        .toList();
    expect(pills.length, 2);
    for (final p in pills) {
      expect(p.height, MobileUi.pillHeight);
      expect(p.radius, MobileUi.pillRadius);
    }
    await _flush(tester);
  });

  testWidgets('主界面基准顶栏：搜索展开/收起可构建', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = _state();
    var closed = 0;
    Widget build(bool searching) => _harness(
          state,
          MobilePillTopBar(
            title: const Text('项目'),
            actions: [
              MobileGlassPillAction(
                icon: Icons.search,
                tooltip: 'search',
                color: Colors.white,
                onTap: () {},
              ),
            ],
            searching: searching,
            searchChild: MobileSearchPill(
              hint: '搜索',
              onChanged: (_) {},
              onClose: () => closed++,
            ),
          ),
        );

    await tester.pumpWidget(build(false));
    await tester.pumpAndSettle();
    // 折叠态：搜索输入框未挂载（与主界面一致，避免隐藏时误触发 autofocus）
    expect(find.byType(TextField), findsNothing);

    await tester.pumpWidget(build(true));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);

    // 关闭按钮回调生效
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closed, 1);
    await _flush(tester);
  });

  testWidgets('二级页顶栏：返回钮 + 标题左对齐 + 操作药丸', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = _state();
    var backed = 0;
    await tester.pumpWidget(_harness(
      state,
      MobileSubPageTopBar(
        title: const Text('日志'),
        onBack: () => backed++,
        actions: [
          MobileGlassPillAction(
            icon: Icons.copy,
            tooltip: 'copy',
            color: Colors.white,
            onTap: () {},
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('日志'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);

    // 标题药丸在返回按钮右侧（标题在左，与主界面一致）
    final backX = tester.getCenter(find.byIcon(Icons.arrow_back)).dx;
    final titleX = tester.getCenter(find.text('日志')).dx;
    expect(titleX, greaterThan(backX));

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(backed, 1);
    await _flush(tester);
  });

  testWidgets('统一分段控件：等宽标签 + 选中切换回调', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = _state();
    var selected = 0;
    await tester.pumpWidget(_harness(
      state,
      MobileSegmentedPills(
        tabs: const [
          MobilePillTab('全部'),
          MobilePillTab('信息', icon: Icons.info_outline, badge: '3'),
          MobilePillTab('错误'),
        ],
        selectedIndex: selected,
        onSelected: (i) => selected = i,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('信息'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    await tester.tap(find.text('错误'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    await _flush(tester);
  });

  test('设计语言令牌与主界面基准一致', () {
    expect(MobileUi.pillHeight, 44);
    expect(MobileUi.pillRadius, 22);
    expect(MobileUi.titlePillPadH, 14);
    expect(MobileUi.actionsPillPadH, 6);
    expect(MobileUi.actionButtonSize, 34);
    expect(MobileUi.actionIconSize, 19);
    expect(MobileUi.pagePaddingH, 8);
    expect(MobileUi.subPagePaddingH, 12);
    expect(MobileUi.mainListPadding().left, MobileUi.pagePaddingH);
    expect(MobileUi.subListPadding().left, MobileUi.subPagePaddingH);
  });
}
