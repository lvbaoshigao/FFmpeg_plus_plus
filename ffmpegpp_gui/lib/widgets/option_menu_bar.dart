import 'package:flutter/material.dart';

/// 统一的「菜单栏选项」控件 —— 融合两处参考样式：
/// * 触发按钮：设置→任务卡片下拉菜单的外观（圆角描边、紧凑高度、展开/收起动画）；
/// * 选项条目：设置页左侧主菜单条目（图标+文字，选中为主题色药丸，
///   AnimatedContainer 变色过渡 + AnimatedSwitcher 图标淡入淡出）。
///
/// 两种形态（同一组件，按 [expandable] 切换）：
/// * `expandable: false` —— 行内分段药丸（替代 SegmentedButton），适合 2~4 个短选项；
/// * `expandable: true`  —— 一个按钮，点开 AnimatedSize 展开选项列表
///   （替代 DropdownMenu / RadioListTile 单选组），选中即回调并收起。
///
/// 供设置页所有枚举型选项控件统一使用；数值型数量选择（并发数/线程数）
/// 仍用任务卡片的下拉菜单，不在此列。
class OptionItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  const OptionItem(this.value, this.label, {this.subtitle, this.icon});
}

class OptionMenuBar<T> extends StatefulWidget {
  final List<OptionItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;

  /// expandable（按钮+展开列表）模式：触发按钮左侧的说明文字（可空）
  final String? label;
  final IconData? leadingIcon;

  /// false = 行内分段药丸；true = 按钮 + 展开选项列表
  final bool expandable;
  final double triggerHeight;

  const OptionMenuBar({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.label,
    this.leadingIcon,
    this.expandable = true,
    this.triggerHeight = 38,
  });

  @override
  State<OptionMenuBar<T>> createState() => _OptionMenuBarState<T>();
}

class _OptionMenuBarState<T> extends State<OptionMenuBar<T>> {
  bool _expanded = false;

  bool _selected(OptionItem<T> it) => it.value == widget.value;

  void _pick(OptionItem<T> it) {
    if (_selected(it)) {
      if (widget.expandable) setState(() => _expanded = false);
      return;
    }
    widget.onChanged(it.value);
    if (widget.expandable) setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = widget.items.where(_selected).firstOrNull;
    final trigger = BoxDecoration(
      color: scheme.surface.withAlpha(60),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: scheme.outlineVariant.withAlpha(90)),
    );

    if (!widget.expandable) {
      // ── 行内分段药丸：同一套选中动画，2~4 个短选项 ──
      return Container(
        decoration: trigger.copyWith(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.all(3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < widget.items.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(child: _pill(context, widget.items[i], compact: true)),
          ],
        ]),
      );
    }

    // ── 按钮 + 展开选项列表 ──
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            height: widget.triggerHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: trigger,
            child: Row(children: [
              if (widget.leadingIcon != null) ...[
                Icon(widget.leadingIcon, size: 15, color: scheme.primary),
                const SizedBox(width: 8),
              ],
              if (widget.label != null) ...[
                Flexible(child: Text(widget.label!,
                    style: TextStyle(fontSize: 12, color: scheme.onSurface))),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              Flexible(
                child: Text(current?.label ?? '',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                        color: scheme.onSurface)),
              ),
              const SizedBox(width: 6),
              // 展开时箭头旋转 180°，与设置页二级菜单同一动画语言
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(Icons.expand_more, size: 17, color: scheme.outline),
              ),
            ]),
          ),
        ),
      ),
      // 展开/收起动画：AnimatedSize 高度过渡（与背景设置二级菜单一致）
      AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: _expanded
            ? Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Material(
                  color: scheme.surface.withAlpha(40),
                  borderRadius: BorderRadius.circular(12),
                  child: Column(children: [
                    for (final it in widget.items) _menuRow(context, it),
                  ]),
                ),
              )
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }

  /// 行内药丸（bar 模式条目）
  Widget _pill(BuildContext context, OptionItem<T> it, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected(it);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _pick(it),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: compact ? 5 : 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: sel ? scheme.primary.withAlpha(34) : Colors.transparent,
          border: Border.all(
              color: sel ? scheme.primary.withAlpha(90) : Colors.transparent),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center,
            children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: it.icon == null
                ? const SizedBox.shrink()
                : Icon(it.icon,
                    key: ValueKey('${it.value}_$sel'),
                    size: 14,
                    color: sel ? scheme.primary : scheme.onSurfaceVariant),
          ),
          if (it.icon != null) const SizedBox(width: 4),
          Flexible(
            child: Text(it.label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? scheme.primary : scheme.onSurfaceVariant,
                )),
          ),
        ]),
      ),
    );
  }

  /// 展开列表行（menu 模式条目）—— 设置页左侧主菜单条目的同款动画
  Widget _menuRow(BuildContext context, OptionItem<T> it) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected(it);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _pick(it),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: sel ? scheme.primary.withAlpha(34) : Colors.transparent,
          border: Border.all(
              color: sel ? scheme.primary.withAlpha(90) : Colors.transparent),
        ),
        child: Row(children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: Icon(
              it.icon ?? Icons.circle_outlined,
              key: ValueKey('${it.value}_$sel'),
              size: 15,
              color: sel ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text(it.label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? scheme.primary : scheme.onSurfaceVariant,
                )),
            if (it.subtitle != null) ...[
              const SizedBox(height: 2),
              Text(it.subtitle!,
                  style: TextStyle(fontSize: 10, color: scheme.outline)),
            ],
          ])),
          // 选中标记：淡入淡出（与图标同一动画语言）
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: sel
                ? Icon(Icons.check_rounded,
                    key: const ValueKey('check'),
                    size: 16, color: scheme.primary)
                : const SizedBox.shrink(key: ValueKey('none')),
          ),
        ]),
      ),
    );
  }
}
