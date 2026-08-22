import 'package:flutter/material.dart';
import 'package:dynamic_glass_glmv/dynamic_glass_glmv.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

/// 移动端液态玻璃底部导航栏 —— 基于 dynamic_glass_glmv 的 GlassPillNavBar。
///
/// 提供原生液态玻璃视觉效果：模糊背景、渐变胶囊滑条、高光描边。
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
    final s = AppStrings.of(lang);

    final items = <AdaptiveNavigationDestination>[
      AdaptiveNavigationDestination(
        icon: Icons.movie_outlined,
        selectedIcon: Icons.movie,
        label: s.navProjects,
      ),
      AdaptiveNavigationDestination(
        icon: Icons.list_alt_outlined,
        selectedIcon: Icons.list_alt,
        label: s.navQueue,
      ),
      AdaptiveNavigationDestination(
        icon: Icons.folder_copy_outlined,
        selectedIcon: Icons.folder_copy,
        label: lang == 'zh' ? '配置库' : 'Configs',
      ),
      AdaptiveNavigationDestination(
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        label: s.navSettings,
      ),
    ];

    // 页面索引 → 列表索引映射
    // 页面: 0=项目, 1=队列, 3=配置库, 4=设置
    final pageToItem = {0: 0, 1: 1, 3: 2, 4: 3};
    // 列表索引 → 页面索引
    final itemToPage = {0: 0, 1: 1, 2: 3, 3: 4};

    final itemIdx = pageToItem[selectedIndex] ?? -1;

    return GlassPillNavBar(
      items: items,
      selectedIndex: itemIdx < 0 ? 0 : itemIdx,
      onTap: (i) => onSelected(itemToPage[i] ?? 0),
      selectedItemColor: scheme.primary,
      unselectedItemColor: scheme.onSurfaceVariant,
      style: GlassPillNavBarStyle(
        height: 62,
        borderRadius: 28,
        horizontalPadding: 0,
        bottomPadding: 6,
        blurSigma: 20,
        backgroundColor: scheme.surface.withValues(alpha: isDark ? 0.55 : 0.45),
        borderColor: Colors.white.withValues(alpha: isDark ? 0.18 : 0.35),
        borderWidth: 0.8,
        pillColors: [
          Colors.white.withValues(alpha: isDark ? 0.82 : 0.95),
          Colors.white.withValues(alpha: isDark ? 0.62 : 0.80),
          Colors.white.withValues(alpha: isDark ? 0.42 : 0.60),
        ],
        pillBorderColor: Colors.white.withValues(alpha: 0.85),
        pillShineEnabled: true,
        showLabels: true,
        iconSize: 22,
        labelGap: 2,
        animationDuration: const Duration(milliseconds: 320),
        animationCurve: Curves.easeOutCubic,
        shadows: [
          BoxShadow(
            color: Colors.black.withAlpha(isDark ? 60 : 20),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
        pillShadows: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.55),
            blurRadius: 4,
            spreadRadius: -1,
            offset: const Offset(0, -1),
          ),
        ],
      ),
    );
  }
}