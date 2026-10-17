import 'package:flutter/material.dart';

/// User-selected neutral surfaces; independent of theme seed and Monet.
abstract final class AppNeutralSurface {
  static const darkBackground = Color(0xFF1A1A1A);
  static const lightBackground = Color(0xFFF2F2F2);
  static const darkCard = Color(0xFF2B2B2B);
  static const lightCard = Color(0xFFE4E4E4);

  static Color background(Brightness brightness) =>
      brightness == Brightness.dark ? darkBackground : lightBackground;

  static Color card(Brightness brightness) =>
      brightness == Brightness.dark ? darkCard : lightCard;
}
