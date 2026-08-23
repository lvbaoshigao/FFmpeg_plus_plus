import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

/// 移动端「液态玻璃药丸」容器 —— 与底部导航栏一致的玻璃质感。
///
/// 依据设置中的玻璃效果渲染：
/// - liquid：oc_liquid_glass 液态玻璃（GPU fragment shader）
/// - blur：扁平高斯模糊（BackdropFilter）
/// - none：纯色药丸
///
/// 供顶栏标题药丸、顶栏操作长药丸、搜索框药丸等复用。
class MobileGlassPill extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  const MobileGlassPill({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cfg = context.watch<AppState>().config;
    final effect = cfg.glassEffect;
    final op = cfg.cardOpacity.clamp(0.0, 1.0);
    final baseAlpha = (op * 255).round().clamp(0, 255);
    final follow = cfg.glassFollowTheme;
    final baseColor = follow ? scheme.primary : scheme.surface;
    final tint = baseColor.withAlpha(baseAlpha);

    final inner = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: effect == 'blur'
              ? scheme.outlineVariant.withAlpha(80)
              : Colors.white.withValues(alpha: isDark ? 0.16 : 0.32),
          width: effect == 'blur' ? 0.5 : 0.7,
        ),
      ),
      child: child,
    );

    if (effect == 'none') return inner;

    if (effect == 'blur') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: inner,
        ),
      );
    }

    // liquid：液态玻璃 shader
    return OCLiquidGlassGroup(
      settings: OCLiquidGlassSettings(
        refractStrength: -0.05,
        blurRadiusPx: 1.2,
        specStrength: isDark ? 14.0 : 20.0,
        specWidth: 8,
        lightbandStrength: 0.7,
        lightbandColor: Colors.white,
      ),
      child: OCLiquidGlass(
        borderRadius: radius,
        color: tint,
        shadow: BoxShadow(
          color: Colors.black.withAlpha(isDark ? 60 : 22),
          blurRadius: 16,
          offset: const Offset(0, 5),
        ),
        child: inner,
      ),
    );
  }
}
