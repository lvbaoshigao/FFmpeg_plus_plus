import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../widgets/app_slider.dart' show appSliderThemeFor;
import 'app_accent_surface.dart';
import 'app_neutral_surface.dart';
import 'app_page_transitions.dart';
import 'app_press_feedback.dart';
import 'app_semantic_colors.dart';

class AppTheme {
  static const int defaultSeedColor = 0xFF5E6AD2;

  static final String monoFont = Platform.isWindows ? 'Consolas' : 'monospace';

  /// seedColor 为用户自定义主题色；dynamicSeed 非空时（Android Monet
  /// 动态取色）覆盖它作为种子色，使用与系统 Material You 一致的
  /// tonalSpot 方案生成整套配色。
  static ThemeData dark({
    int seedColor = defaultSeedColor,
    String fontFamily = '',
    double fontSize = 14.0,
    int fontWeight = 400,
    int? dynamicSeed,
    bool useThemeColor = true,
    bool predictiveBack = true,
    String glassEffect = 'liquid',
  }) {
    final scheme = _colorScheme(
      brightness: Brightness.dark,
      seedColor: seedColor,
      dynamicSeed: dynamicSeed,
      useThemeColor: useThemeColor,
    );
    return _build(
      scheme,
      fontFamily,
      fontSize,
      fontWeight,
      predictiveBack: predictiveBack,
      glassEffect: glassEffect,
    );
  }

  static ThemeData light({
    int seedColor = defaultSeedColor,
    String fontFamily = '',
    double fontSize = 14.0,
    int fontWeight = 400,
    int? dynamicSeed,
    bool useThemeColor = true,
    bool predictiveBack = true,
    String glassEffect = 'liquid',
  }) {
    final scheme = _colorScheme(
      brightness: Brightness.light,
      seedColor: seedColor,
      dynamicSeed: dynamicSeed,
      useThemeColor: useThemeColor,
    );
    return _build(
      scheme,
      fontFamily,
      fontSize,
      fontWeight,
      predictiveBack: predictiveBack,
      glassEffect: glassEffect,
    );
  }

  static ColorScheme _colorScheme({
    required Brightness brightness,
    required int seedColor,
    required int? dynamicSeed,
    required bool useThemeColor,
  }) {
    final accent = ColorScheme.fromSeed(
      seedColor: Color(
        useThemeColor ? (dynamicSeed ?? seedColor) : defaultSeedColor,
      ),
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    if (useThemeColor) return accent;

    // 关闭的是自定义/动态主题色，不是操作与选中态的颜色。强调色回退到
    // 应用默认配色；只让表面、正文与描边保持中性，避免整站（含节点编辑器）
    // 被 monochrome 一起去色。保留成对的 on* 与 fixed 色，确保控件对比度。
    final neutral = ColorScheme.fromSeed(
      seedColor: const Color(0xFF777777),
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    );
    return neutral.copyWith(
      primary: accent.primary,
      onPrimary: accent.onPrimary,
      primaryContainer: accent.primaryContainer,
      onPrimaryContainer: accent.onPrimaryContainer,
      primaryFixed: accent.primaryFixed,
      primaryFixedDim: accent.primaryFixedDim,
      onPrimaryFixed: accent.onPrimaryFixed,
      onPrimaryFixedVariant: accent.onPrimaryFixedVariant,
      secondary: accent.secondary,
      onSecondary: accent.onSecondary,
      secondaryContainer: accent.secondaryContainer,
      onSecondaryContainer: accent.onSecondaryContainer,
      secondaryFixed: accent.secondaryFixed,
      secondaryFixedDim: accent.secondaryFixedDim,
      onSecondaryFixed: accent.onSecondaryFixed,
      onSecondaryFixedVariant: accent.onSecondaryFixedVariant,
      tertiary: accent.tertiary,
      onTertiary: accent.onTertiary,
      tertiaryContainer: accent.tertiaryContainer,
      onTertiaryContainer: accent.onTertiaryContainer,
      tertiaryFixed: accent.tertiaryFixed,
      tertiaryFixedDim: accent.tertiaryFixedDim,
      onTertiaryFixed: accent.onTertiaryFixed,
      onTertiaryFixedVariant: accent.onTertiaryFixedVariant,
      inversePrimary: accent.inversePrimary,
    );
  }

  static ThemeData _build(
    ColorScheme scheme,
    String fontFamily,
    double fontSize,
    int fontWeight, {
    bool predictiveBack = true,
    String glassEffect = 'liquid',
  }) {
    final isDark = scheme.brightness == Brightness.dark;
    // 字号缩放统一交给 app.dart 里的 MediaQuery.textScaler（TextScaler.linear(fontSize/14)），
    // 这里不能再 `sz * scale`，否则字号会被乘两次（默认 17 号会渲染成约 20.6px）。
    final w = _fw(fontWeight);
    final base = ThemeData.fallback().textTheme;
    TextStyle s(TextStyle? b, double sz) => (b ?? const TextStyle()).copyWith(
      fontSize: sz,
      fontWeight: w,
      height: 1.45,
      color: scheme.onSurface,
    );

    final tt = base.copyWith(
      displayLarge: s(base.displayLarge, 57),
      displayMedium: s(base.displayMedium, 45),
      displaySmall: s(base.displaySmall, 36),
      headlineLarge: s(base.headlineLarge, 32),
      headlineMedium: s(base.headlineMedium, 28),
      headlineSmall: s(base.headlineSmall, 24),
      titleLarge: s(base.titleLarge, 22),
      titleMedium: s(base.titleMedium, 16),
      titleSmall: s(base.titleSmall, 14),
      bodyLarge: s(base.bodyLarge, 16),
      bodyMedium: s(base.bodyMedium, 14),
      bodySmall: s(base.bodySmall, 12),
      labelLarge: s(base.labelLarge, 14),
      labelMedium: s(base.labelMedium, 12),
      labelSmall: s(base.labelSmall, 11),
    );

    final fallback = Platform.isWindows
        ? const ['Microsoft YaHei', 'SimHei', 'SimSun', 'KaiTi', 'sans-serif']
        : Platform.isMacOS
        ? const [
            'PingFang SC',
            'Hiragino Sans GB',
            'SF Pro Text',
            'Menlo',
            'sans-serif',
          ]
        : const [
            'Noto Sans CJK SC',
            'WenQuanYi Micro Hei',
            'DejaVu Sans',
            'sans-serif',
          ];

    final appliedTt =
        fontFamily.isNotEmpty &&
            !fontFamily.contains('\\') &&
            !fontFamily.contains('/')
        ? tt.apply(fontFamily: fontFamily, fontFamilyFallback: fallback)
        : tt.apply(fontFamilyFallback: fallback);

    // Shared modal roles: charcoal translucent glass, a quiet rim, and paired
    // action pills. The dark glass must stay strictly neutral (R == G == B):
    // the earlier warm charcoal (0x35322C) and tan rim (0x81755B) read as a
    // yellow cast once the blurred backdrop showed through the surface.
    final modalSurface = glassEffect == 'none'
        ? scheme.surfaceContainerHigh
        : isDark
        ? AppNeutralSurface.darkCardHigh.withAlpha(235)
        : scheme.surfaceContainerHigh.withAlpha(246);
    // 选择器确认按钮的「主题色克制着色」（与对话框主行动同源）。
    final pickerAccent = AppAccentSurface.fromScheme(scheme);
    const modalRadius = Radius.circular(28);
    final dialogShape = RoundedRectangleBorder(
      borderRadius: const BorderRadius.all(modalRadius),
      side: BorderSide(
        color: isDark
            ? Colors.white.withAlpha(36)
            : scheme.outlineVariant.withAlpha(145),
        width: 0.8,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // The context-aware AppPressTheme wrapper adds reduced-motion/high-contrast
      // variants; this OS-aware base also covers isolated widgets and previews.
      splashFactory: AppPressFeedback.splashFactory,
      splashColor: AppPressFeedback.splashColor(scheme),
      highlightColor: Colors.transparent,
      hoverColor: scheme.onSurface.withValues(alpha: 0.045),
      focusColor: scheme.primary.withValues(alpha: 0.14),
      // 转场：Android 用自写的位移式转场（见 theme/app_page_transitions.dart）。
      //
      // 之前用 framework 的 PredictiveBackPageTransitionsBuilder，它非手势时委托
      // FadeForwards：旧页上垫一层 ColoredBox(ColorScheme.surface)、旧页前 25% 就
      // 淡出、新页 75% 才淡入 —— 深色下前 ~112ms 只剩一块 surface 实色，就是
      // 「进入二级页先黑一下」。Zoom 更糟（scrim 是硬编码纯黑）。
      //
      // 「玻璃变黑」的另一个历史根因是快照：Zoom 默认 allowSnapshotting=true 会把
      // 进入的路由光栅化，采不到 BackdropFilter 的 backdrop。本仓库已在路由层统一
      // 关快照（smoothRoute 与各 MaterialPageRoute 都传 allowSnapshotting: false），
      // 与本次转场改动互不影响。
      pageTransitionsTheme: PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: AppPageTransitionsBuilder(
            predictiveBack: predictiveBack,
          ),
          TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: const ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: const ZoomPageTransitionsBuilder(),
        },
      ),
      fontFamilyFallback: fallback,
      textTheme: appliedTt,
      // Material controls can resolve primaryTextTheme instead of textTheme.
      primaryTextTheme: appliedTt,
      fontFamily:
          fontFamily.isNotEmpty &&
              !fontFamily.contains('/') &&
              !fontFamily.contains('\\')
          ? fontFamily
          : null,
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        side: BorderSide(color: scheme.outline, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? scheme.onSurface.withAlpha(90)
              : states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.outline,
        ),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outlineVariant,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          overlayColor: AppPressFeedback.overlayColor(scheme),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        horizontalTitleGap: 12,
        minVerticalPadding: 10,
        titleTextStyle: appliedTt.bodyMedium,
        subtitleTextStyle: appliedTt.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      scaffoldBackgroundColor: AppNeutralSurface.background(scheme.brightness),
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
        hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        floatingLabelStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w500,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withAlpha(160),
            width: 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        isDense: true,
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(overlayColor: AppPressFeedback.overlayColor(scheme)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(overlayColor: AppPressFeedback.overlayColor(scheme)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ).copyWith(overlayColor: AppPressFeedback.overlayColor(scheme)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ).copyWith(overlayColor: AppPressFeedback.overlayColor(scheme)),
      ),
      // 必须和 filledButtonTheme 保持同样的圆角/内边距：否则 OutlinedButton 会退回
      // Material 3 默认值（胶囊形 + 更小的内边距），和旁边的 FilledButton 并排时
      // 高度和圆角都对不上（例如「容器」与「添加文件」）。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(160)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ).copyWith(overlayColor: AppPressFeedback.overlayColor(scheme)),
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
        // 关掉 M3 进度条末端的实心圆点（用户要求进度条上不能出现圆）：
        // 只改 stopIndicatorColor 无效，framework 会回退到 primary；必须把半径设为 0。
        stopIndicatorRadius: 0,
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
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.outlineVariant, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: scheme.outlineVariant.withAlpha(160),
              width: 1,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.primary, width: 1.5),
          ),
        ),
        // 下拉/菜单统一外观：与 OptionMenuBar / AppDropdown 的浮层同款
        // （圆角 14、elevation 10、surface 背景），避免系统 DropdownMenu 与
        // 自定义面板出现两种圆角/阴影。
        menuStyle: MenuStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
            ),
          ),
          surfaceTintColor: WidgetStatePropertyAll(scheme.surface),
          elevation: const WidgetStatePropertyAll(10),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 8),
          ),
          // 与 OptionMenuBar / AppDropdown 的浮层同色：统一用 surface，
          // 不再混用 surfaceContainerHighest（深色下会偏亮、和自定义面板不一致）。
          backgroundColor: WidgetStatePropertyAll(scheme.surface),
          shadowColor: WidgetStatePropertyAll(
            Colors.black.withAlpha(isDark ? 80 : 30),
          ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 10,
      ),
      // Shared modal surfaces follow the app's rounded panels. Theme-only
      // styling preserves route focus, semantics, motion, and per-dialog sizing.
      dialogTheme: DialogThemeData(
        backgroundColor: modalSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withAlpha(isDark ? 90 : 35),
        elevation: 8,
        // Shared by Material dialogs and custom modal panels.
        shape: dialogShape,
        // Explicit Dialog.constraints can opt wider for dedicated desktop editors.
        constraints: const BoxConstraints(maxWidth: 560),
        titleTextStyle: appliedTt.titleMedium?.copyWith(
          fontSize: 18,
          fontWeight: w.value < FontWeight.w600.value ? FontWeight.w600 : w,
        ),
        contentTextStyle: appliedTt.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
        // A 320dp viewport still has room for the standard 280dp dialog.
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: modalSurface,
        surfaceTintColor: Colors.transparent,
        shape: dialogShape,
        headerBackgroundColor: modalSurface,
        headerForegroundColor: scheme.onSurface,
        dayForegroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.onPrimary : null,
        ),
        dayBackgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.primary : null,
        ),
        todayForegroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.onPrimary : null,
        ),
        todayBackgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? scheme.primary : null,
        ),
        todayBorder: BorderSide(color: scheme.primary),
        cancelButtonStyle: TextButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        // 确认按钮与对话框主行动同一套「主题色克制着色」：
        // 不再铺满 scheme.primary（琥珀/亮黄主题下会变成无边框荧光板砖）。
        confirmButtonStyle: TextButton.styleFrom(
          backgroundColor: pickerAccent.fill,
          foregroundColor: pickerAccent.foreground,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: pickerAccent.border),
          ),
        ),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: modalSurface,
        shape: dialogShape,
        dialHandColor: scheme.primary,
        entryModeIconColor: scheme.primary,
        dayPeriodColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : Colors.transparent,
        ),
        dialTextColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurface,
        ),
        dayPeriodTextColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurfaceVariant,
        ),
        hourMinuteColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        hourMinuteTextColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurface,
        ),
        cancelButtonStyle: TextButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        confirmButtonStyle: TextButton.styleFrom(
          backgroundColor: pickerAccent.fill,
          foregroundColor: pickerAccent.foreground,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: pickerAccent.border),
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        // Modal sheets inherit this color so MobileVisualTheme can replace it.
        backgroundColor: modalSurface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: modalRadius),
        ),
        // Keep handle visibility opt-in; custom sheets already draw their own.
        dragHandleColor: scheme.onSurfaceVariant,
        dragHandleSize: const Size(36, 4),
      ),
      // 语义色（成功/警告/危险/信息/中性）：见 theme/app_semantic_colors.dart。
      // 注入到主题层后，所有 `scheme.sem.xxx` 与
      // `Theme.of(context).extension<AppSemantic>()` 都拿到同一份实例，
      // 其内部按完整 ColorScheme 做进程级缓存，主题未变时直接复用。
      extensions: <ThemeExtension<dynamic>>[AppSemantic.ofScheme(scheme)],
    );
  }

  static FontWeight _fw(int w) {
    const m = {
      100: FontWeight.w100,
      200: FontWeight.w200,
      300: FontWeight.w300,
      400: FontWeight.w400,
      500: FontWeight.w500,
      600: FontWeight.w600,
      700: FontWeight.w700,
      800: FontWeight.w800,
      900: FontWeight.w900,
    };
    return m[w] ?? FontWeight.w400;
  }
}
