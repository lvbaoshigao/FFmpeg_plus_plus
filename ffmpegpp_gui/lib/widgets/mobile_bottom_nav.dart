import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

/// 移动端液态玻璃底部导航栏 —— 基于 oc_liquid_glass 的 OCLiquidGlass。
///
/// - 整体是一颗悬浮「药丸」（胶囊）玻璃；liquid 用 GPU shader 液态玻璃，
///   blur 用扁平高斯模糊（BackdropFilter），none 为纯色药丸；
/// - 选中项使用胶囊「药丸」指示器；长按指示器可左右拖动，遮罩跟随手指，
///   松手切换到对应页面，按住时遮罩有放大特效；
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
  /// 长按拖动中遮罩中心的水平位置（相对 bar 内容区，null = 未在拖动）。
  double? _dragX;
  /// 长按开始瞬间「手指」相对「遮罩中心」的水平偏移：按住遮罩边缘拖动时
  /// 保持抓取点不跳变，松手后按遮罩中心判页。
  double _dragGrabOffset = 0;

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
    final cfg = context.watch<AppState>().config;
    final lang = cfg.language;
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
    final follow = cfg.glassFollowTheme;
    final baseColor = follow ? scheme.primary : scheme.surface;
    final tint = baseColor.withAlpha(baseAlpha);

    final barHeight = 60.0;
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final radius = barHeight / 2;

    // 选中项颜色：blur 时遮罩是实心主题色，选中项用 onPrimary 反白；其余用主题色。
    final selectedColor = effect == 'blur' ? scheme.onPrimary : scheme.primary;
    final unselectedColor = scheme.onSurfaceVariant;

    // 药丸间距：每个药丸之间留 4px 间隔
    const pillGap = 4.0;

    Widget buildBarIn() {
      return Container(
        height: barHeight,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: effect == 'blur'
                ? scheme.outlineVariant.withAlpha(70)
                : Colors.white.withValues(alpha: isDark ? 0.16 : 0.32),
            width: effect == 'blur' ? 0.5 : 0.7,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (ctx, cons) {
          // 计算每个药丸的宽度（减去间距）
          final totalGap = pillGap * (items.length - 1);
          final itemW = (cons.maxWidth - totalGap) / items.length;
          final dragging = _dragX != null;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (d) => setState(() {
              final curCenter = _itemCenter(itemIdx, itemW, pillGap);
              _dragGrabOffset = d.localPosition.dx - curCenter;
              _dragX = curCenter;
            }),
            onLongPressMoveUpdate: (d) => setState(() {
              _dragX = (d.localPosition.dx - _dragGrabOffset)
                  .clamp(itemW / 2, cons.maxWidth - itemW / 2);
            }),
            onLongPressEnd: (_) {
              final dx = _dragX;
              setState(() => _dragX = null);
              if (dx != null) {
                // 根据遮罩中心落在哪个药丸区间来判定目标页
                int target = 0;
                for (var i = 0; i < items.length; i++) {
                  final center = _itemCenter(i, itemW, pillGap);
                  if ((dx - center).abs() < itemW / 2) {
                    target = i;
                    break;
                  }
                }
                widget.onSelected(itemToPage[target] ?? 0);
              }
            },
            onLongPressCancel: () => setState(() => _dragX = null),
            child: SizedBox(
              width: cons.maxWidth,
              height: cons.maxHeight,
              child: Stack(children: [
              // 滑动遮罩胶囊：切换菜单时在条目间平滑滑动；长按拖动时跟随手指。
              AnimatedPositioned(
                duration: dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: dragging
                    ? (_dragX! - itemW / 2)
                    : _itemLeft(itemIdx, itemW, pillGap),
                top: 2,
                bottom: 2,
                width: itemW,
                child: AnimatedScale(
                  scale: dragging ? 1.12 : 1.0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: _mask(scheme, isDark, effect),
                ),
              ),
              // 药丸行：每个药丸之间有间距，crossAxisAlignment.stretch 让药丸填满高度
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) SizedBox(width: pillGap),
                    SizedBox(
                      width: itemW,
                      child: _NavItem(
                        icon: items[i].$1,
                        activeIcon: items[i].$2,
                        label: items[i].$3,
                        selected: i == itemIdx,
                        selectedColor: selectedColor,
                        unselectedColor: unselectedColor,
                        onTap: () => widget.onSelected(itemToPage[i] ?? 0),
                      ),
                    ),
                  ],
                ],
              ),
            ]),
            ),
          );
        }),
      );
    }

    // none：纯色药丸（无玻璃光效）
    if (effect == 'none') {
      return Padding(
        padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
        child: buildBarIn(),
      );
    }

    // blur：扁平高斯模糊（无 3D 液态光效），遮罩为实心主题色
    if (effect == 'blur') {
      return Padding(
        padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
        child: RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: buildBarIn(),
            ),
          ),
        ),
      );
    }

    // liquid：oc_liquid_glass 液态玻璃（GPU fragment shader）
    final settings = OCLiquidGlassSettings(
      refractStrength: -0.06,
      blurRadiusPx: 1.5,
      specStrength: isDark ? 18.0 : 26.0,
      specWidth: 10,
      lightbandStrength: 0.9,
      lightbandColor: Colors.white,
    );

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
          child: buildBarIn(),
        ),
      ),
    );
  }

  /// 第 i 个药丸的左边缘位置（考虑间距）。
  double _itemLeft(int i, double itemW, double gap) => i * (itemW + gap);

  /// 第 i 个药丸的中心位置（考虑间距）。
  double _itemCenter(int i, double itemW, double gap) => i * (itemW + gap) + itemW / 2;

  /// 遮罩胶囊外观：blur=实心主题色；liquid=白→主题色渐变；none=半透明主题色。
  Widget _mask(ColorScheme scheme, bool isDark, String effect) {
    if (effect == 'blur') {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: scheme.primary,
          border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 0.8),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withAlpha(70),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      );
    }
    final indicator = effect == 'none'
        ? scheme.primary.withAlpha(70)
        : scheme.primary.withValues(alpha: isDark ? 0.28 : 0.20);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.16 : 0.42),
            indicator,
          ],
          stops: const [0.0, 0.6],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.22 : 0.50),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.08),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
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
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    // 使用 GestureDetector 而非 InkWell：InkWell 内部的 TapGestureRecognizer
    // 会与父级 GestureDetector 的 LongPressGestureRecognizer 竞争，
    // 导致长按拖动遮罩不生效。GestureDetector 只注册 onTap，不干扰长按。
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: color),
              duration: const Duration(milliseconds: 220),
              builder: (ctx, c, child) => Icon(
                selected ? activeIcon : icon,
                size: 27,
                color: c,
              ),
            ),
            const SizedBox(height: 1),
            TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: color),
              duration: const Duration(milliseconds: 220),
              builder: (ctx, c, child) => Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.0,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: c,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
