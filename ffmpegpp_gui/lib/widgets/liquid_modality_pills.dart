import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

/// 模型模态（输入 / 输出）。
abstract final class LiquidModalities {
  static const String text = 'text';
  static const String image = 'image';
  static const String voice = 'voice';

  static const List<String> all = [text, image, voice];
}

/// 可多选、可拖动排序的模态药丸行。
///
/// 设计稿 3 的交互全部落在这里：
/// * **选中段拉伸**：选中药丸的宽度权重大于未选中药丸；切换时用
///   [Curves.easeOutBack]（选中，先冲过头再回落）/ [Curves.easeInOutCubic]
///   （未选中）分别插值宽度，所以整行像液体一样重新分配宽度，而不是瞬切。
/// * **拖动排序**：长按药丸拖到另一颗上即可换位；松手后顺序写回模型条目
///   （选中模态的 JSON 数组顺序也随之更新）。
/// * **液态玻璃质感**：选中药丸用主题色渐变 + 顶部高光 + 细描边，
///   未选中药丸用 surfaceContainerHighest；颜色全部来自 ColorScheme。
/// * **无障碍**：每颗药丸都是 [Semantics] 按钮（toggled 表达多选状态），
///   并额外提供「左移 / 右移」自定义语义动作，读屏用户不依赖拖拽也能排序。
///
/// 性能：宽度动画只重建这一行（[AnimatedBuilder] + [LayoutBuilder]），
/// 页面其余部分不参与重建；行内只有三颗药丸，动画开销与药丸数量线性相关。
class LiquidModalityPills extends StatefulWidget {
  /// 展示顺序（应包含 [LiquidModalities.all] 全部三项）。
  final List<String> order;

  /// 当前选中的模态集合。
  final Set<String> selected;

  final ValueChanged<String> onToggle;

  /// 拖动排序：oldIndex → newIndex（索引基于 [order]）。
  final void Function(int oldIndex, int newIndex) onReorder;

  final String Function(String modality) labelOf;
  final IconData Function(String modality) iconOf;

  /// 用于生成稳定的测试 key：'${keyPrefix}_image' 等。
  final String? keyPrefix;

  final double height;
  final double gap;
  final bool isZh;
  final bool enabled;

  const LiquidModalityPills({
    super.key,
    this.order = LiquidModalities.all,
    required this.selected,
    required this.onToggle,
    required this.onReorder,
    required this.labelOf,
    required this.iconOf,
    this.keyPrefix,
    this.height = 44,
    this.gap = 8,
    this.isZh = true,
    this.enabled = true,
  });

  @override
  State<LiquidModalityPills> createState() => _LiquidModalityPillsState();
}

class _LiquidModalityPillsState extends State<LiquidModalityPills>
    with SingleTickerProviderStateMixin {
  /// 选中段 / 未选中段的宽度权重。差值越大，「拉伸」越明显。
  static const double _selectedWeight = 1.34;
  static const double _unselectedWeight = 0.82;

  late final AnimationController _controller;
  late Map<String, double> _fromWeights;
  late Map<String, double> _toWeights;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      value: 1,
    );
    _toWeights = _weightsFor(widget.selected);
    _fromWeights = Map<String, double>.of(_toWeights);
  }

  Map<String, double> _weightsFor(Set<String> selected) {
    final values = <String>{...LiquidModalities.all, ...widget.order};
    return {
      for (final value in values)
        value: selected.contains(value) ? _selectedWeight : _unselectedWeight,
    };
  }

  double _weightAt(String value, double progress) {
    final double from =
        _fromWeights[value] ?? _weightsFor(widget.selected)[value] ?? 1;
    final double to = _toWeights[value] ?? from;
    final Curve curve = to >= from
        ? Curves.easeOutBack
        : Curves.easeInOutCubic;
    final double t = curve.transform(progress.clamp(0.0, 1.0));
    return (from + (to - from) * t).clamp(0.55, 1.80);
  }

  @override
  void didUpdateWidget(LiquidModalityPills old) {
    super.didUpdateWidget(old);
    if (!setEquals(old.selected, widget.selected)) {
      // 若上一次动画还没结束，从当前实际权重继续，避免宽度跳变。
      final double progress = _controller.value;
      final Map<String, double> current = {
        for (final value in widget.order) value: _weightAt(value, progress),
      };
      _fromWeights = <String, double>{
        ..._weightsFor(widget.selected),
        ...current,
      };
      _toWeights = _weightsFor(widget.selected);
      if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
        _fromWeights = Map<String, double>.of(_toWeights);
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    } else if (!listEquals(old.order, widget.order)) {
      // 排序变化不改变权重，但补齐新出现项，防止空值。
      _toWeights = <String, double>{
        ..._weightsFor(widget.selected),
        ..._toWeights,
      };
      _fromWeights = <String, double>{
        ..._weightsFor(widget.selected),
        ..._fromWeights,
      };
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _acceptDrop(String data, int targetIndex) {
    final int from = widget.order.indexOf(data);
    if (from < 0 || from == targetIndex) return;
    widget.onReorder(from, targetIndex);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final int count = widget.order.length;
        final double available = math.max(
          0,
          maxWidth - widget.gap * math.max(0, count - 1),
        );
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final double progress = _controller.value;
            final Map<String, double> weights = {
              for (final value in widget.order)
                value: _weightAt(value, progress),
            };
            final double total = weights.values.fold(0.0, (a, b) => a + b);
            return Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                for (var i = 0; i < count; i++) ...[
                  if (i > 0) SizedBox(width: widget.gap),
                  SizedBox(
                    height: widget.height,
                    width: total <= 0
                        ? available / math.max(1, count)
                        : available * (weights[widget.order[i]] ?? 1) / total,
                    child: _buildPill(
                      context,
                      widget.order[i],
                      i,
                      scheme,
                      isDark,
                      total <= 0
                          ? available / math.max(1, count)
                          : available *
                                (weights[widget.order[i]] ?? 1) /
                                total,
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPill(
    BuildContext context,
    String value,
    int index,
    ColorScheme scheme,
    bool isDark,
    double width,
  ) {
    final bool selected = widget.selected.contains(value);
    final String label = widget.labelOf(value);
    final IconData icon = widget.iconOf(value);
    final double radius = widget.height / 2;
    final Map<CustomSemanticsAction, VoidCallback> customActions = {
      if (widget.enabled && index > 0)
        CustomSemanticsAction(label: widget.isZh ? '左移' : 'Move left'): () =>
            widget.onReorder(index, index - 1),
      if (widget.enabled && index < widget.order.length - 1)
        CustomSemanticsAction(label: widget.isZh ? '右移' : 'Move right'): () =>
            widget.onReorder(index, index + 1),
    };
    return Semantics(
      key: ValueKey('${widget.keyPrefix ?? 'modality'}_$value'),
      button: true,
      enabled: widget.enabled,
      toggled: selected,
      label: label,
      hint: widget.isZh
          ? '双击切换；长按拖动可排序'
          : 'Double tap to toggle; long press to reorder',
      customSemanticsActions: customActions.isEmpty ? null : customActions,
      onTap: widget.enabled ? () => widget.onToggle(value) : null,
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) =>
            widget.enabled && details.data != value,
        onAcceptWithDetails: (details) => _acceptDrop(details.data, index),
        builder: (context, candidateData, rejectedData) {
          final bool hovering = candidateData.isNotEmpty;
          final Widget surface = _ModalityPillSurface(
            selected: selected,
            hovering: hovering,
            icon: icon,
            label: label,
            scheme: scheme,
            isDark: isDark,
            radius: radius,
          );
          return LongPressDraggable<String>(
            data: value,
            maxSimultaneousDrags: widget.enabled ? 1 : 0,
            hapticFeedbackOnStart: true,
            feedback: Material(
              color: Colors.transparent,
              child: SizedBox(
                height: widget.height,
                width: math.max(72, width),
                child: _ModalityPillSurface(
                  selected: true,
                  hovering: true,
                  icon: icon,
                  label: label,
                  scheme: scheme,
                  isDark: isDark,
                  radius: radius,
                ),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: surface),
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              excludeFromSemantics: true,
              onTap: widget.enabled ? () => widget.onToggle(value) : null,
              child: surface,
            ),
          );
        },
      ),
    );
  }
}

/// 单颗模态药丸的视觉表面。
///
/// 选中：主题色渐变（含顶部高光）+ 主题色描边 + 柔和投影；
/// 未选中：surfaceContainerHighest 实底 + outlineVariant 细边。
class _ModalityPillSurface extends StatelessWidget {
  final bool selected;
  final bool hovering;
  final IconData icon;
  final String label;
  final ColorScheme scheme;
  final bool isDark;
  final double radius;

  const _ModalityPillSurface({
    required this.selected,
    required this.hovering,
    required this.icon,
    required this.label,
    required this.scheme,
    required this.isDark,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final Color contentColor = selected
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? null
            : scheme.surfaceContainerHighest.withValues(
                alpha: isDark ? 0.55 : 0.80,
              ),
        gradient: selected
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: isDark ? 0.34 : 0.22),
                  scheme.primary.withValues(alpha: isDark ? 0.16 : 0.10),
                  Colors.white.withValues(alpha: isDark ? 0.05 : 0.12),
                ],
                stops: const [0, 0.58, 1],
              )
            : null,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: hovering
              ? scheme.primary
              : selected
              ? scheme.primary.withValues(alpha: 0.44)
              : scheme.outlineVariant.withValues(alpha: 0.60),
          width: hovering ? 1.4 : 0.7,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: scheme.primary.withValues(
                    alpha: isDark ? 0.20 : 0.14,
                  ),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: contentColor),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: selected ? 12 : 11.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: contentColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
