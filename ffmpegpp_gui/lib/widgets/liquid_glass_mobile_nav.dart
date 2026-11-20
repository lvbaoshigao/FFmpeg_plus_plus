import 'package:flutter/material.dart';
import 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_strings.dart';
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

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final indicatorStyle = context.select<AppState?, String>(
      (state) => state?.config.selectionIndicatorStyle ?? 'theme',
    );
    // The hosted package exposes layout and item colors, but no indicator
    // builder. Retain its original refracting droplet only for liquid mode.
    if (indicatorStyle == 'liquid' &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.highContrastOf(context)) {
      return LiquidGlassTabBar(
        currentIndex: currentIndex,
        onTap: onTap,
        onTapIntercept: onTapIntercept,
        selectedColor: selectedColor ?? theme.colorScheme.primary,
        unselectedColor: unselectedColor ?? theme.colorScheme.onSurfaceVariant,
        style: style,
        items: items,
      );
    }
    return _StyledAppTabBar(bar: this, indicatorStyle: indicatorStyle);
  }
}

/// Keeps the hosted tab geometry while the shared indicator owns its material.
///
/// The fallback supports tap, drag-release, long press, keyboard activation,
/// and interception. Liquid-only droplet deformation stays in the hosted bar.
class _StyledAppTabBar extends StatefulWidget {
  const _StyledAppTabBar({required this.bar, required this.indicatorStyle});

  final AppLiquidTabBar bar;
  final String indicatorStyle;

  @override
  State<_StyledAppTabBar> createState() => _StyledAppTabBarState();
}

class _StyledAppTabBarState extends State<_StyledAppTabBar> {
  double? _dragSlot;
  int? _focused;

  void _activate(int index) {
    final bar = widget.bar;
    final intercepted = bar.onTapIntercept?.call(index) ?? false;
    if (mounted) {
      setState(() => _dragSlot = null);
    }
    if (!intercepted) {
      bar.onTap(index);
    }
  }

  void _finishDrag() {
    final slot = _dragSlot;
    if (slot != null) {
      _activate(slot.round());
    }
  }

  void _cancelDrag() => setState(() => _dragSlot = null);

  @override
  Widget build(BuildContext context) {
    final bar = widget.bar;
    final style = bar.style;
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
      6,
      style.horizontalMargin,
      MediaQuery.paddingOf(context).bottom +
          LiquidGlassTabBar.bottomGapOf(context, style),
    );
    final radius = style.barHeight / 2;
    final track = DecoratedBox(
      decoration: BoxDecoration(
        color: look?.style == 'liquid'
            ? Colors.transparent
            : look?.tint ?? scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
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
              final reducedMotion = MediaQuery.disableAnimationsOf(context);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onHorizontalDragStart: (_) =>
                    setState(() => _dragSlot = bar.currentIndex.toDouble()),
                onHorizontalDragUpdate: (details) => setState(() {
                  _dragSlot =
                      ((_dragSlot ?? bar.currentIndex.toDouble()) +
                              (details.primaryDelta ?? 0) / slotWidth)
                          .clamp(0.0, bar.items.length - 1.0);
                }),
                onHorizontalDragEnd: (_) => _finishDrag(),
                onHorizontalDragCancel: _cancelDrag,
                onLongPressStart: (details) => setState(() {
                  _dragSlot = (details.localPosition.dx / slotWidth - 0.5)
                      .clamp(0.0, bar.items.length - 1.0);
                }),
                onLongPressMoveUpdate: (details) => setState(() {
                  _dragSlot = (details.localPosition.dx / slotWidth - 0.5)
                      .clamp(0.0, bar.items.length - 1.0);
                }),
                onLongPressEnd: (_) => _finishDrag(),
                onLongPressCancel: _cancelDrag,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: _dragSlot ?? bar.currentIndex.toDouble()),
                  duration: reducedMotion || _dragSlot != null
                      ? Duration.zero
                      : const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  builder: (context, position, _) {
                    final rect = Rect.fromLTWH(
                      position * slotWidth - style.capsuleOverhang,
                      0,
                      slotWidth + style.capsuleOverhang * 2,
                      style.capsuleHeight,
                    );
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fromRect(
                          rect: rect,
                          child: SelectionHighlight(
                            key: const ValueKey('app-tab-selection'),
                            radius: style.capsuleHeight / 2,
                            style: widget.indicatorStyle,
                          ),
                        ),
                        Row(
                          children: [
                            for (
                              var index = 0;
                              index < bar.items.length;
                              index++
                            )
                              Expanded(child: _interactiveItem(context, index)),
                          ],
                        ),
                        // As in the hosted bar, keep color changes aligned with
                        // the moving capsule and expose only one semantics row.
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ExcludeSemantics(
                              child: ClipPath(
                                clipper: _TabSelectionClipper(rect),
                                child: Row(
                                  children: [
                                    for (
                                      var index = 0;
                                      index < bar.items.length;
                                      index++
                                    )
                                      Expanded(
                                        child: _itemContent(
                                          context,
                                          index,
                                          true,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
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

  Widget _interactiveItem(BuildContext context, int index) {
    final bar = widget.bar;
    final item = bar.items[index];
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey('app-tab-$index'),
      container: true,
      button: true,
      selected: index == bar.currentIndex,
      label: item.semanticLabel ?? item.label,
      onTap: () => _activate(index),
      excludeSemantics: true,
      child: FocusableActionDetector(
        onShowFocusHighlight: (show) =>
            setState(() => _focused = show ? index : null),
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
        child: InkWell(
          onTap: () => _activate(index),
          canRequestFocus: false,
          excludeFromSemantics: true,
          borderRadius: BorderRadius.circular(bar.style.capsuleHeight / 2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(bar.style.capsuleHeight / 2),
              border: _focused == index
                  ? Border.all(color: scheme.onSurface, width: 2)
                  : null,
            ),
            child: _itemContent(context, index, false),
          ),
        ),
      ),
    );
  }

  Widget _itemContent(BuildContext context, int index, bool selected) {
    final bar = widget.bar;
    final item = bar.items[index];
    final scheme = Theme.of(context).colorScheme;
    final highContrast = MediaQuery.highContrastOf(context);
    final color = selected
        ? bar.selectedColor ??
              (highContrast ? scheme.onSurface : scheme.primary)
        : bar.unselectedColor ?? scheme.onSurfaceVariant;
    final icon =
        item.iconBuilder?.call(color) ??
        IconTheme.merge(
          data: IconThemeData(color: color, size: bar.style.iconSize),
          child: item.icon!,
        );
    return SizedBox(
      height: bar.style.capsuleHeight,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: item.label == null
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
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ).merge(bar.style.labelStyle).copyWith(color: color),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
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

/// 主界面与子页面共用的底栏尺寸：与历史主界面底部导航逐像素一致。
const LiquidGlassTabBarStyle kAppLiquidTabBarStyle = LiquidGlassTabBarStyle(
  capsuleHeight: 52,
  capsuleInset: 4,
  horizontalMargin: 24,
  bottomGap: 8,
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
    if (navStyle == 'liquid') {
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
      bar = NavGlassShell(
        pal: pal,
        radius: 26,
        keyPrefix: 'bottomNav',
        child: _FlatNavBar(
          selectedIndex: index < 0 ? 0 : index,
          onTap: (tabIndex) => onSelected(_pageOrder[tabIndex]),
          items: items,
        ),
      );
    }

    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedSlide(
        offset: hidden ? const Offset(0, 1.2) : Offset.zero,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        curve: Curves.easeInOutCubic,
        child: bar,
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
