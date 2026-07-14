import 'dart:io' show Platform;
import 'package:flutter/material.dart';

class AppTheme {
  static final String monoFont = Platform.isWindows ? 'Consolas' : 'monospace';

  static ThemeData dark({int seedColor = 0xFF5E6AD2, String fontFamily = '', double fontSize = 14.0, int fontWeight = 400}) {
    final scheme = ColorScheme.fromSeed(seedColor: Color(seedColor), brightness: Brightness.dark);
    return _build(scheme, fontFamily, fontSize, fontWeight);
  }

  static ThemeData light({int seedColor = 0xFF5E6AD2, String fontFamily = '', double fontSize = 14.0, int fontWeight = 400}) {
    final scheme = ColorScheme.fromSeed(seedColor: Color(seedColor), brightness: Brightness.light);
    return _build(scheme, fontFamily, fontSize, fontWeight);
  }

  static ThemeData _build(ColorScheme scheme, String fontFamily, double fontSize, int fontWeight) {
    final scale = fontSize / 14.0;
    final w = _fw(fontWeight);
    final base = ThemeData.fallback().textTheme;
    TextStyle s(TextStyle? b, double sz) => (b ?? const TextStyle()).copyWith(fontSize: (sz * scale), fontWeight: w);

    final tt = base.copyWith(
      displayLarge: s(base.displayLarge, 57), displayMedium: s(base.displayMedium, 45), displaySmall: s(base.displaySmall, 36),
      headlineLarge: s(base.headlineLarge, 32), headlineMedium: s(base.headlineMedium, 28), headlineSmall: s(base.headlineSmall, 24),
      titleLarge: s(base.titleLarge, 22), titleMedium: s(base.titleMedium, 16), titleSmall: s(base.titleSmall, 14),
      bodyLarge: s(base.bodyLarge, 16), bodyMedium: s(base.bodyMedium, 14), bodySmall: s(base.bodySmall, 12),
      labelLarge: s(base.labelLarge, 14), labelMedium: s(base.labelMedium, 12), labelSmall: s(base.labelSmall, 11),
    );

    final fallback = Platform.isWindows
        ? const ['Microsoft YaHei', 'SimHei', 'SimSun', 'KaiTi', 'sans-serif']
        : Platform.isMacOS
            ? const ['PingFang SC', 'Hiragino Sans GB', 'SF Pro Text', 'Menlo', 'sans-serif']
            : const ['Noto Sans CJK SC', 'WenQuanYi Micro Hei', 'DejaVu Sans', 'sans-serif'];

    final appliedTt = fontFamily.isNotEmpty && !fontFamily.contains('\\') && !fontFamily.contains('/')
        ? tt.apply(fontFamily: fontFamily, fontFamilyFallback: fallback)
        : tt.apply(fontFamilyFallback: fallback);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamilyFallback: fallback,
      textTheme: appliedTt,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface.withAlpha(180),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(40)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface.withAlpha(120),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: scheme.outline, width: 1.5)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: scheme.outline.withAlpha(140), width: 1.5)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: scheme.primary, width: 2)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        isDense: false,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1),
    );
  }

  static FontWeight _fw(int w) {
    const m = {100: FontWeight.w100, 200: FontWeight.w200, 300: FontWeight.w300, 400: FontWeight.w400,
        500: FontWeight.w500, 600: FontWeight.w600, 700: FontWeight.w700, 800: FontWeight.w800, 900: FontWeight.w900};
    return m[w] ?? FontWeight.w400;
  }
}
