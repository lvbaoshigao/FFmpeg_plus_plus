import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';

/// 统一「表面样式」常量（卡片 / 移动端底部菜单栏 / 移动端顶部药丸共用）：
/// - [theme]  跟随主题色（纯色，不透明卡片；设置了主题渐变时显示渐变）
/// - [liquid] 液态玻璃
/// - [blur]   模糊（高斯模糊 + 半透明 surface）
/// - [gray]   灰色（纯色容器色）
class SurfaceStyle {
  static const String theme = 'theme';
  static const String liquid = 'liquid';
  static const String blur = 'blur';
  static const String gray = 'gray';
  static const List<String> all = [theme, liquid, blur, gray];
}

/// 卡片玻璃渲染所需的「配置指纹」：只有它变化时才允许重建
/// OCLiquidGlassGroup/OCLiquidGlass 节点或切换渲染分支，避免无关
/// notify（进度/日志/任务）引起的 shader 重置与整卡重建。
@immutable
class _CardGlassKey {
  final String style;
  final double op;
  final int primary;
  final int second;
  const _CardGlassKey({
    required this.style,
    required this.op,
    required this.primary,
    required this.second,
  });

  @override
  bool operator ==(Object other) =>
      other is _CardGlassKey &&
      other.style == style &&
      other.op == op &&
      other.primary == primary &&
      other.second == second;

  @override
  int get hashCode => Object.hash(style, op, primary, second);
}

/// 应用统一卡片容器 —— 接管「设置 / 项目 / 处理队列 / 配置库」的卡片样式。
///
/// 样式由 [style]（AppConfig.cardStyle 四值）决定：
/// - 'liquid' 移动端：oc_liquid_glass GPU 液态玻璃（与底部导航/药丸同参数）；
///             桌面端：背景模糊 + 上亮下暗体感渐变玻璃
/// - 'blur'   扁平高斯模糊 + 半透明 surface
/// - 'theme'  跟随主题色纯色（主题渐变时渐变；不透明度对可读性做下限钳制）
/// - 'gray'   灰色纯色容器（surfaceContainerHigh）
///
/// 不透明度统一由全局 `cardOpacity` 控制。
class AppCard extends StatefulWidget {
  final Widget child;
  /// 表面样式（SurfaceStyle 四值之一）
  final String style;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  /// 可选点击回调（卡片整体可点，如配置库条目）
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    required this.style,
    this.radius = 16,
    this.padding,
    this.margin,
    this.onTap,
  });

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _pressed = false;

  /// 液态玻璃静态 settings：与底部导航/药丸保持同一份 const 实例，
  /// 避免每次 build 新建 settings 触发 shader uniform 重置（移动端表现为
  /// 液态玻璃「来回跳跃」闪烁）。
  static const _liquidSettings = OCLiquidGlassSettings(
    refractStrength: -0.10,
    blurRadiusPx: 0.0,
    specStrength: 0.5,
    specPower: 48,
    specWidth: 10,
    lightbandStrength: 0.0,
    lightbandColor: Colors.white,
  );

  static _CardGlassKey _keyOf(AppState s, String style) {
    final c = s.config;
    return _CardGlassKey(
      style: style,
      op: c.cardOpacity,
      primary: c.themeColor,
      second: c.themeColor2,
    );
  }

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = widget.style;
    // 仅订阅玻璃渲染相关字段，进度/日志等高频 notify 不会重建卡片。
    final key = context.select<AppState, _CardGlassKey>((s) => _keyOf(s, style));
    final op = key.op.clamp(0.0, 1.0);
    final radius = widget.radius;
    final br = BorderRadius.circular(radius);
    // 主题渐变：themeColor2 >= 0 时纯色表面改用 起色→止色 渐变
    final grad = key.second >= 0 ? <Color>[Color(key.primary), Color(key.second)] : null;
    // 卡片内放一层透明 Material 作为 ink 宿主：纯色/模糊表面有背景色，
    // 内部 ListTile/SwitchListTile 的水波纹与选中底色必须画在「卡片之上」
    // 才会可见（否则画在页面 Material 上被卡片背景遮住，并触发
    // Flutter「ListTile background may be invisible」错误）。
    final inner = Material(type: MaterialType.transparency, child: widget.child);

    Widget core;
    if (style == SurfaceStyle.theme || style == SurfaceStyle.gray) {
      // 纯色卡片：必须「看起来是纯色」——alpha 跟随不透明度但保底 ~88%，
      // 否则用户把卡片不透明度调低后会误以为纯色模式失效（变成透明）。
      final base = style == SurfaceStyle.theme ? scheme.primary : scheme.surfaceContainerHigh;
      final alpha = ((isDark ? 238.0 : 248.0) * op.clamp(0.88, 1.0)).round().clamp(0, 255);
      core = RepaintBoundary(
        child: Container(
          padding: widget.padding,
          decoration: BoxDecoration(
            color: grad == null ? base.withAlpha(alpha) : null,
            gradient: grad != null
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: grad.map((c) => c.withAlpha(alpha)).toList(),
                  )
                : null,
            borderRadius: br,
            border: Border.all(color: scheme.outlineVariant.withAlpha(isDark ? 45 : 70), width: 0.6),
            boxShadow: [
              BoxShadow(color: Colors.black.withAlpha(isDark ? 30 : 12), blurRadius: 12, offset: const Offset(0, 3)),
            ],
          ),
          child: inner,
        ),
      );
    } else if (style == SurfaceStyle.blur) {
      final alpha = ((isDark ? 110.0 : 130.0) * op).round().clamp(0, 255);
      core = RepaintBoundary(
        child: ClipRRect(
          borderRadius: br,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              padding: widget.padding,
              decoration: BoxDecoration(
                borderRadius: br,
                color: scheme.surface.withAlpha(alpha),
                border: Border.all(color: scheme.outlineVariant.withAlpha(isDark ? 60 : 80), width: 0.6),
              ),
              child: inner,
            ),
          ),
        ),
      );
    } else if (style == SurfaceStyle.liquid && isMobilePlatform) {
      // 移动端液态玻璃：oc_liquid_glass GPU shader（与底部导航/药丸一致）。
      // OCLiquidGlass 自身接收 color=tint；inner 只保留边框，避免双重染色。
      final tint = scheme.surface.withAlpha((op * 255).round().clamp(0, 255));
      final glassKey = ValueKey<_CardGlassKey>(key);
      final innerKey = ValueKey<String>('${key.hashCode}_appcard_inner');
      core = RepaintBoundary(
        child: OCLiquidGlassGroup(
          key: glassKey,
          settings: _liquidSettings,
          child: OCLiquidGlass(
            key: innerKey,
            borderRadius: radius,
            color: tint,
            shadow: BoxShadow(
              color: Colors.black.withAlpha(isDark ? 60 : 22),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
            child: Container(
              padding: widget.padding,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: br,
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.18),
                  width: 0.7,
                ),
              ),
              child: inner,
            ),
          ),
        ),
      );
    } else {
      // 桌面端液态玻璃：背景模糊 + 上亮下暗体感渐变（GlassPanel liquid 的
      // 自包含简化版，不再依赖全局 glassEffect）。
      final alphaTop = ((isDark ? 96.0 : 118.0) * op).round();
      final alphaBot = ((isDark ? 46.0 : 62.0) * op).round();
      core = RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: br,
            boxShadow: [
              BoxShadow(color: Colors.black.withAlpha(isDark ? 60 : 26), blurRadius: 18, offset: const Offset(0, 6)),
            ],
          ),
          child: ClipRRect(
            borderRadius: br,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: widget.padding,
                decoration: BoxDecoration(
                  borderRadius: br,
                  color: op <= 0.001 ? Colors.transparent : null,
                  gradient: op > 0.001
                      ? LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: grad != null
                              ? [
                                  Color.lerp(grad.first, Colors.black, 0)!.withAlpha(alphaTop),
                                  Color.lerp(grad.last, Colors.black, 0.15)!.withAlpha(alphaBot),
                                ]
                              : [
                                  scheme.surface.withAlpha(alphaTop),
                                  scheme.surface.withAlpha((alphaTop + alphaBot) ~/ 2),
                                  scheme.surface.withAlpha(alphaBot),
                                ],
                          stops: grad == null ? const [0.0, 0.55, 1.0] : null,
                        )
                      : null,
                  border: Border.all(
                    color: op <= 0.001
                        ? Colors.transparent
                        : Colors.white.withValues(alpha: isDark ? 0.14 : 0.28),
                    width: 1,
                  ),
                ),
                child: inner,
              ),
            ),
          ),
        ),
      );
    }

    Widget result = core;
    if (widget.margin != null) {
      result = Padding(padding: widget.margin!, child: result);
    }
    if (widget.onTap != null) {
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) {
          _setPressed(false);
          widget.onTap!();
        },
        onTapCancel: () => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? 0.985 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: result,
        ),
      );
    }
    return result;
  }
}
