import 'dart:io';

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/app_dropdown.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/editor_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 下拉控件共享同一套圆角浮层、缩放动画和选项交互。
Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: Center(child: SizedBox(width: 260, child: child)),
      ),
    );

void main() {
  testWidgets('AppDropdown 显示标签/当前值，并在统一浮层中选择', (tester) async {
    String? picked;
    await tester.pumpWidget(_wrap(AppDropdown<String>(
      label: '格式',
      value: 'mp4',
      items: const [
        AppDropdownItem('mp4', 'MP4'),
        AppDropdownItem('mkv', 'MKV'),
        AppDropdownItem('webm', 'WebM'),
      ],
      onChanged: (v) => picked = v,
    )));

    expect(find.text('格式'), findsOneWidget);
    expect(find.text('MP4'), findsOneWidget);
    expect(find.text('MKV'), findsNothing);

    await tester.tap(find.text('MP4'));
    await tester.pumpAndSettle();

    final mkv = find.text('MKV');
    expect(mkv, findsOneWidget);
    expect(find.text('WebM'), findsOneWidget);
    final menuClip = find.ancestor(of: mkv, matching: find.byType(ClipRRect));
    expect(menuClip, findsOneWidget);
    expect(
      tester.widget<ClipRRect>(menuClip).borderRadius,
      const BorderRadius.all(Radius.circular(12)),
    );

    await tester.tap(find.text('MKV'));
    await tester.pumpAndSettle();
    expect(picked, 'mkv');
    expect(find.text('MKV'), findsNothing, reason: '选择后浮层收起');
  });

  testWidgets('EditorDropdown 复用同一套下拉外观', (tester) async {
    String? picked;
    await tester.pumpWidget(_wrap(EditorDropdown(
      label: '输出格式',
      value: 'png',
      items: const [('png', 'PNG'), ('jpg', 'JPEG')],
      onChanged: (v) => picked = v,
    )));

    expect(find.text('输出格式'), findsOneWidget);
    expect(find.text('PNG'), findsOneWidget);

    await tester.tap(find.text('PNG'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JPEG'));
    await tester.pumpAndSettle();
    expect(picked, 'jpg');
  });

  /// 打开一个包含 count 个条目的下拉。
  Future<void> openWith(WidgetTester tester, int count) async {
    await tester.pumpWidget(_wrap(AppDropdown<int>(
      value: 0,
      items: [for (var i = 0; i < count; i++) AppDropdownItem(i, '选项$i')],
      onChanged: (_) {},
    )));
    await tester.tap(find.text('选项0'));
    await tester.pumpAndSettle();
  }

  testWidgets('条目多时自动带搜索框', (tester) async {
    await openWith(tester, 10);
    expect(find.byType(TextField), findsOneWidget,
        reason: '10 项应自动开启搜索');
  });

  testWidgets('条目少时不带搜索框', (tester) async {
    await openWith(tester, 3);
    expect(find.byType(TextField), findsNothing,
        reason: '3 项不应出现搜索框');
  });

  test('lib 内不再直接使用系统下拉/右键菜单 API（防止样式回退）', () {
    // 统一入口：AppDropdown / EditorDropdown（下拉）、showAnimatedMenu（右键菜单）。
    // 该断言会拦住后续 PR 再次手写 DropdownButtonFormField 之类。
    final pattern = RegExp(
      r'\b(DropdownButtonFormField|DropdownButton|DropdownMenu|PopupMenuButton|showMenu)\s*[(<]',
    );
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (pattern.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '请改用 AppDropdown / EditorDropdown / showAnimatedMenu，违规位置: ${offenders.join(' | ')}',
    );
  });

  testWidgets('未选中的旧值会安全回退到首项，不出现空触发钮', (tester) async {
    await tester.pumpWidget(_wrap(AppDropdown<String>(
      value: 'deleted-value',
      items: const [
        AppDropdownItem('a', '甲'),
        AppDropdownItem('b', '乙'),
      ],
      onChanged: (_) {},
    )));
    expect(find.text('甲'), findsOneWidget);
  });

  testWidgets('grouped options render headers below search and remain selectable', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(_wrap(AppDropdown<String>(
      value: 'a1',
      searchable: true,
      groups: const [
        AppDropdownGroup('Supplier A', [
          AppDropdownItem('a1', 'Alpha'),
          AppDropdownItem('a2', 'Atlas'),
        ]),
        AppDropdownGroup('Supplier B', [
          AppDropdownItem('b1', 'Beta'),
        ]),
      ],
      onChanged: (value) => picked = value,
    )));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Supplier A'), findsOneWidget);
    expect(find.text('Supplier B'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(TextField)).dy,
      lessThan(tester.getTopLeft(find.text('Supplier A')).dy),
    );

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(picked, 'b1');
  });

  testWidgets('global dropdown appearance config controls glass treatment', (
    tester,
  ) async {
    final theme = ThemeData(useMaterial3: true);
    final cs = theme.colorScheme;

    final option = find.text('Two');
    final panelBackdrop = find.ancestor(
      of: option,
      matching: find.byType(BackdropFilter),
    );

    Future<Color> openPanel(String appearance) async {
      // Unmount the previous trigger to dismiss its OverlayPortal.
      await tester.pumpWidget(const SizedBox.shrink());
      final state = AppState()..config.dropdownAppearance = appearance;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 260,
                  child: AppDropdown<String>(
                    value: 'one',
                    items: const [
                      AppDropdownItem('one', 'One'),
                      AppDropdownItem('two', 'Two'),
                    ],
                    onChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      expect(option, findsOneWidget);
      final tint = find.ancestor(of: option, matching: find.byType(Material));
      return tester.widget<Material>(tint.first).color!;
    }

    expect(await openPanel('theme'), cs.surface);
    expect(panelBackdrop, findsNothing);

    final liquid = await openPanel('liquid');
    expect(panelBackdrop, findsOneWidget);
    expect(liquid.a, inExclusiveRange(0, 1));
    final liquidSaturation = HSLColor.fromColor(liquid).saturation;
    expect(liquidSaturation, closeTo(0, 0.01));

    final frosted = await openPanel('frosted');
    expect(panelBackdrop, findsOneWidget);
    expect(frosted.a, inExclusiveRange(liquid.a, 1));
    expect(HSLColor.fromColor(frosted).saturation, greaterThan(liquidSaturation));
  });
}
