import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart' as lgr;

/// The bar's own glass: a real refracting surface (liquid_glass_renderer) with
/// a soft outside-only shadow and a 1 px rim.
///
/// Light mode: a fairly opaque white tint and a bright rim, like iOS 26.
/// Dark mode: nearly clear glass with a faint gray fill, a very weak rim and
/// dimmed edge light — on a black page a bright rim reads as a hard outline.
class GlassSurface extends StatelessWidget {
  /// Creates the surface; it expands to its constraints.
  const GlassSurface({super.key, required this.radius, this.tint, this.rim});

  /// Corner radius of the bar.
  final double radius;

  /// Optional tint override for the glass; null keeps the iOS 26 default.
  final Color? tint;

  /// Optional 1 px rim override; null keeps the iOS 26 default.
  final Color? rim;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = lgr.LiquidRoundedSuperellipse(borderRadius: radius);
    return CustomPaint(
      // The shadow is painted separately and only OUTSIDE the shape: a
      // BoxShadow fills the whole shape and would darken the clear glass.
      painter: _OutsideShadowPainter(radius: radius),
      child: Container(
        foregroundDecoration: ShapeDecoration(
          shape: lgr.LiquidRoundedSuperellipse(
            borderRadius: radius,
            side: BorderSide(
              color: rim ??
                  (dark
                      ? Colors.white.withValues(alpha: 0.02)
                      : Colors.white.withValues(alpha: 0.5)),
            ),
          ),
        ),
        child: lgr.LiquidGlass.withOwnLayer(
          shape: shape,
          settings: lgr.LiquidGlassSettings(
            // Dark mode dims what is behind the bar like iOS 26 does; the
            // old near-clear glass turned a green button behind it neon.
            glassColor: tint ??
                (dark
                    ? Colors.black.withValues(alpha: 0.35)
                    // 0.68: the shader boosts saturation AFTER tinting, so
                    // with less white a colourful widget behind the bar looked
                    // darker and more saturated than on iOS 26.
                    : Colors.white.withValues(alpha: 0.68)),
            // Wide edge refraction band — the "iOS 26" look on a large panel.
            thickness: 32,
            // Light frost: content behind is recognisable as silhouettes.
            blur: 5,
            // The shader boosts saturation after tinting; on a dark bar 1.8
            // makes colourful content glow.
            saturation: dark ? 1.0 : 1.8,
            lightIntensity: dark ? 0.05 : 1.0,
            ambientStrength: 0.2,
          ),
          child: dark
              // On black the native bar is dark gray, not black.
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    // Also makes up for the dark tint, which no longer
                    // lightens the glass on black.
                    color: Colors.white.withValues(alpha: 0.074),
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  child: const SizedBox.expand(),
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _OutsideShadowPainter extends CustomPainter {
  const _OutsideShadowPainter({required this.radius});

  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outline = lgr.LiquidRoundedSuperellipse(
      borderRadius: radius,
    ).getOuterPath(rect);
    // Clip away the shape itself: only the outside remains.
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect.inflate(radius + 48)),
      outline,
    );
    const soft = BoxShadow(
      color: Color(0x24000000), // black 14 %
      blurRadius: 20,
      offset: Offset(0, 8),
    );
    canvas
      ..save()
      ..clipPath(outside)
      ..drawPath(outline.shift(soft.offset), soft.toPaint())
      // 2 px wide, half of it is clipped away → a visible 1 px contour that
      // separates the bar from white pages.
      ..drawPath(
        outline,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0x0D000000), // black 5 %
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_OutsideShadowPainter old) => old.radius != radius;
}
