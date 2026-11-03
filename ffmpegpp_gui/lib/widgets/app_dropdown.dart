import 'package:flutter/material.dart';

import 'option_menu_bar.dart';

/// 全应用统一下拉选择框。
///
/// 背景：项目里同时存在 DropdownButtonFormField（系统直角菜单 + 瞬时弹出）
/// 与 OptionMenuBar（圆角 14 浮层 + 200ms 缩放展开）两套下拉。样式统一的
/// 正确做法不是逐个改调用点，而是让所有下拉都收敛到这一个组件：
///
/// * 触发钮：与工具栏/设置页一致的胶囊按钮（label 在左、当前值在右、箭头旋转）；
/// * 浮层：复用 OptionMenuBar 的 Overlay 面板（圆角 / 阴影 / 缩放动画 / 键盘导航）；
/// * 语义色：支持 AppDropdownItem.textColor / fontWeight（如硬编编码器高亮）；
/// * 条目多时自动开启搜索（> 8 项），短选项列表不加搜索框。
///
/// 这样新增页面只要用 AppDropdown（或它的薄封装 EditorDropdown），
/// 不必再重复配置 menuStyle / borderRadius / dropdownColor。
class AppDropdownItem<T> {
  final T value;
  final String label;
  final Color? textColor;
  final FontWeight? fontWeight;
  final IconData? icon;
  final String? subtitle;
  final bool danger;

  const AppDropdownItem(
    this.value,
    this.label, {
    this.textColor,
    this.fontWeight,
    this.icon,
    this.subtitle,
    this.danger = false,
  });
}

/// A labeled group of options in an [AppDropdown].
class AppDropdownGroup<T> {
  final String label;
  final List<AppDropdownItem<T>> items;

  const AppDropdownGroup(this.label, this.items);
}

class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    this.label,
    required this.value,
    this.items = const [],
    this.groups = const [],
    this.onChanged,
    this.height = 36,
    this.labelColor,
    this.menuWidth,
    this.searchable,
    this.searchHint,
    this.emptyLabel,
    this.leadingIcon,
  });

  /// 可选的行内标签（显示在触发钮上方）。
  final String? label;
  final T value;
  final List<AppDropdownItem<T>> items;
  final List<AppDropdownGroup<T>> groups;
  final ValueChanged<T>? onChanged;

  /// 触发钮高度（默认 36；紧凑工具栏可传 30~34，表单可传 40~44）。
  final double height;
  final Color? labelColor;

  /// 浮层固定宽度（null = 跟随触发钮宽度）。
  final double? menuWidth;

  /// 是否显示搜索框；null = 条目数 > 8 时自动开启。
  final bool? searchable;
  final String? searchHint;
  final String? emptyLabel;
  final IconData? leadingIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menuItems = <OptionItem<T>>[
      for (final item in items)
        OptionItem<T>(
          item.value,
          item.label,
          icon: item.icon,
          subtitle: item.subtitle,
          danger: item.danger,
          textColor: item.textColor,
          fontWeight: item.fontWeight,
        ),
      for (final group in groups)
        for (final item in group.items)
          OptionItem<T>(
            item.value,
            item.label,
            icon: item.icon,
            subtitle: item.subtitle,
            danger: item.danger,
            textColor: item.textColor,
            fontWeight: item.fontWeight,
            groupLabel: group.label,
          ),
    ];
    if (menuItems.isEmpty) return const SizedBox.shrink();

    // 防御：调用点可能在异步刷新后传入了已不存在的旧值。回退到首项，
    // 避免 OptionMenuBar 的“当前值”变成空白而看起来像坏掉。
    final safeValue = menuItems.any((e) => e.value == value)
        ? value
        : menuItems.first.value;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null && label!.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: labelColor ?? scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 6),
        ],
        OptionMenuBar<T>(
          value: safeValue,
          items: menuItems,
          onChanged: (v) => onChanged?.call(v),
          triggerHeight: height,
          searchable: searchable ?? menuItems.length > 8,
          searchHint: searchHint,
          emptyLabel: emptyLabel,
          menuWidth: menuWidth,
          leadingIcon: leadingIcon,
        ),
      ],
    );
  }
}
