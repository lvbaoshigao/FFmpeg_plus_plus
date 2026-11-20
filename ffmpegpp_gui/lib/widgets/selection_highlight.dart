import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import 'desktop_resize_scope.dart';
import 'liquid_glass_fallback.dart';

/// A decorative selection surface that fills its parent's finite bounds.
///
/// The navigation item owns its input, focus, and selected semantics. Glass
/// styles use neutral tints independently of the application's accent color.
final class SelectionHighlight extends StatelessWidget {
  /// Uses the configured selection style unless [style] overrides it.
  const SelectionHighlight({super.key, this.radius = 12, this.style});

  /// The corner radius in logical pixels.
  final double radius;

  /// Optional theme, liquid, blur, or outline override for a local preview.
  final String? style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final configured =
        style ??
        context.select<AppState?, String>(
          (state) => state?.config.selectionIndicatorStyle ?? 'theme',
        );
    final resolved = switch (configured) {
      'liquid' || 'blur' || 'outline' => configured,
      _ => 'theme',
    };
    final corners = BorderRadius.circular(radius);
    final highContrast = MediaQuery.highContrastOf(context);
    final neutralInk = neutralGray(scheme.onSurface);

    Widget surface;
    if (highContrast) {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          color: neutralGray(scheme.surfaceContainerHighest),
          borderRadius: corners,
          border: Border.all(color: scheme.onSurface, width: 2),
        ),
        child: const SizedBox.expand(),
      );
    } else if (resolved == 'theme' || resolved == 'outline') {
      surface = DecoratedBox(
        decoration: BoxDecoration(
          color: resolved == 'theme'
              ? scheme.secondaryContainer.withAlpha(200)
              : null,
          borderRadius: corners,
          border: resolved == 'outline'
              ? Border.all(
                  color: neutralInk.withValues(alpha: 0.72),
                  width: 1.5,
                )
              : null,
        ),
        child: const SizedBox.expand(),
      );
    } else {
      final tuning = glassTuningOf(context);
      final opacity = context
          .select<AppState?, double>(
            (state) => state?.config.cardOpacity ?? 0.7,
          )
          .clamp(0.0, 1.0);
      final isDark = scheme.brightness == Brightness.dark;
      final alpha = ((isDark ? 0.50 : 0.65) * opacity * tuning.tintScale).clamp(
        0.0,
        0.92,
      );
      final body = DecoratedBox(
        decoration: BoxDecoration(
          color: neutralGray(
            scheme.surfaceContainerHighest,
          ).withValues(alpha: alpha),
          borderRadius: corners,
          // Selection remains visible even with all glass edge effects disabled.
          border: Border.all(
            color: neutralInk.withValues(alpha: isDark ? 0.45 : 0.50),
            width: 1.25,
          ),
        ),
        child: const SizedBox.expand(),
      );
      final resizing = DesktopResizeScope.isResizingOf(context);
      final sigma = tunedGlassSigma(8, tuning);
      if (resolved == 'liquid') {
        surface = resizing
            ? body
            : LiquidGlassBackdrop(
                borderRadius: corners,
                sigma: sigma,
                tuning: tuning,
                opacity: opacity,
                child: body,
              );
      } else {
        surface = ClipRRect(
          borderRadius: corners,
          child: BackdropFilter(
            enabled: !resizing && sigma > 0,
            filter: cachedGlassBlur(sigma),
            child: body,
          ),
        );
      }
    }

    return IgnorePointer(child: ExcludeSemantics(child: surface));
  }
}
