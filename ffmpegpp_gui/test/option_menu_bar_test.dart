import 'package:ffmpegpp_gui/theme/mobile_visual_theme.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  group('OptionMenuBar long lists', () {
    testWidgets(
      'should keep the active search field when keyboard reduces height',
      (tester) async {
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _host(
            SizedBox(
              width: 230,
              child: OptionMenuBar<int>(
                value: 179,
                searchable: true,
                items: List.generate(180, (i) => OptionItem(i, 'Model $i')),
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.tap(find.text('Model 179'));
        await tester.pumpAndSettle();
        final field = tester.state(find.byType(TextField));
        tester.view.viewInsets = const FakeViewPadding(bottom: 270);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(TextField)), same(field));
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
        );
        await tester.enterText(find.byType(TextField), 'Model 17');
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'should preserve scroll when parent recreates equivalent options',
      (tester) async {
        late StateSetter refresh;
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (context, setState) {
                refresh = setState;
                return SizedBox(
                  width: 240,
                  child: OptionMenuBar<int>(
                    value: 0,
                    items: List.generate(180, (i) => OptionItem(i, 'Model $i')),
                    onChanged: (_) {},
                  ),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text('Model 0'));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView), const Offset(0, -620));
        await tester.pumpAndSettle();
        final state = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        );
        final offset = state.position.pixels;
        expect(offset, greaterThan(400));
        refresh(() {});
        await tester.pumpAndSettle();
        expect(state.position.pixels, closeTo(offset, 0.5));
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('should build visible options lazily', (tester) async {
      final items = List.generate(300, (i) => OptionItem(i, 'Model $i'));
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 240,
            child: OptionMenuBar<int>(
              value: 0,
              items: items,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Model 0'));
      await tester.pumpAndSettle();
      final mountedRows = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(InkWell),
      );
      expect(mountedRows.evaluate().length, lessThan(30));
      expect(find.text('Model 299'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('should reveal a selected option outside the lazy viewport', (
      tester,
    ) async {
      final items = List.generate(
        180,
        (i) => OptionItem(
          i,
          i < 30
              ? 'Model $i'
              : 'Model $i extended context and reasoning capabilities '
                    'with a full multi-line provider identifier',
          groupLabel: i % 12 == 0 ? 'Provider $i' : null,
        ),
      );
      final selectedName = items.last.label;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 240,
            child: OptionMenuBar<int>(
              value: 179,
              items: items,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text(selectedName));
      await tester.pumpAndSettle();
      final selected = find.descendant(
        of: find.byType(ListView),
        matching: find.text(selectedName),
      );
      expect(selected.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('should wrap the full model ID with large system text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const id = 'organization/reasoning-model-preview-2026-extended-context';
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(
                  textScaler: const TextScaler.linear(1.7),
                  boldText: true,
                )
                .applyTextStyleOverrides(
                  lineHeightScaleFactorOverride: 1.6,
                  letterSpacingOverride: 1.0,
                  wordSpacingOverride: null,
                  paragraphSpacingOverride: null,
                ),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                child: OptionMenuBar<String>(
                  value: id,
                  menuWidth: 320,
                  itemLabelMaxLines: null,
                  items: const [OptionItem(id, id, groupLabel: 'Organization')],
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text(id));
      await tester.pumpAndSettle();
      final name = find.descendant(
        of: find.byType(ListView),
        matching: find.text(id),
      );
      final paragraph = tester.renderObject<RenderParagraph>(name);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.getSize(name).height, greaterThan(35));
      expect(tester.takeException(), isNull);
    });

    testWidgets('should scroll keyboard action highlights to lazy rows', (
      tester,
    ) async {
      int? selected;
      await tester.pumpWidget(
        _host(
          ScaleMenuButton<int>(
            icon: Icons.more_vert,
            items: List.generate(120, (i) => OptionItem(i, 'Action $i')),
            onSelected: (value) => selected = value,
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(find.text('Action 119').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 119);
      expect(tester.takeException(), isNull);
    });
  });
  testWidgets('动作菜单安全区与键盘变化不越界且极小高度可滚动', (tester) async {
    tester.view.physicalSize = const Size(400, 360);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 20, bottom: 24);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Center(
            child: ScaleMenuButton<String>(
              icon: Icons.more_vert,
              items: List.generate(
                30,
                (i) => OptionItem('item$i', 'Action $i'),
              ),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    Rect panelRect() => tester.getRect(find.byType(ClipRRect).last);
    expect(tester.takeException(), isNull);
    expect(panelRect().top, greaterThanOrEqualTo(20));
    expect(panelRect().bottom, lessThanOrEqualTo(336));
    tester.view.viewInsets = const FakeViewPadding(bottom: 210);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(panelRect().top, greaterThanOrEqualTo(20));
    expect(panelRect().bottom, lessThanOrEqualTo(150));
    tester.view.viewInsets = const FakeViewPadding(bottom: 310);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(panelRect().bottom, lessThanOrEqualTo(50));
  });

  testWidgets('搜索浮层按安全区和键盘变化重算可用高度', (tester) async {
    tester.view.physicalSize = const Size(400, 360);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 20, bottom: 24);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: 180,
              child: OptionMenuBar<String>(
                value: 'item0',
                searchable: true,
                items: List.generate(
                  30,
                  (i) => OptionItem('item$i', 'Item $i'),
                ),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Item 0'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    Rect panelRect() => tester.getRect(
      find
          .ancestor(
            of: find.byType(TextField),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    var rect = panelRect();
    expect(rect.top, greaterThanOrEqualTo(20));
    expect(rect.bottom, lessThanOrEqualTo(336));
    tester.view.viewInsets = const FakeViewPadding(bottom: 210);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    rect = panelRect();
    expect(rect.top, greaterThanOrEqualTo(20));
    expect(rect.bottom, lessThanOrEqualTo(150));
    await tester.enterText(find.byType(TextField), 'no match');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('极小可用空间下搜索header与空状态可滚动而不overflow', (tester) async {
    tester.view.physicalSize = const Size(400, 120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 180,
          child: OptionMenuBar<String>(
            value: 'alpha',
            searchable: true,
            items: _items(),
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'no match');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final rect = tester.getRect(
      find
          .ancestor(
            of: find.byType(TextField),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(120));
  });
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

    // 打开时不高亮任何项（不「框住」第一项）；首次 ↓ 显示高亮并落在
    // 第一项，再次 ↓ 移到第二项，Enter 选中。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
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

  group('OptionMenuBar row radius', () {
    Future<void> openMenu(WidgetTester tester, {bool miuix = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: miuix
              ? ThemeData(extensions: const [MobileVisualTheme(enabled: true)])
              : null,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                child: OptionMenuBar<String>(
                  value: 'alpha',
                  items: _items(),
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      // 触发钮文字 Alpha 在 Overlay 之前的树中，first 即为触发按钮。
      await tester.tap(find.text('Alpha').first);
      await tester.pumpAndSettle();
    }

    // 「Beta」只出现在展开的浮层列表里，其最近的 InkWell 即行的水波/高亮宿主。
    Finder rowInk() => find
        .ancestor(of: find.text('Beta'), matching: find.byType(InkWell))
        .first;

    testWidgets('row ink and highlight share the default menu radius', (
      tester,
    ) async {
      await openMenu(tester);
      final ink = tester.widget<InkWell>(rowInk());
      final box = tester.widget<Container>(
        find.descendant(of: rowInk(), matching: find.byType(Container)).first,
      );
      expect(ink.borderRadius, BorderRadius.circular(12));
      expect(
        (box.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(12),
      );
    });

    testWidgets('row ink and highlight follow the miuix menu radius', (
      tester,
    ) async {
      await openMenu(tester, miuix: true);
      final ink = tester.widget<InkWell>(rowInk());
      final box = tester.widget<Container>(
        find.descendant(of: rowInk(), matching: find.byType(Container)).first,
      );
      expect(ink.borderRadius, BorderRadius.circular(20));
      expect(
        (box.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(20),
      );
    });
  });
}
