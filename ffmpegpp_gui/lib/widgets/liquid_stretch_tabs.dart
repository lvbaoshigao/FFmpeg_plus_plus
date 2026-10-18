import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'mobile_glass_pill.dart';

/// 顶部「基本 / 模型」分段选项卡的一个段。
@immutable
class LiquidStretchTab {
  final IconData icon;
  final String label;

  const LiquidStretchTab({required this.icon, required this.label});
}

/// 液态玻璃「拉伸」分段选项卡。
///
/// 与普通分段控件的区别（对应设计稿 3 的非线性药丸拉伸）：
/// * 选中指示块不是淡入淡出的静态底色，而是一块跟着手指移动的玻璃；
/// * 移动时**前缘先走、后缘后走**（两条不同缓动曲线），因此指示块在途中会
///   横向拉长，落位后收回原宽 —— 这就是「非线性的药丸拉伸」；
/// * 指示块本身带主题色渐变 + 高光 + 细描边（不引入任何写死色值）。
///
/// 外层直接复用 [MobileGlassPill]，因此四种 pillStyle（liquid / blur /
/// theme / gray）与顶栏、搜索药丸完全一致；内部宽度变化用 [AnimatedBuilder]
/// 只重绘这条选项卡，不触发页面其它部分重建。
class LiquidStretchTabs extends StatefulWidget {
  /// 选中指示块的 key（测试/诊断用）。
  static const Key indicatorKey = ValueKey('liquid_stretch_tab_indicator');

  final List<LiquidStretchTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// MobileGlassPill 的样式（AppConfig.pillStyle 四值之一）。
  final String style;
  final double height;
  final double radius;

  /// 无障碍分组标签（例如「基本 / 模型」）。
  final String? semanticsLabel;

  final Duration duration;

  const LiquidStretchTabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onChanged,
    required this.style,
    this.height = 42,
    this.radius = 21,
    this.semanticsLabel,
    this.duration = const Duration(milliseconds: 420),
  }) : assert(tabs.length > 0);

  @override
  State<LiquidStretchTabs> createState() => _LiquidStretchTabsState();
}

class _LiquidStretchTabsState extends State<LiquidStretchTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late double _from;
  late double _to;

  @override
  void initState() {
    super.initState();
    _from = widget.selectedIndex.toDouble();
    _to = _from;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(LiquidStretchTabs old) {
    super.didUpdateWidget(old);
    if (old.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    final int next = widget.selectedIndex.clamp(0, widget.tabs.length - 1);
    if (old.selectedIndex != widget.selectedIndex ||
        old.tabs.length != widget.tabs.length) {
      // 动画中途再次切换时从当前视觉位置继续，避免指示块瞬移。
      final current = lerpDouble(_from, _to, _controller.value) ?? _to;
      _from = current;
      _to = next.toDouble();
      if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
        _from = _to;
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final count = widget.tabs.length;
    final Widget pill = MobileGlassPill(
      style: widget.style,
      height: widget.height,
      radius: widget.radius,
      padding: const EdgeInsets.all(3),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : math.max(
                  0,
                  MediaQuery.sizeOf(context).width -
                      2 * MediaQuery.paddingOf(context).horizontal -
                      24,
                );
          final double slot = count == 0 ? 0 : width / count;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final double p = _controller.value;
              // 前缘快、后缘慢：easeOutQuart / easeInQuart 的差值就是拉伸量。
              final double lead = Curves.easeOutQuart.transform(p);
              final double lag = Curves.easeInQuart.transform(p);
              final bool rightward = _to >= _from;
              // 保留一部分线性位移，避免相邻两颗（只有 2 段时）拉得过长。
              final double leftT = lerpDouble(
                p,
                rightward ? lag : lead,
                0.35,
              )!;
              final double rightT = lerpDouble(
                p,
                rightward ? lead : lag,
                0.35,
              )!;
              final double fromLeft = _from * slot;
              final double toLeft = _to * slot;
              final double fromRight = fromLeft + slot;
              final double toRight = toLeft + slot;
              final double left = (fromLeft + (toLeft - fromLeft) * leftT)
                  .clamp(0.0, width);
              final double right = (fromRight + (toRight - fromRight) * rightT)
                  .clamp(0.0, width);
              final double indicatorWidth = math.max(0.0, right - left);
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned(
                    left: left,
                    top: 0,
                    bottom: 0,
                    width: indicatorWidth,
                    child: RepaintBoundary(
                      child: DecoratedBox(
                        key: LiquidStretchTabs.indicatorKey,
                        decoration: _indicatorDecoration(scheme, isDark),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < count; i++)
                        Expanded(
                          child: _buildTab(context, i, scheme, isDark),
                        ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
    final String? label = widget.semanticsLabel;
    if (label == null || label.isEmpty) return pill;
    return Semantics(container: true, label: label, child: pill);
  }

  BoxDecoration _indicatorDecoration(ColorScheme scheme, bool isDark) {
    final double radius = math.max(0, widget.radius - 3);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          scheme.primary.withValues(alpha: isDark ? 0.34 : 0.22),
          scheme.primary.withValues(alpha: isDark ? 0.18 : 0.12),
          Colors.white.withValues(alpha: isDark ? 0.06 : 0.14),
        ],
        stops: const [0, 0.58, 1],
      ),
      border: Border.all(
        color: scheme.primary.withValues(alpha: isDark ? 0.42 : 0.30),
        width: 0.8,
      ),
      boxShadow: [
        BoxShadow(
          color: scheme.primary.withValues(alpha: isDark ? 0.20 : 0.14),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }

  Widget _buildTab(
    BuildContext context,
    int index,
    ColorScheme scheme,
    bool isDark,
  ) {
    final LiquidStretchTab tab = widget.tabs[index];
    final bool selected = index == widget.selectedIndex;
    final Color color = selected ? scheme.primary : scheme.onSurfaceVariant;
    final Duration textDuration =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(math.max(0, widget.radius - 3)),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        onTap: () {
          if (!selected) widget.onChanged(index);
        },
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(tab.icon, size: 15, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: textDuration,
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                  child: Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
