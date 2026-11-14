import 'package:flutter/material.dart';
import 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import 'mobile_bottom_nav.dart' show NavGlassShell, navGlassPalOf;

// 子页面（配置库等）只 import 本文件即可拿到统一的底栏样式与条目类型，
// 不必各自直接依赖 liquid_glass_tab_bar。
export 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart'
    show LiquidGlassTabItem, LiquidGlassTabBarStyle;

/// 全应用统一的底部液态玻璃菜单栏外观。
///
/// 主界面底部导航（[LiquidGlassMobileNav]）与各子页面底部的胶囊切换栏
/// （如 AI 提供商详情页的「基本 / 模型」）都走这一份样式：
/// capsuleHeight 52 / inset 4 / 左右边距 14 / 底部 8 / 图标 22。
///
/// 抽成公共 widget 的原因（用户要求）：主界面已经用了 liquid_glass_tab_bar
/// 模块，其余带底部菜单栏的界面必须用**同一个模块、同一套尺寸与材质**，
/// 不允许再各写一套自绘玻璃底栏。子页面只需给出 items / 选中项 / 回调。
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
  });

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
    final theme = Theme.of(context);
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
          LiquidGlassTabItem(
            icon: const Icon(Icons.movie_outlined),
            label: strings.navProjects,
          ),
          LiquidGlassTabItem(
            icon: const Icon(Icons.list_alt_outlined),
            label: strings.navQueue,
          ),
          LiquidGlassTabItem(
            icon: const Icon(Icons.folder_copy_outlined),
            label: language == 'zh' ? '配置库' : 'Configs',
          ),
          LiquidGlassTabItem(
            icon: const Icon(Icons.settings_outlined),
            label: strings.navSettings,
          ),
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
          labels: [
            strings.navProjects,
            strings.navQueue,
            language == 'zh' ? '配置库' : 'Configs',
            strings.navSettings,
          ],
          icons: const [
            Icons.movie_outlined,
            Icons.list_alt_outlined,
            Icons.folder_copy_outlined,
            Icons.settings_outlined,
          ],
        ),
      );
    }

    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedSlide(
        offset: hidden ? const Offset(0, 1.2) : Offset.zero,
        duration: const Duration(milliseconds: 240),
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
    required this.labels,
    required this.icons,
  });

  final int selectedIndex;
  final ValueChanged<int> onTap;
  final List<String> labels;
  final List<IconData> icons;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          for (var i = 0; i < icons.length; i++)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(26),
                onTap: () => onTap(i),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icons[i],
                      size: 22,
                      color: i == selectedIndex
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 10,
                        color: i == selectedIndex
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
