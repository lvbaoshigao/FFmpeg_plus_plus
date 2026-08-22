import 'package:flutter/material.dart';
import 'package:glass_liquid_navbar/glass_liquid_navbar.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

/// 移动端液态玻璃底部导航栏 —— 基于 glass_liquid_navbar 的 LiquidGlassNavbar。
///
/// 提供 iOS 26 风格液态玻璃：超通透背景、高模糊、镜面高光、胶囊指示器。
/// 完全遵循设置中的玻璃效果配置（liquid/blur/none）。
class MobileBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const MobileBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lang = context.watch<AppState>().config.language;
    final cfg = context.watch<AppState>().config;
    final s = AppStrings.of(lang);

    final items = <LiquidNavItem>[
      LiquidNavItem(icon: Icons.movie_outlined, activeIcon: Icons.movie, label: s.navProjects),
      LiquidNavItem(icon: Icons.list_alt_outlined, activeIcon: Icons.list_alt, label: s.navQueue),
      LiquidNavItem(icon: Icons.folder_copy_outlined, activeIcon: Icons.folder_copy, label: lang == 'zh' ? '配置库' : 'Configs'),
      LiquidNavItem(icon: Icons.settings_outlined, activeIcon: Icons.settings, label: s.navSettings),
    ];

    // 页面索引映射：0=项目, 1=队列, 3=配置库, 4=设置
    final pageToItem = {0: 0, 1: 1, 3: 2, 4: 3};
    final itemToPage = {0: 0, 1: 1, 2: 3, 3: 4};
    final itemIdx = pageToItem[selectedIndex] ?? 0;

    // 根据玻璃效果设置主题
    final effect = cfg.glassEffect;
    final glassOpacity = cfg.cardOpacity.clamp(0.0, 1.0);
    final baseAlpha = (glassOpacity * 255).round().clamp(0, 255);

    final theme = LiquidGlassTheme(
      glassColor: scheme.surface.withAlpha(baseAlpha),
      glassBorderColor: Colors.white.withValues(alpha: isDark ? 0.18 : 0.35),
      glassBlur: effect == 'blur' ? 30.0 : (effect == 'none' ? 0.0 : 25.0),
      borderRadius: 28,
      selectedColor: scheme.primary,
      unselectedColor: scheme.onSurfaceVariant,
      indicatorColor: effect == 'none'
          ? scheme.primary.withAlpha(80)
          : scheme.primary.withValues(alpha: isDark ? 0.25 : 0.20),
      indicatorBlur: effect == 'none' ? 0.0 : 15.0,
      pillHeight: 62,
      horizontalPadding: 0,
      bottomSafeAreaPadding: 6,
      iconSize: 24,
      labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
      shadowColor: Colors.black.withAlpha(isDark ? 80 : 30),
      shadowBlurRadius: 30,
      enableSpecularHighlight: effect == 'liquid',
      specularHighlightOpacity: isDark ? 0.15 : 0.08,
    );

    return LiquidGlassNavbar(
      items: items,
      currentIndex: itemIdx,
      onTap: (i) => onSelected(itemToPage[i] ?? 0),
      theme: theme,
      showLabels: true,
      isFullWidth: true,
      floatingOffset: 0,
    );
  }
}