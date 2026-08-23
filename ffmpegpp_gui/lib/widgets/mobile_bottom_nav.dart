import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

/// 移动端液态玻璃底部导航栏 —— 基于 oc_liquid_glass 的 OCLiquidGlass。
///
/// - 整体是一颗悬浮「药丸」（胶囊）玻璃，通过 GPU fragment shader 实现
///   iOS 26 风格的折射/高光/光带液态玻璃；
/// - 选中项使用胶囊「药丸」指示器（图标/文字高亮 + 主题色圆角背景）；
/// - 遵循设置中的玻璃效果配置（liquid/blur/none）。
class MobileBottomNav extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const MobileBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  State<MobileBottomNav> createState() => _MobileBottomNavState();
}

class _MobileBottomNavState extends State<MobileBottomNav> {
  @override
  void initState() {
    super.initState();
    // 首次进入主界面即预加载 oc_liquid_glass 的 fragment shader，
    // 避免底部导航第一次渲染时的异步加载闪烁。
    OCLiquidGlassGroup.precacheShader();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lang = context.watch<AppState>().config.language;
    final cfg = context.watch<AppState>().config;
    final s = AppStrings.of(lang);

    final items = <(IconData, IconData, String)>[
      (Icons.movie_outlined, Icons.movie, s.navProjects),
      (Icons.list_alt_outlined, Icons.list_alt, s.navQueue),
      (Icons.folder_copy_outlined, Icons.folder_copy, lang == 'zh' ? '配置库' : 'Configs'),
      (Icons.settings_outlined, Icons.settings, s.navSettings),
    ];

    // 页面索引映射：0=项目, 1=队列, 3=配置库, 4=设置
    const pageToItem = {0: 0, 1: 1, 3: 2, 4: 3};
    const itemToPage = {0: 0, 1: 1, 2: 3, 3: 4};
    final itemIdx = pageToItem[widget.selectedIndex] ?? 0;

    final effect = cfg.glassEffect;
    final op = cfg.cardOpacity.clamp(0.0, 1.0);
    final baseAlpha = (op * 255).round().clamp(0, 255);

    final barHeight = 60.0;
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final radius = barHeight / 2; // 完全胶囊形药丸

    // 玻璃主体的着色与描边（同时作为 shader 加载失败/关闭效果时的兜底背景）
    final follow = cfg.glassFollowTheme;
    final baseColor = follow ? scheme.primary : scheme.surface;
    final tint = baseColor.withAlpha(baseAlpha);
    final borderColor = Colors.white.withValues(alpha: isDark ? 0.16 : 0.32);

    // 胶囊指示器：选中项图标背后的主题色药丸
    final selectedColor = scheme.primary;
    final indicator = effect == 'none'
        ? scheme.primary.withAlpha(70)
        : scheme.primary.withValues(alpha: isDark ? 0.28 : 0.20);
    final unselectedColor = scheme.onSurfaceVariant;

    Widget buildBar() => Container(
          height: barHeight,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: borderColor, width: 0.7),
          ),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                _NavItem(
                  icon: items[i].$1,
                  activeIcon: items[i].$2,
                  label: items[i].$3,
                  selected: i == itemIdx,
                  selectedColor: selectedColor,
                  unselectedColor: unselectedColor,
                  indicatorColor: indicator,
                  onTap: () => widget.onSelected(itemToPage[i] ?? 0),
                ),
            ],
          ),
        );

    // none：纯色药丸（无玻璃光效）
    if (effect == 'none') {
      return Padding(
        padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
        child: buildBar(),
      );
    }

    // liquid / blur：oc_liquid_glass 液态玻璃（GPU fragment shader）
    final settings = effect == 'blur'
        ? OCLiquidGlassSettings(
            refractStrength: -0.01,
            blurRadiusPx: 10,
            specStrength: 6,
            specWidth: 6,
            lightbandStrength: 0.25,
            lightbandColor: Colors.white,
          )
        : OCLiquidGlassSettings(
            refractStrength: -0.06,
            blurRadiusPx: 1.5,
            specStrength: isDark ? 18.0 : 26.0,
            specWidth: 10,
            lightbandStrength: 0.9,
            lightbandColor: Colors.white,
          );

    // oc_liquid_glass 需要将形状放在 group 内部；shader 加载失败时自动回退到
    // 内部 Container（即 buildBar），不会出现空白。
    return OCLiquidGlassGroup(
      settings: settings,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
        child: OCLiquidGlass(
          borderRadius: radius,
          color: tint,
          shadow: BoxShadow(
            color: Colors.black.withAlpha(isDark ? 70 : 26),
            blurRadius: 22,
            offset: const Offset(0, 6),
          ),
          child: buildBar(),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final Color selectedColor;
  final Color unselectedColor;
  final Color indicatorColor;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.indicatorColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 选中项：胶囊药丸指示器
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: selected ? indicatorColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  selected ? activeIcon : icon,
                  size: 23,
                  color: color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
