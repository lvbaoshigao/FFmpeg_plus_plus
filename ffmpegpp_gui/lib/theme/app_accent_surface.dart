import 'package:flutter/material.dart';

import 'app_neutral_surface.dart';

/// 「主题色克制着色」：强调按钮 / 强调块的一整套配色。
///
/// 存在的理由：全应用的主行动按钮此前直接铺 `scheme.primary` 满色。主题色是
/// 靛蓝时看着还行，但主题色一旦换成琥珀 / 亮黄这类高饱和强色，按钮就变成
/// **一整块没有边界的荧光色块**——没有描边、没有层次，在深色玻璃底上尤其刺眼
/// （用户反馈「按钮始终是黄色的，而且没有任何边框」）。
///
/// 这里不再让按钮完全依附主题色，而是：
/// * [fill]：把主题色以低透明度**混进中性表面**（不是纯色铺底），
///   于是亮暗两套都有稳定的底色，主题色只贡献色相倾向；
/// * [border]：一条同色系的 1px 描边，给按钮明确边界（原先 primary 按钮
///   `side: BorderSide.none`，在深色底上完全糊住）；
/// * [foreground]：用 `onSurface` 而不是 `onPrimary`——底色已经很浅，
///   再配 `onPrimary` 会掉对比度。
///
/// 语义色（错误红 / 警告）不走这里，它们要保留「危险」辨识度。
@immutable
class AppAccentSurface {
  const AppAccentSurface({
    required this.fill,
    required this.foreground,
    required this.border,
  });

  /// 强调块的底色（主题色低透明度混入中性表面，恒为不透明）。
  final Color fill;

  /// 落在 [fill] 上的前景色。
  final Color foreground;

  /// 强调块的 1px 描边色。
  final Color border;

  static AppAccentSurface of(BuildContext context, {double strength = 1.0}) =>
      fromScheme(Theme.of(context).colorScheme, strength: strength);

  static AppAccentSurface fromScheme(
    ColorScheme scheme, {
    double strength = 1.0,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    final base = dark
        ? AppNeutralSurface.darkCardHigh
        : AppNeutralSurface.lightCardHigh;
    final t = strength.clamp(0.0, 1.6);
    final tintAlpha = ((dark ? 0.26 : 0.20) * t).clamp(0.0, 1.0);
    final borderAlpha = ((dark ? 0.42 : 0.34) * t).clamp(0.0, 1.0);
    return AppAccentSurface(
      fill: Color.alphaBlend(scheme.primary.withValues(alpha: tintAlpha), base),
      foreground: scheme.onSurface,
      border: scheme.primary.withValues(alpha: borderAlpha),
    );
  }

  /// 映射成可直接交给 Filled / Outlined / Text 按钮的 [ButtonStyle]。
  ButtonStyle style({
    OutlinedBorder? shape,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 12,
    ),
    Size minimumSize = const Size(0, 44),
    bool transparentFill = false,
  }) {
    final resolvedShape =
        shape ?? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? fill.withValues(alpha: 0.55)
            : transparentFill
            ? Colors.transparent
            : fill,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? foreground.withValues(alpha: 0.45)
            : foreground,
      ),
      overlayColor: WidgetStatePropertyAll(border.withValues(alpha: 0.18)),
      side: WidgetStatePropertyAll(BorderSide(color: border, width: 1)),
      padding: WidgetStatePropertyAll(padding),
      minimumSize: WidgetStatePropertyAll(minimumSize),
      shape: WidgetStatePropertyAll(resolvedShape),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
