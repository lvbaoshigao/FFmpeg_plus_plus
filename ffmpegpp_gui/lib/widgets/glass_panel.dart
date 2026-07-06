import 'dart:ui';
import 'package:flutter/material.dart';

/// 液态玻璃面板 —— 圆角 + 背景模糊 + 半透明渐变 + 边框 + 柔和阴影
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  /// 顶部渐变的不透明度 (0-255)。为空时使用主题默认值。
  final int? tintAlpha;

  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 18,
    this.blur = 16,
    this.padding,
    this.tintAlpha,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final br = BorderRadius.circular(radius);
    final topA = tintAlpha ?? (isDark ? 190 : 210);
    final botA = tintAlpha != null
        ? (tintAlpha! - 45).clamp(20, 255)
        : (isDark ? 140 : 165);

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: br,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 60 : 28),
              blurRadius: 24,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: br,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: br,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.surface.withAlpha(topA),
                    scheme.surface.withAlpha(botA),
                  ],
                ),
                border: Border.all(
                  color: scheme.outlineVariant.withAlpha(isDark ? 90 : 120),
                  width: 1,
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮动液态玻璃顶栏 —— 每个页面顶部的标题+操作按钮容器
class GlassTopBar extends StatelessWidget {
  final Widget title;
  final List<Widget> actions;
  final double height;

  const GlassTopBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: GlassPanel(
        radius: 18,
        child: SizedBox(
          height: height,
          child: Row(children: [
            const SizedBox(width: 16),
            Expanded(
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                child: title,
              ),
            ),
            ...actions,
            const SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }
}
