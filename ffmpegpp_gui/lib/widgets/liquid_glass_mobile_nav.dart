import 'package:flutter/material.dart';
import 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_strings.dart';

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
    final theme = Theme.of(context);
    final index = _pageOrder.indexOf(selectedIndex);

    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedSlide(
        offset: hidden ? const Offset(0, 1.2) : Offset.zero,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeInOutCubic,
        child: LiquidGlassTabBar(
          currentIndex: index < 0 ? 0 : index,
          onTap: (tabIndex) => onSelected(_pageOrder[tabIndex]),
          selectedColor: theme.colorScheme.primary,
          unselectedColor: theme.colorScheme.onSurfaceVariant,
          style: const LiquidGlassTabBarStyle(
            capsuleHeight: 52,
            capsuleInset: 4,
            horizontalMargin: 14,
            bottomGap: 8,
            iconSize: 22,
          ),
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
        ),
      ),
    );
  }
}
