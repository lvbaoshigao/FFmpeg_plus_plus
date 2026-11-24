import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lgr;

import 'droplet_track.dart';
import 'glass_surface.dart';
import 'style.dart';
import 'tab_item.dart';

/// A floating iOS 26 style "liquid glass" tab bar.
///
/// At rest the selected item sits in a soft capsule. When the user taps
/// another item, presses and holds, or drags along the bar, the capsule turns
/// into a real refracting glass droplet that stretches, wobbles and follows
/// the finger, and the whole bar grows slightly.
///
/// Put it in [Scaffold.bottomNavigationBar] together with
/// `extendBody: true`, so the page content scrolls behind the glass:
///
/// ```dart
/// Scaffold(
///   extendBody: true,
///   body: pages[index],
///   bottomNavigationBar: LiquidGlassTabBar(
///     currentIndex: index,
///     onTap: (i) => setState(() => index = i),
///     items: const [
///       LiquidGlassTabItem(icon: Icon(Icons.home_outlined), label: 'Home'),
///       LiquidGlassTabItem(icon: Icon(Icons.search), label: 'Search'),
///       LiquidGlassTabItem(icon: Icon(Icons.person_outline), label: 'Profile'),
///     ],
///   ),
/// )
/// ```
///
/// Use [LiquidGlassTabBar.heightOf] to add bottom padding to scrollable
/// content so the last item is not hidden behind the bar.
///
/// Requires Impeller (the default renderer on iOS and Android).
class LiquidGlassTabBar extends StatefulWidget {
  /// Creates a liquid glass tab bar.
  const LiquidGlassTabBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.onTapIntercept,
    this.selectedColor,
    this.unselectedColor,
    this.style = const LiquidGlassTabBarStyle(),
  })  : assert(items.length >= 2, 'A tab bar needs at least two items.'),
        assert(currentIndex >= 0 && currentIndex < items.length);

  /// The destinations, left to right.
  ///
  /// At least two. There is no upper limit, but every item gets an equal
  /// share of the width — 2 to 5 items is recommended (like iOS); with more,
  /// labels get truncated on narrow phones.
  final List<LiquidGlassTabItem> items;

  /// Index of the selected item.
  final int currentIndex;

  /// Called when the user selects an item — by tapping it or by releasing a
  /// drag over it. Also called when the selected item is tapped again.
  final ValueChanged<int> onTap;

  /// Return `true` to handle a tap (or a drag released) on [index] yourself,
  /// e.g. to open a sheet for an "action" item. The selection then stays
  /// where it is and [onTap] is not called.
  final bool Function(int index)? onTapIntercept;

  /// Color of the selected icon and label. Defaults to
  /// [ColorScheme.primary].
  final Color? selectedColor;

  /// Color of the other icons and labels. Defaults to near-black in light
  /// mode and near-white in dark mode, like iOS 26.
  final Color? unselectedColor;

  /// Layout values.
  final LiquidGlassTabBarStyle style;

  /// Distance between the bar and the bottom safe area for [style] on the
  /// current platform. See [LiquidGlassTabBarStyle.bottomGap].
  static double bottomGapOf(
    BuildContext context, [
    LiquidGlassTabBarStyle style = const LiquidGlassTabBarStyle(),
  ]) {
    if (style.bottomGap case final gap?) return gap;
    final safe = MediaQuery.paddingOf(context).bottom;
    if (defaultTargetPlatform == TargetPlatform.iOS && safe > 0) return -8;
    return 12;
  }

  /// How much of the bottom of the screen the bar covers, including the safe
  /// area. Use it as bottom padding for scrollable content.
  static double heightOf(
    BuildContext context, [
    LiquidGlassTabBarStyle style = const LiquidGlassTabBarStyle(),
  ]) =>
      MediaQuery.paddingOf(context).bottom +
      bottomGapOf(context, style) +
      style.barHeight +
      _topPadding;

  /// Room above the bar for its shadow and the growing droplet.
  static const double _topPadding = 6;

  @override
  State<LiquidGlassTabBar> createState() => _LiquidGlassTabBarState();
}

class _LiquidGlassTabBarState extends State<LiquidGlassTabBar> {
  /// The whole bar grows slightly while the user interacts with it.
  bool _active = false;

  LiquidGlassTabBarStyle get _style => widget.style;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom +
        LiquidGlassTabBar.bottomGapOf(context, _style);
    final inset = _style.capsuleInset;
    final barRadius = _style.barHeight / 2;

    return MediaQuery.removePadding(
      context: context,
      removeBottom: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          _style.horizontalMargin,
          LiquidGlassTabBar._topPadding,
          _style.horizontalMargin,
          bottom,
        ),
        child: AnimatedScale(
          scale: _active ? 1.025 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: Stack(
            // The growing droplet may stick out of the bar — do not clip it.
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: GlassSurface(radius: barRadius, tint: _style.barTint),
              ),
              Padding(
                // Equal gap on all four sides of the resting capsule: the
                // capsule sticks out of the row by `capsuleOverhang` on each
                // end and still stops `inset` short of the bar edge.
                padding: EdgeInsets.symmetric(
                  horizontal: inset + _style.capsuleOverhang,
                  vertical: inset,
                ),
                child: SizedBox(
                  height: _style.capsuleHeight,
                  child: DropletTrack(
                    slotCount: widget.items.length,
                    selectedSlot: widget.currentIndex,
                    onSlotSelected: widget.onTap,
                    onSlotTap: widget.onTapIntercept,
                    onActiveChanged: (v) => setState(() => _active = v),
                    capsuleHeight: _style.capsuleHeight,
                    maxOverhang: _style.capsuleOverhang,
                    minGlassHeight: _style.barHeight,
                    indicatorBuilder: _lens,
                    indicatorBelowBuilder: _restCapsule,
                    itemBuilder: _item,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int index, bool active) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final selected = widget.selectedColor ?? theme.colorScheme.primary;
    final unselected = widget.unselectedColor ??
        (dark ? const Color(0xE6FFFFFF) : const Color(0xFF1C1C1E));
    final color = active ? selected : unselected;
    final item = widget.items[index];

    final Widget icon = item.iconBuilder != null
        ? item.iconBuilder!(color)
        : IconTheme.merge(
            data: IconThemeData(color: color, size: _style.iconSize),
            child: item.icon!,
          );

    return Semantics(
      button: true,
      selected: index == widget.currentIndex,
      label: item.semanticLabel ?? item.label,
      excludeSemantics: true,
      child: item.label == null
          // Icon-only: centered in the capsule.
          ? Center(child: icon)
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: _style.iconSize + 6,
                    child: Center(child: icon),
                  ),
                  Text(
                    item.label!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // Same weight in both layers — only the color may differ, or the
                    // two layers would not line up at the droplet's edge.
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ).merge(_style.labelStyle).copyWith(color: color),
                  ),
                ],
              ),
            ),
    );
  }

  /// The resting capsule, drawn BELOW the items; fades out as the glass lens
  /// takes over.
  Widget _restCapsule(BuildContext context, double glass) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fade = 1 - glass;
    final capsuleBase = _style.capsuleTint;
    return DecoratedBox(
      decoration: BoxDecoration(
        // Gray at 25% rather than white at 14%: the same gray on black, but
        // it does not wash out colourful content behind the bar, so the
        // selected color stays readable on top of it. A themed capsuleTint
        // replaces the neutral fill and keeps its own alpha through the fade.
        color: capsuleBase != null
            ? capsuleBase.withValues(alpha: capsuleBase.a * fade)
            : (dark
                  ? const Color(0xFF909090).withValues(alpha: 0.25 * fade)
                  : Colors.black.withValues(alpha: 0.05 * fade)),
        borderRadius: BorderRadius.circular(_style.capsuleHeight / 2),
        // No border: in light mode the shadow draws the edge, in dark mode the
        // fill alone is enough (like iOS).
        boxShadow: [
          if (!dark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06 * fade),
              blurRadius: 5,
              offset: const Offset(0, 1),
            ),
        ],
      ),
    );
  }

  /// The glass droplet, drawn ABOVE the items — only while interacting.
  Widget _lens(BuildContext context, double glass) {
    if (glass == 0) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;

    final lensBase = _style.lensTint ?? Colors.white;
    return lgr.LiquidGlass.withOwnLayer(
      // The renderer clamps the radius to half the height → an exact stadium.
      shape: const lgr.LiquidRoundedSuperellipse(borderRadius: 999),
      settings: lgr.LiquidGlassSettings(
        // A clear lens; the resting fill below fades out at the same rate.
        // A themed lensTint replaces the clear white and keeps its alpha.
        glassColor: lensBase.withValues(
          alpha: lerpDouble(0, (dark ? 0.05 : 0.18) * lensBase.a, glass)!,
        ),
        thickness: lerpDouble(0, 20, glass)!,
        // No blur: the lens sits on top of the icon.
        blur: 0,
        chromaticAberration: lerpDouble(0, 0.15, glass)!,
        lightIntensity: lerpDouble(0.1, 0.9, glass)!,
        refractiveIndex: lerpDouble(1.18, 1.32, glass)!,
        saturation: lerpDouble(1.0, 1.1, glass)!,
      ),
      // A thin rim sharpens the shader's soft edge. In light mode a gray rim
      // and an outside-only shadow keep the droplet visible on white pages.
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: StadiumBorder(
            side: BorderSide(
              color: dark
                  ? Colors.white.withValues(alpha: lerpDouble(0, 0.13, glass)!)
                  : Colors.black.withValues(alpha: lerpDouble(0, 0.08, glass)!),
            ),
          ),
          shadows: [
            if (!dark)
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: lerpDouble(0, 0.14, glass)!,
                ),
                blurRadius: 10,
                offset: const Offset(0, 2),
                blurStyle: BlurStyle.outer,
              ),
          ],
        ),
      ),
    );
  }
}
