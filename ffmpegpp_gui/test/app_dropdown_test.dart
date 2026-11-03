import 'dart:io';

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/app_dropdown.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/editor_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 下拉菜单样式统一回归测试。
///
/// 目标：所有下拉都收敛到 AppDropdown（OptionMenuBar 浮层：圆角 14 +
/// 缩放展开），不再出现系统 DropdownButtonFormField 的直角瞬时菜单。
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

    // 浮层打开：条目出现，且面板使用统一圆角 14（不是系统菜单的直角）
    expect(find.text('MKV'), findsOneWidget);
    expect(find.text('WebM'), findsOneWidget);
    final panel = tester.widgetList<Material>(find.byType(Material)).where(
          (m) => m.borderRadius == BorderRadius.circular(14),
        );
    expect(panel, isNotEmpty, reason: '浮层面板应使用圆角 14 的统一外壳');

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
    final state = AppState();
    await state.updateConfig((config) => config..dropdownAppearance = 'frosted');
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
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
    expect(find.byType(BackdropFilter), findsOneWidget);
    final theme = ThemeData(useMaterial3: true);
    final panel = tester.widgetList<Material>(find.byType(Material)).firstWhere(
          (material) => material.borderRadius == BorderRadius.circular(14),
        );
    expect(
      panel.color,
      Color.alphaBlend(
        theme.colorScheme.primary.withAlpha(34),
        theme.colorScheme.surface.withAlpha(218),
      ),
    );
  });
}
