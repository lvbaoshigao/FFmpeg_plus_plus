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
///
/// [pressable] 为 true 时（用于「内部无可点击元素」的药丸，如左上角标题药丸），
/// 手指按下放大、按住保持、松手回弹，提供触觉反馈。
class MobileGlassPill extends StatefulWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final bool pressable;
  final VoidCallback? onTap;

  const MobileGlassPill({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.margin,
    this.pressable = false,
    this.onTap,
  });

  @override
  State<MobileGlassPill> createState() => _MobileGlassPillState();
}

class _MobileGlassPillState extends State<MobileGlassPill> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cfg = context.watch<AppState>().config;
    final effect = cfg.glassEffect;
    final op = cfg.cardOpacity.clamp(0.0, 1.0);
    // 上限压低（约 41%~47% 不透明度）：避免浅色模式下 surface 底色叠满成
    // 一整片「发白」，让背景透出、保留玻璃通透感。
    final maxAlpha = isDark ? 105 : 120;
    final baseAlpha = (op * maxAlpha).round().clamp(0, 255);
    final follow = cfg.glassFollowTheme;
    final baseColor = follow ? scheme.primary : scheme.surface;
    final tint = baseColor.withAlpha(baseAlpha);

    final inner = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: effect == 'blur'
              ? scheme.outlineVariant.withAlpha(80)
              : Colors.white.withValues(alpha: isDark ? 0.12 : 0.18),
          width: effect == 'blur' ? 0.5 : 0.7,
        ),
      ),
      child: widget.child,
    );

    Widget pill;
    if (effect == 'none') {
      pill = inner;
    } else if (effect == 'blur') {
      pill = RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: inner,
          ),
        ),
      );
    } else {
      // liquid：液态玻璃 shader
      // 关闭高光带（lightband）与压低镜面高光：高光带按固定像素偏移绘制，
      // 在较「高」的内容（如设置项卡片）上会变成一条横向“分界线”，
      // 视觉上把内容截成两段 —— 这里去掉它，仅保留折射 + 柔和高光。
      pill = OCLiquidGlassGroup(
        settings: OCLiquidGlassSettings(
          refractStrength: -0.05,
          blurRadiusPx: 1.6,
          specStrength: isDark ? 6.0 : 8.0,
          specWidth: 4,
          lightbandStrength: 0.0,
          lightbandColor: Colors.white,
        ),
        child: OCLiquidGlass(
          borderRadius: widget.radius,
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

    Widget result = pill;
    
    if (widget.pressable || widget.onTap != null) {
      // 按下放大、按住保持、松手回弹。
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapUp: (_) {
          _set(false);
          widget.onTap?.call();
        },
        onTapCancel: () => _set(false),
        child: AnimatedScale(
          scale: _pressed ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: pill,
        ),
      );
    }
    
    // 应用 margin
    if (widget.margin != null) {
      result = Padding(padding: widget.margin!, child: result);
    }
    
    return result;
  }
}
