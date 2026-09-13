import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import '../widgets/app_slider.dart' show appSliderThemeFor;

// ═══════════════════════════════════════════
// 路由转场：关闭「快照（SnapshotWidget）」版转场
// ═══════════════════════════════════════════

/// 无快照的 Zoom 转场（Android 默认转场的同款动画，但不抓离屏快照）。
///
/// 为什么必须关掉快照：
/// 1) framework 的 [ZoomPageTransitionsBuilder] 默认 allowSnapshotting = true，
///    会把**进入的路由**用 framework 的 SnapshotWidget 先抓成一张离屏快照再对快照做
///    缩放/淡入。本应用所有二级页面（设置二级菜单、命令页、日志页、节点编辑器…）都
///    铺了壁纸 + 玻璃（BackdropFilter / ImageFilter.shader）。快照是把子树光栅化到
///    一张图片，**采样不到 backdrop**——玻璃区域在快照里直接变成透明/黑色；
///    而且首帧快照尚未产出时整屏会先黑一下，用户反馈的「进入二级菜单屏幕总会先黑一下」
///    正是这个现象。
/// 2) 关闭后进入/退出的路由每帧实时绘制，壁纸与玻璃和内容保持一致，也不再黑屏。
///    代价只是转场期间失去 framework 的快照缓存优化（本应用的转场只有 200~250ms）。
///
/// [PredictiveBackPageTransitionsBuilder] 在**非返回手势**时也会回退到默认
/// ZoomPageTransitionsBuilder（同样开快照），所以这里一并替换。
class _NoSnapshotZoomTransitionsBuilder extends PageTransitionsBuilder {
  const _NoSnapshotZoomTransitionsBuilder();

  static const ZoomPageTransitionsBuilder _zoom = ZoomPageTransitionsBuilder(
    allowSnapshotting: false,
    allowEnterRouteSnapshotting: false,
  );

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      _zoom.buildTransitions(route, context, animation, secondaryAnimation, child);

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _zoom.delegatedTransition;
}

/// 预测式返回手势（Android 14+）：仅在实际的返回（pop）手势期间使用 framework 的
/// [PredictiveBackPageTransitionsBuilder]（保留跟手动画），其余路径（push、
/// 按钮返回、程序化导航）统一走无快照 Zoom，避免“黑一下”与玻璃失效。
class _NoSnapshotPredictiveBackTransitionsBuilder extends PageTransitionsBuilder {
  const _NoSnapshotPredictiveBackTransitionsBuilder();

  static const PredictiveBackPageTransitionsBuilder _predictive =
      PredictiveBackPageTransitionsBuilder();
  static const ZoomPageTransitionsBuilder _zoom = ZoomPageTransitionsBuilder(
    allowSnapshotting: false,
    allowEnterRouteSnapshotting: false,
  );

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.popGestureInProgress) {
      return _predictive.buildTransitions(
          route, context, animation, secondaryAnimation, child);
    }
    return _zoom.buildTransitions(route, context, animation, secondaryAnimation, child);
  }

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _zoom.delegatedTransition;
}

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
      // 转场统一使用「无快照」版本，见 _NoSnapshotZoomTransitionsBuilder 的说明：
      // 快照（SnapshotWidget）抓不到 BackdropFilter 的 backdrop → 二级页面首帧黑屏、
      // 玻璃区域变黑；关闭后壁纸与玻璃全程实时绘制。
      pageTransitionsTheme: PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: predictiveBack
              ? const _NoSnapshotPredictiveBackTransitionsBuilder()
              : const _NoSnapshotZoomTransitionsBuilder(),
          TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: const _NoSnapshotZoomTransitionsBuilder(),
          TargetPlatform.linux: const _NoSnapshotZoomTransitionsBuilder(),
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
      // ── 统一的滑动条 / 进度条样式 ──
      // 用户要求：所有进度条（滑动条）样式统一 —— 两边大圆角的矩形轨道、内部可滑动、
      // 滑块为主题色，并带滑动动画。
      // 放在主题层一次生效：设置页、视频滤镜/节点参数面板、任务卡等所有
      // Slider / RangeSlider 都会跟随，避免逐处替换却漏掉某处又变成两套样式。
      // 规格定义在唯一来源 widgets/app_slider.dart（轨道高 6、两端半圆、主题色滑块
      // + activationAnimation 驱动的按下放大与光晕），显式使用 AppSlider 的地方
      // 与这里完全同源，因此全应用滑动条外观一致。
      sliderTheme: appSliderThemeFor(scheme),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        linearMinHeight: 8,
        // 两端大圆角（高度 8 → 半径 4 = 半圆端）
        borderRadius: BorderRadius.circular(4),
        stopIndicatorColor: scheme.primary,
        circularTrackColor: scheme.surfaceContainerHighest,
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
