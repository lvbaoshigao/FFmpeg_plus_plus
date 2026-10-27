import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// OptionMenuBar / ScaleMenuButton 的键盘与浮层定位回归。
///
/// 背景（2026-10-27 审查）：这两个控件是本次替换 PopupMenuButton /
/// DropdownButtonFormField 的新实现，此前没有任何测试覆盖，于是
/// 「搜索框里打空格 = 静默选中第一条搜索结果」「浮层宽度大于触发钮时
/// 跑出屏幕右侧」「贴底的 ⋮ 菜单弹到屏幕外」这类问题只能靠用户反馈发现。
Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

List<OptionItem<String>> _items() => const [
  OptionItem('alpha', 'Alpha'),
  OptionItem('beta', 'Beta'),
  OptionItem('gamma', 'Gamma'),
];

void main() {
  testWidgets('搜索框里按空格不会选中条目（面板不能抢走搜索框的按键）', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 200,
          child: OptionMenuBar<String>(
            value: 'gamma',
            searchable: true,
            menuWidth: 260,
            items: _items(),
            onChanged: picked.add,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Gamma'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(picked, isEmpty, reason: '空格属于搜索词，不能触发选中');
    expect(find.byType(TextField), findsOneWidget, reason: '菜单不应被空格收起');
  });

  testWidgets('搜索过滤后回车只选中过滤结果里的那一项', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 200,
          child: OptionMenuBar<String>(
            value: 'alpha',
            searchable: true,
            menuWidth: 260,
            items: _items(),
            onChanged: picked.add,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'be');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // 只触发一次，且是过滤后的 Beta —— 不是「清空过滤后的首项 Alpha」
    expect(picked, ['beta']);
  });

  testWidgets('浮层比触发钮宽时不会跑出屏幕右侧', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 80, right: 16),
              child: SizedBox(
                width: 156,
                child: OptionMenuBar<String>(
                  value: 'gamma',
                  menuWidth: 260,
                  items: _items(),
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Gamma'));
    await tester.pumpAndSettle();

    final panel = find
        .ancestor(of: find.text('Alpha'), matching: find.byType(Material))
        .first;
    expect(tester.getRect(panel).right, lessThanOrEqualTo(412.0));
  });

  testWidgets('⋮ 菜单支持键盘：↑↓ 移动高亮、Enter 选中、Esc 关闭', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _host(
        ScaleMenuButton<String>(
          icon: Icons.more_vert,
          items: const [
            OptionItem('use', '设为当前模型'),
            OptionItem('delete', '删除模型', danger: true),
          ],
          onSelected: picked.add,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('设为当前模型'), findsOneWidget);

    // 打开时高亮第一项；↓ 移到第二项，Enter 选中。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, ['delete']);

    // Esc 关闭且不选中（替换掉 PopupMenuButton 后不能丢这个能力）。
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('设为当前模型'), findsNothing);
    expect(picked, ['delete']);
  });

  testWidgets('触发钮贴着屏幕底部时菜单向上弹出', (tester) async {
    tester.view.physicalSize = const Size(412, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ScaleMenuButton<String>(
                icon: Icons.more_vert,
                menuWidth: 230,
                items: const [
                  OptionItem('use', '设为当前模型'),
                  OptionItem('delete', '删除模型', danger: true),
                ],
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    final panel = find
        .ancestor(of: find.text('删除模型'), matching: find.byType(Material))
        .first;
    expect(tester.getRect(panel).bottom, lessThanOrEqualTo(700.0));
  });
}
