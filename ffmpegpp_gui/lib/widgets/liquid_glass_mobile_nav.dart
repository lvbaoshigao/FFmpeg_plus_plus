import 'package:flutter/material.dart';
import 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart';
import 'package:provider/provider.dart';

import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../theme/mobile_ui.dart';
import 'liquid_glass_fallback.dart';
import 'mobile_bottom_nav.dart' show NavGlassShell, navGlassPalOf, navGlassLook;
import 'selection_highlight.dart';
import 'tabler_icon.dart';

// 子页面（配置库等）只 import 本文件即可拿到统一的底栏样式与条目类型，
// 不必各自直接依赖 liquid_glass_tab_bar。
export 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart'
    show LiquidGlassTabItem, LiquidGlassTabBarStyle;

/// 全应用统一的底部液态玻璃菜单栏外观。
///
/// 主界面底部导航（[LiquidGlassMobileNav]）与各子页面底部的胶囊切换栏
/// （如 AI 提供商详情页的「基本 / 模型」）都走这一份样式：
/// capsuleHeight 52 / inset 4 / 左右边距 24 / 底部 8 / 图标 22。
///
/// 所有页面共享公开条目与几何配置。液态遮罩使用 hosted TabBar，其余遮罩
/// 在本包装器中复用导航玻璃外壳，避免各页面重复实现。
class AppLiquidTabBar extends StatelessWidget {
  const AppLiquidTabBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.onTapIntercept,
    this.selectedColor,
    this.unselectedColor,
    this.style = kAppLiquidTabBarStyle,
  }) : assert(items.length >= 2, 'A tab bar needs at least two items.'),
       assert(currentIndex >= 0 && currentIndex < items.length);

  final List<LiquidGlassTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// 返回 true 表示该次点击由调用方自行处理（如「动作」项），选中态不变。
  final bool Function(int index)? onTapIntercept;

  final Color? selectedColor;
  final Color? unselectedColor;
  final LiquidGlassTabBarStyle style;

  /// Shared geometry for parents that must reserve space for a floating bar.
  static LiquidGlassTabBarStyle resolveStyle(
    BuildContext context,
    LiquidGlassTabBarStyle style,
  ) => _tabStyleOf(context, style);

  /// Height of this bar's painted host after the caller removes bottom safe
  /// area padding. The value includes the top droplet/shadow room and the
  /// configured bottom gap, and follows the active text scaler.
  static double heightOf(
    BuildContext context, [
    LiquidGlassTabBarStyle style = kAppLiquidTabBarStyle,
  ]) {
    final effective = _tabStyleOf(context, style);
    return effective.barHeight +
        _tabBarTopPadding +
        LiquidGlassTabBar.bottomGapOf(context, effective);
  }

  /// Total clearance needed below scrollable content, including the safe area.
  static double clearanceOf(
    BuildContext context, [
    LiquidGlassTabBarStyle style = kAppLiquidTabBarStyle,
  ]) => MediaQuery.paddingOf(context).bottom + heightOf(context, style);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final indicatorStyle = context.select<AppState?, String>(
      (state) => state?.config.selectionIndicatorStyle ?? 'theme',
    );
    final effectiveStyle = _tabStyleOf(context, style);
    // Mobile uses one backdrop and one content row for every indicator style.
    if (!isMobilePlatform &&
        indicatorStyle == 'liquid' &&
        MediaQuery.textScalerOf(context).scale(10.5) <= 12 &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.highContrastOf(context)) {
      return _FloatingTabBarFrame(
        horizontalMargin: style.horizontalMargin,
        child: LiquidGlassTabBar(
          currentIndex: currentIndex,
          onTap: onTap,
          onTapIntercept: onTapIntercept,
          selectedColor: selectedColor ?? theme.colorScheme.primary,
          unselectedColor:
              unselectedColor ?? theme.colorScheme.onSurfaceVariant,
          style: effectiveStyle,
          items: items,
        ),
      );
    }
    return _FloatingTabBarFrame(
      horizontalMargin: style.horizontalMargin,
      child: _StyledAppTabBar(bar: this, indicatorStyle: indicatorStyle),
    );
  }
}

/// Restricts the painted surface, while keeping margins transparent and tappable
/// content clear of landscape cutouts.
class _FloatingTabBarFrame extends StatelessWidget {
  const _FloatingTabBarFrame({
    required this.horizontalMargin,
    required this.child,
  });

  final double horizontalMargin;
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    bottom: false,
    child: Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MobileUi.navMaxWidth + horizontalMargin * 2,
        ),
        child: child,
      ),
    ),
  );
}

const double _tabBarTopPadding = 6;

LiquidGlassTabBarStyle _tabStyleOf(
  BuildContext context,
  LiquidGlassTabBarStyle style,
) {
  final labelSize = style.labelStyle?.fontSize ?? 10.5;
  final labelHeight =
      MediaQuery.textScalerOf(context).scale(labelSize) *
      (style.labelStyle?.height ?? 1.2);
  final contentHeight = style.iconSize + 6 + labelHeight + 8;
  final mobileCapsuleHeight = contentHeight.clamp(
    isMobilePlatform && style.capsuleHeight < 48 ? 48.0 : style.capsuleHeight,
    double.infinity,
  );
  return LiquidGlassTabBarStyle(
    capsuleHeight: isMobilePlatform ? mobileCapsuleHeight : style.capsuleHeight,
    capsuleInset: style.capsuleInset,
    capsuleOverhang: style.capsuleOverhang,
    horizontalMargin: style.horizontalMargin,
    bottomGap: style.bottomGap,
    iconSize: style.iconSize,
    labelStyle: style.labelStyle,
  );
}

/// Keeps the shared tab geometry and supports taps, drags, long presses,
/// keyboard activation, and action interception.
class _StyledAppTabBar extends StatefulWidget {
  const _StyledAppTabBar({required this.bar, required this.indicatorStyle});

  final AppLiquidTabBar bar;
  final String indicatorStyle;

  @override
  State<_StyledAppTabBar> createState() => _StyledAppTabBarState();
}

class _StyledAppTabBarState extends State<_StyledAppTabBar> {
  final ValueNotifier<double?> _dragPosition = ValueNotifier(null);
  int? _focused;

  void _activate(int index) {
    final bar = widget.bar;
    final intercepted = bar.onTapIntercept?.call(index) ?? false;
    _dragPosition.value = null;
    if (!intercepted) bar.onTap(index);
  }

  void _finishDrag() {
    final slot = _dragPosition.value;
    if (slot != null) _activate(slot.round());
  }

  void _cancelDrag() => _dragPosition.value = null;

  @override
  void dispose() {
    _dragPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bar = widget.bar;
    final style = _tabStyleOf(context, bar.style);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasAppState = context.select<AppState?, bool>(
      (state) => state != null,
    );
    final pal = hasAppState ? navGlassPalOf(context) : null;
    final look = pal == null
        ? null
        : navGlassLook(scheme, theme.brightness == Brightness.dark, pal);
    final margins = EdgeInsets.fromLTRB(
      style.horizontalMargin,
      _tabBarTopPadding,
      style.horizontalMargin,
      MediaQuery.paddingOf(context).bottom +
          LiquidGlassTabBar.bottomGapOf(context, style),
    );
    final radius = style.barHeight / 2;
    final mobile = isMobilePlatform;
    final neutralTrack = mobile && widget.indicatorStyle == 'liquid';
    final trackTint = look?.tint ?? scheme.surfaceContainerHigh;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final track = DecoratedBox(
      decoration: BoxDecoration(
        color: mobile && pal == null || look?.style == 'liquid'
            ? Colors.transparent
            : neutralTrack
            ? neutralGray(trackTint)
            : trackTint,
        borderRadius: BorderRadius.circular(radius),
        border: mobile && (look?.solid ?? false)
            ? Border.all(color: scheme.onSurface.withValues(alpha: 0.16))
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: style.capsuleInset + style.capsuleOverhang,
          vertical: style.capsuleInset,
        ),
        child: SizedBox(
          height: style.capsuleHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slotWidth = constraints.maxWidth / bar.items.length;
              if (slotWidth <= 0) return const SizedBox.shrink();
              final reducedMotion = MediaQuery.disableAnimationsOf(context);
              final lastSlot = bar.items.length - 1.0;
              double positionFor(double dx) {
                final slot = dx / slotWidth - 0.5;
                return (rtl ? lastSlot - slot : slot).clamp(0.0, lastSlot);
              }

              final staticRows = _StaticTabRows(
                normal: Row(
                  children: [
                    for (var index = 0; index < bar.items.length; index++)
                      Expanded(child: _interactiveItem(context, index, style)),
                  ],
                ),
                selected: mobile
                    ? null
                    : Row(
                        children: [
                          for (var index = 0; index < bar.items.length; index++)
                            Expanded(
                              child: _itemContent(context, index, true, style),
                            ),
                        ],
                      ),
              );
              Rect selectionRect(double position) {
                final x = (rtl ? lastSlot - position : position) * slotWidth;
                // Leave breathing room around the inset and keep the entire
                // slot available to touch and keyboard users.
                return mobile
                    ? Rect.fromLTWH(
                        x + 3,
                        2,
                        (slotWidth - 6).clamp(0.0, slotWidth),
                        style.capsuleHeight - 4,
                      )
                    : Rect.fromLTWH(
                        x - style.capsuleOverhang,
                        0,
                        slotWidth + style.capsuleOverhang * 2,
                        style.capsuleHeight,
                      );
              }

              return GestureDetector(
                key: const ValueKey('app-tab-drag-surface'),
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onHorizontalDragStart: (_) {
                  _dragPosition.value = bar.currentIndex.toDouble();
                },
                onHorizontalDragUpdate: (details) {
                  _dragPosition.value =
                      ((_dragPosition.value ?? bar.currentIndex.toDouble()) +
                              (details.primaryDelta ?? 0) /
                                  slotWidth *
                                  (rtl ? -1 : 1))
                          .clamp(0.0, bar.items.length - 1.0);
                },
                onHorizontalDragEnd: (_) => _finishDrag(),
                onHorizontalDragCancel: _cancelDrag,
                onLongPressStart: (details) {
                  _dragPosition.value = positionFor(details.localPosition.dx);
                },
                onLongPressMoveUpdate: (details) {
                  _dragPosition.value = positionFor(details.localPosition.dx);
                },
                onLongPressEnd: (_) => _finishDrag(),
                onLongPressCancel: _cancelDrag,
                child: ValueListenableBuilder<double?>(
                  valueListenable: _dragPosition,
                  child: staticRows,
                  builder: (context, dragPosition, rows) =>
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                          end: dragPosition ?? bar.currentIndex.toDouble(),
                        ),
                        // 松手后约 420ms 弹性归位（轻微越过再落定）。
                        duration: reducedMotion || dragPosition != null
                            ? Duration.zero
                            : Duration(milliseconds: mobile ? 420 : 240),
                        curve: mobile
                            ? const Cubic(0.34, 1.26, 0.64, 1)
                            : Curves.easeOutCubic,
                        child: rows,
                        builder: (context, position, staticRows) {
                          final rows = staticRows! as _StaticTabRows;
                          final raw = reducedMotion
                              ? dragPosition ?? bar.currentIndex.toDouble()
                              : position;
                          // 移动端弹性曲线会越过终点：限制在首尾 tab 之间。
                          final rect = selectionRect(
                            mobile ? raw.clamp(0.0, lastSlot.toDouble()) : raw,
                          );
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fromRect(
                                rect: rect,
                                child: mobile
                                    // 拖动时选中片轻微横向拉伸，松开约 420ms 回弹。
                                    ? TweenAnimationBuilder<double>(
                                        tween: Tween<double>(
                                          end: dragPosition != null &&
                                                  !reducedMotion
                                              ? 1.06
                                              : 1.0,
                                        ),
                                        duration: Duration(
                                          milliseconds: dragPosition != null
                                              ? 110
                                              : 420,
                                        ),
                                        curve: dragPosition != null
                                            ? Curves.easeOutCubic
                                            : Curves.easeOutBack,
                                        child: MobileGlassSelection(
                                          key: const ValueKey(
                                            'app-tab-selection',
                                          ),
                                          radius: rect.height / 2,
                                          style: widget.indicatorStyle,
                                        ),
                                        builder: (context, stretch, child) =>
                                            Transform(
                                              alignment: Alignment.center,
                                              transform: Matrix4.diagonal3Values(
                                                stretch,
                                                1,
                                                1,
                                              ),
                                              child: child,
                                            ),
                                      )
                                    : SelectionHighlight(
                                        key: const ValueKey(
                                          'app-tab-selection',
                                        ),
                                        radius: style.capsuleHeight / 2,
                                        style: widget.indicatorStyle,
                                      ),
                              ),
                              rows.normal,
                              if (rows.selected != null)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: ExcludeSemantics(
                                      child: ClipPath(
                                        clipper: _TabSelectionClipper(rect),
                                        child: rows.selected,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                ),
              );
            },
          ),
        ),
      ),
    );

    if (mobile) {
      final shape = BorderRadius.circular(radius);
      // Own the mobile material here so track, selection and configurable
      // outline cannot acquire a second glass shell from a hosted nav wrapper.
      Widget surface = look?.solid ?? false
          ? track
          : MobileGlassSurface(
              borderRadius: shape,
              tuning: pal?.tuning ?? const GlassTuning(),
              opacity: pal?.op ?? 0.7,
              liquid: look?.style != 'blur',
              accent:
                  !neutralTrack &&
                      pal != null &&
                      pal.follow &&
                      pal.useThemeColor
                  ? themedGlassBase(scheme, pal.tone, true, second: pal.second)
                  : null,
              child: track,
            );
      if (hasAppState) {
        surface = withConfigurableBorder(context, surface, radius: shape);
      }
      return Padding(padding: margins, child: surface);
    }
    return pal == null
        ? Padding(padding: margins, child: track)
        : NavGlassShell(
            pal: pal,
            radius: radius,
            padding: margins,
            keyPrefix: 'styledAppTabBar',
            child: track,
          );
  }

  void _handleFocusHighlight(int index, bool show) {
    final next = show ? index : (_focused == index ? null : _focused);
    if (_focused == next) return;
    setState(() => _focused = next);
  }

  Widget _interactiveItem(
    BuildContext context,
    int index,
    LiquidGlassTabBarStyle style,
  ) {
    final bar = widget.bar;
    final item = bar.items[index];
    final scheme = Theme.of(context).colorScheme;
    final mobile = isMobilePlatform;
    final itemShape = BorderRadius.circular(style.capsuleHeight / 2);
    final face = InkWell(
      onTap: () => _activate(index),
      canRequestFocus: false,
      excludeFromSemantics: true,
      borderRadius: itemShape,
      splashFactory: mobile ? NoSplash.splashFactory : null,
      overlayColor: mobile
          ? WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return scheme.onSurface.withValues(alpha: 0.08);
              }
              if (states.contains(WidgetState.hovered)) {
                return scheme.onSurface.withValues(alpha: 0.05);
              }
              return null;
            })
          : null,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: itemShape,
          border: _focused == index
              ? Border.all(color: scheme.onSurface, width: 2)
              : null,
        ),
        child: _itemContent(
          context,
          index,
          mobile && index == bar.currentIndex,
          style,
        ),
      ),
    );
    return Semantics(
      key: ValueKey('app-tab-$index'),
      container: true,
      button: true,
      selected: index == bar.currentIndex,
      label: item.semanticLabel ?? item.label,
      onTap: () => _activate(index),
      excludeSemantics: true,
      child: FocusableActionDetector(
        onShowFocusHighlight: (show) => _handleFocusHighlight(index, show),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate(index);
              return null;
            },
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) {
              _activate(index);
              return null;
            },
          ),
        },
        child: mobile
            ? Material(type: MaterialType.transparency, child: face)
            : face,
      ),
    );
  }

  Widget _itemContent(
    BuildContext context,
    int index,
    bool selected,
    LiquidGlassTabBarStyle style,
  ) {
    final bar = widget.bar;
    final item = bar.items[index];
    final scheme = Theme.of(context).colorScheme;
    final highContrast = MediaQuery.highContrastOf(context);
    final mobile = isMobilePlatform;
    final color = highContrast && mobile
        ? scheme.onSurface
        : selected
        ? bar.selectedColor ??
              (highContrast || mobile ? scheme.onSurface : scheme.primary)
        : bar.unselectedColor ??
              (mobile
                  ? Color.lerp(scheme.onSurface, scheme.onSurfaceVariant, 0.40)!
                  : scheme.onSurfaceVariant);
    final icon =
        item.iconBuilder?.call(color) ??
        IconTheme.merge(
          data: IconThemeData(color: color, size: bar.style.iconSize),
          child: item.icon!,
        );
    final content = item.label == null
        ? icon
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: bar.style.iconSize + 6,
                child: Center(child: icon),
              ),
              Text(
                item.label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.2,
                  fontWeight: mobile && selected
                      ? FontWeight.w700
                      : FontWeight.w500,
                ).merge(bar.style.labelStyle).copyWith(color: color),
              ),
            ],
          );
    final itemSurface = SizedBox(
      height: style.capsuleHeight,
      child: Center(
        child: mobile
            ? content
            : FittedBox(fit: BoxFit.scaleDown, child: content),
      ),
    );
    return mobile
        ? Tooltip(
            message: item.semanticLabel ?? item.label ?? '',
            triggerMode: TooltipTriggerMode.manual,
            child: itemSurface,
          )
        : itemSurface;
  }
}

class _StaticTabRows extends StatelessWidget {
  const _StaticTabRows({required this.normal, required this.selected});

  final Widget normal;
  final Widget? selected;

  @override
  Widget build(BuildContext context) => normal;
}

class _TabSelectionClipper extends CustomClipper<Path> {
  const _TabSelectionClipper(this.rect);

  final Rect rect;

  @override
  Path getClip(Size size) => Path()
    ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)));

  @override
  bool shouldReclip(covariant _TabSelectionClipper oldClipper) =>
      oldClipper.rect != rect;
}

/// 主界面与子页面共用的悬浮底栏尺寸；大字号会扩展内容高度。
const LiquidGlassTabBarStyle kAppLiquidTabBarStyle = LiquidGlassTabBarStyle(
  capsuleHeight: 52,
  capsuleInset: 4,
  horizontalMargin: MobileUi.navInsetH,
  bottomGap: MobileUi.navBottomGap,
  iconSize: 22,
);

class LiquidGlassMobileNav extends StatelessWidget {
  const LiquidGlassMobileNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.hidden = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool hidden;

  static const _pageOrder = [0, 1, 3, 4];

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppState, String>(
      (state) => state.config.language,
    );
    final strings = AppStrings.of(language);
    final index = _pageOrder.indexOf(selectedIndex);
    final items = <(TablerGlyph, String)>[
      (TablerGlyph.movie, strings.navProjects),
      (TablerGlyph.listDetails, strings.navQueue),
      (TablerGlyph.folders, language == 'zh' ? '配置库' : 'Configs'),
      (TablerGlyph.settings, strings.navSettings),
    ];

    // 菜单样式跟随设置（设置→外观→菜单样式）：liquid 走 AppLiquidTabBar，
    // theme/gray/blur 由 NavGlassShell 统一渲染（与侧边导轨同一套视觉语义）。
    final navStyle = context.select<AppState, String>(
      (state) => state.config.navStyle,
    );

    final Widget bar;
    if (isMobilePlatform || navStyle == 'liquid') {
      bar = AppLiquidTabBar(
        currentIndex: index < 0 ? 0 : index,
        onTap: (tabIndex) => onSelected(_pageOrder[tabIndex]),
        items: [
          for (final (glyph, label) in items)
            LiquidGlassTabItem(icon: TablerIcon(glyph), label: label),
        ],
      );
    } else {
      // theme / gray / blur：NavGlassShell 提供胶囊外壳与玻璃效果，
      // 内容为一行等宽图标（与 AppLiquidTabBar 相同的图标与标签）。
      final pal = navGlassPalOf(context);
      final look = navGlassLook(
        Theme.of(context).colorScheme,
        Theme.of(context).brightness == Brightness.dark,
        pal,
      );
      bar = _FloatingTabBarFrame(
        horizontalMargin: MobileUi.navInsetH,
        child: NavGlassShell(
          pal: pal,
          radius: 26,
          keyPrefix: 'bottomNav',
          padding: EdgeInsets.fromLTRB(
            MobileUi.navInsetH,
            6,
            MobileUi.navInsetH,
            MediaQuery.paddingOf(context).bottom + MobileUi.navBottomGap,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: look.tint,
              borderRadius: BorderRadius.circular(26),
            ),
            child: _FlatNavBar(
              selectedIndex: index < 0 ? 0 : index,
              onTap: (tabIndex) => onSelected(_pageOrder[tabIndex]),
              items: items,
            ),
          ),
        ),
      );
    }

    return ExcludeFocus(
      excluding: hidden,
      child: ExcludeSemantics(
        excluding: hidden,
        child: IgnorePointer(
          ignoring: hidden,
          child: AnimatedSlide(
            offset: hidden ? const Offset(0, 1.2) : Offset.zero,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 240),
            curve: Curves.easeInOutCubic,
            child: bar,
          ),
        ),
      ),
    );
  }
}

/// theme / gray / blur 样式下的扁平导航条内容：一行等宽图标 + 标签。
/// 外壳玻璃效果由 [NavGlassShell] 提供，这里只负责排布与点击。
class _FlatNavBar extends StatelessWidget {
  const _FlatNavBar({
    required this.selectedIndex,
    required this.onTap,
    required this.items,
  });

  final int selectedIndex;
  final ValueChanged<int> onTap;
  final List<(TablerGlyph, String)> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedColor = MediaQuery.highContrastOf(context)
        ? scheme.onSurface
        : scheme.primary;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: Semantics(
                key: ValueKey('flat-nav-item-$i'),
                button: true,
                selected: i == selectedIndex,
                label: items[i].$2,
                child: InkWell(
                  borderRadius: BorderRadius.circular(26),
                  onTap: () => onTap(i),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (i == selectedIndex)
                        const Positioned.fill(
                          left: 4,
                          top: 4,
                          right: 4,
                          bottom: 4,
                          child: SelectionHighlight(
                            key: ValueKey('flat-nav-selection'),
                            radius: 22,
                          ),
                        ),
                      ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TablerIcon(
                              items[i].$1,
                              size: 22,
                              color: i == selectedIndex
                                  ? selectedColor
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 2),
                            Flexible(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: Text(
                                  items[i].$2,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    height: 1,
                                    color: i == selectedIndex
                                        ? selectedColor
                                        : scheme.onSurfaceVariant,
                                    fontWeight: i == selectedIndex
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
