import 'package:flutter/widgets.dart';

/// Layout of a [LiquidGlassTabBar].
///
/// The defaults are tuned against the native iOS 26 tab bar.
@immutable
class LiquidGlassTabBarStyle {
  /// Creates a style. All values are in logical pixels.
  const LiquidGlassTabBarStyle({
    this.capsuleHeight = 54,
    this.capsuleInset = 4,
    this.capsuleOverhang = 6,
    this.horizontalMargin = 20,
    this.bottomGap,
    this.iconSize = 26,
    this.labelStyle,
    this.barTint,
    this.capsuleTint,
    this.lensTint,
  });

  /// Height of the selection capsule. The bar is this plus
  /// 2 × [capsuleInset] tall.
  final double capsuleHeight;

  /// Gap between the resting capsule and the edge of the bar, the same on all
  /// four sides.
  final double capsuleInset;

  /// How far the resting capsule reaches past its item on the left and the
  /// right, so it is wider than the item slot like on iOS 26. The items are
  /// moved inwards by the same amount, so the gap to the bar edge stays
  /// [capsuleInset].
  final double capsuleOverhang;

  /// Distance between the bar and the left/right edges of the screen.
  final double horizontalMargin;

  /// Distance between the bar and the bottom safe area.
  ///
  /// When `null` the platform default is used: on iOS devices with a home
  /// indicator the bar sinks 8 pt into the indicator area like the native
  /// tab bar does; everywhere else it floats 12 above the safe area.
  final double? bottomGap;

  /// Size of [Icon]s inside the items.
  final double iconSize;

  /// Style of the item labels. Its color is ignored — the bar sets it.
  final TextStyle? labelStyle;

  /// Tint of the bar glass surface. When null, the iOS 26 default is kept
  /// (white 68% light, black 35% dark).
  final Color? barTint;

  /// Fill of the resting selection capsule below the items. When null, the
  /// iOS 26 default is kept (black 5% light, gray 25% dark).
  final Color? capsuleTint;

  /// Tint of the glass lens droplet while pressed, dragging or switching.
  /// When null, the iOS 26 default is kept (clear white).
  final Color? lensTint;

  /// Total height of the bar itself (without margins).
  double get barHeight => capsuleHeight + 2 * capsuleInset;
}
