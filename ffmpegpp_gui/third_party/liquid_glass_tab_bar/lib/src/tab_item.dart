import 'package:flutter/widgets.dart';

/// One destination in a [LiquidGlassTabBar].
///
/// The bar paints every item twice (once in the unselected color and once in
/// the selected color, clipped to the moving capsule) so the color flows
/// smoothly while the capsule slides. Because of that the icon must look the
/// same in both layers except for its color:
///
///  * Use [LiquidGlassTabItem.new] with an [Icon] (or any widget that reads
///    the ambient [IconTheme]).
///  * Use [LiquidGlassTabItem.builder] for icons that need the color passed in
///    explicitly, such as SVGs.
///
/// Leave [label] out for an icon-only item; then give a [semanticLabel] so
/// screen readers can still announce it.
@immutable
class LiquidGlassTabItem {
  /// An item whose [icon] is colored through the ambient [IconTheme].
  const LiquidGlassTabItem({
    required Widget this.icon,
    this.label,
    this.semanticLabel,
  })  : iconBuilder = null,
        assert(
          label != null || semanticLabel != null,
          'An icon-only item needs a semanticLabel.',
        );

  /// An item whose icon is built with the current color, e.g. for SVGs:
  ///
  /// ```dart
  /// LiquidGlassTabItem.builder(
  ///   label: 'Home',
  ///   iconBuilder: (color) => SvgPicture.asset(
  ///     'assets/home.svg',
  ///     colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  ///   ),
  /// )
  /// ```
  const LiquidGlassTabItem.builder({
    required Widget Function(Color color) this.iconBuilder,
    this.label,
    this.semanticLabel,
  })  : icon = null,
        assert(
          label != null || semanticLabel != null,
          'An icon-only item needs a semanticLabel.',
        );

  /// The icon, colored through [IconTheme].
  final Widget? icon;

  /// Builds the icon with the given color.
  final Widget Function(Color color)? iconBuilder;

  /// The text shown under the icon. `null` for an icon-only item.
  final String? label;

  /// Optional label for screen readers. Defaults to [label].
  final String? semanticLabel;
}
