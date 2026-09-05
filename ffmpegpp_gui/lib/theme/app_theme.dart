import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

class AppTheme {
  static final String monoFont = Platform.isWindows ? 'Consolas' : 'monospace';

  /// seedColor 为用户自定义主题色；dynamicSeed 非空时（Android Monet
  /// 动态取色）覆盖它作为种子色，使用与系统 Material You 一致的
  /// tonalSpot 方案生成整套配色。
  static ThemeData dark({int seedColor = 0xFF5E6AD2, String fontFamily = '', double fontSize = 14.0, int fontWeight = 400, int? dynamicSeed, bool predictiveBack = true, String glassEffect = 'liquid'}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Color(dynamicSeed ?? seedColor),
      brightness: Brightness.dark,
    );
    return _build(scheme, fontFamily, fontSize, fontWeight, predictiveBack: predictiveBack, glassEffect: glassEffect);
  }

  static ThemeData light({int seedColor = 0xFF5E6AD2, String fontFamily = '', double fontSize = 14.0, int fontWeight = 400, int? dynamicSeed, bool predictiveBack = true, String glassEffect = 'liquid'}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Color(dynamicSeed ?? seedColor),
      brightness: Brightness.light,
    );
    return _build(scheme, fontFamily, fontSize, fontWeight, predictiveBack: predictiveBack, glassEffect: glassEffect);
  }

  static ThemeData _build(ColorScheme scheme, String fontFamily, double fontSize, int fontWeight, {bool predictiveBack = true, String glassEffect = 'liquid'}) {
    final isDark = scheme.brightness == Brightness.dark;
    // 字号缩放统一交给 app.dart 里的 MediaQuery.textScaler（TextScaler.linear(fontSize/14)），
    // 这里不能再 `sz * scale`，否则字号会被乘两次（默认 17 号会渲染成约 20.6px）。
    final w = _fw(fontWeight);
    final base = ThemeData.fallback().textTheme;
    TextStyle s(TextStyle? b, double sz) => (b ?? const TextStyle()).copyWith(fontSize: sz, fontWeight: w, color: scheme.onSurface);

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
      // 预测式返回手势（Android 14+）：开启时 Android 使用 PredictiveBack 转场，
      // 关闭时回退到 Zoom 转场。iOS/macOS 沿用 Cupertino，桌面沿用 Zoom。
      pageTransitionsTheme: PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: predictiveBack
              ? const PredictiveBackPageTransitionsBuilder()
              : const ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: const ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: const ZoomPageTransitionsBuilder(),
        },
      ),
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
        fillColor: scheme.surfaceContainerHighest.withAlpha(80),
        hintStyle: TextStyle(color: scheme.outline, fontSize: 13),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        floatingLabelStyle: TextStyle(color: scheme.primary, fontWeight: FontWeight.w500),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.outlineVariant, width: 1)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(160), width: 1)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.primary, width: 1.5)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.error, width: 1)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        isDense: true,
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
      // 必须和 filledButtonTheme 保持同样的圆角/内边距：否则 OutlinedButton 会退回
      // Material 3 默认值（胶囊形 + 更小的内边距），和旁边的 FilledButton 并排时
      // 高度和圆角都对不上（例如「容器」与「添加文件」）。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            side: BorderSide(color: scheme.outlineVariant.withAlpha(160)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 1),
      // DropdownMenu / 下拉菜单：大圆角 + 玻璃质感 + 阴影（避免深色下纯黑）
      dropdownMenuTheme: DropdownMenuThemeData(
        // 触发框：与全局输入框一致的主题化圆角填充样式
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withAlpha(90),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.outlineVariant, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(160), width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.primary, width: 1.5),
          ),
        ),
        menuStyle: MenuStyle(
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(color: scheme.outlineVariant.withAlpha(70)))),
          surfaceTintColor: WidgetStatePropertyAll(scheme.surface),
          elevation: WidgetStatePropertyAll(12),
          padding: WidgetStatePropertyAll(const EdgeInsets.symmetric(vertical: 8)),
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest.withAlpha(240)),
          shadowColor: WidgetStatePropertyAll(Colors.black.withAlpha(isDark ? 80 : 30)),
          // 展开面板宽高上限：DropdownMenu 未显式给 width 时会按最长条目
          // （含 leadingIcon）撑开，桌面端表现为「菜单栏过大 / 宽度极大」。
          // 这里兜底约束，个别下拉再用自身 width/menuHeight 精确控制。
          maximumSize: const WidgetStatePropertyAll(Size(320, 320)),
        ),
      ),
      // 所有弹出菜单（PopupMenuButton / 右键菜单等）统一圆角矩形。
      // 注意：PopupMenuThemeData 不支持 constraints（该参数只存在于
      // PopupMenuButton / showMenu 上），所以菜单宽度无法在主题层统一兜底。
      // 宽度上限由各 PopupMenuButton 自身的 constraints（含 maxWidth）控制，
      // 凡是显式传了 constraints 的按钮都必须带上 maxWidth，否则会覆盖掉
      // 默认的 280 上限，菜单就会按最长条目无限撑宽（见各页面注释）。
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 8,
      ),
      // 所有对话框统一风格：
      // - 液态玻璃 / 模糊：半透明磨砂背景（透出后面玻璃层）+ 细边框 + 无 M3 tint；
      // - none（透明）：恢复高不透明实心背景，避免文字透底难读。
      dialogTheme: DialogThemeData(
        backgroundColor: glassEffect == 'none'
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerHigh.withAlpha(isDark ? 0xE4 : 0xDC),
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color: glassEffect == 'none'
                ? Colors.transparent
                : scheme.outlineVariant.withAlpha(isDark ? 70 : 90),
            width: 0.6,
          ),
        ),
      ),
    );
  }

  static FontWeight _fw(int w) {
    const m = {100: FontWeight.w100, 200: FontWeight.w200, 300: FontWeight.w300, 400: FontWeight.w400,
        500: FontWeight.w500, 600: FontWeight.w600, 700: FontWeight.w700, 800: FontWeight.w800, 900: FontWeight.w900};
    return m[w] ?? FontWeight.w400;
  }
}
