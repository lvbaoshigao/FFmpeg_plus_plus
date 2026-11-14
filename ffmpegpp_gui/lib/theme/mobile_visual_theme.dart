import 'package:flutter/material.dart';
import 'app_neutral_surface.dart';

/// Flutter-native, Miuix-inspired roles, not a pixel replica or Compose port.
/// Reference: https://github.com/Xocio/ZeroUI/blob/main/kit/src/main/java/com/zeroui/kit/theme/ZeroTokens.kt
/// Neutral surfaces are this app's choice; accent, fonts and materials stay independent.
@immutable
class MobileVisualTheme extends ThemeExtension<MobileVisualTheme> {
  const MobileVisualTheme({this.enabled = false});
  final bool enabled;
  double get menuRadius => enabled ? 20 : 12;
  double get chatRadius => enabled ? 20 : 16;
  double get chatInset => enabled ? 16 : 12;
  double bubbleRadius(double fallback) => enabled ? 20 : fallback;

  static MobileVisualTheme of(BuildContext context) =>
      Theme.of(context).extension<MobileVisualTheme>() ??
      const MobileVisualTheme();

  ThemeData applyTo(ThemeData base) {
    if (!enabled) return base;
    final scheme = base.colorScheme;
    final page = AppNeutralSurface.background(scheme.brightness);
    final card = AppNeutralSurface.card(scheme.brightness);
    return base.copyWith(
      colorScheme: scheme.copyWith(
        surface: page,
        surfaceContainer: card,
        surfaceContainerLow: page,
        surfaceContainerHigh: card,
        surfaceContainerHighest: card,
      ),
      extensions: [
        ...base.extensions.values.where((e) => e is! MobileVisualTheme),
        this,
      ],
    );
  }

  @override
  MobileVisualTheme copyWith({bool? enabled}) =>
      MobileVisualTheme(enabled: enabled ?? this.enabled);

  @override
  MobileVisualTheme lerp(covariant MobileVisualTheme? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

MobileVisualTheme resolveMobileVisualTheme(
  String configured, {
  required bool isMobile,
}) => MobileVisualTheme(enabled: isMobile && configured == 'miuix');
