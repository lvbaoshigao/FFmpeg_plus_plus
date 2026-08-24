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
/// - 选中项使用胶囊「药丸」指示器；按下拖动（无需长按）遮罩即跟随手指，
///   松手吸附到最近药丸并切换页面；点按直接切换（带滑动动画）；
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

/// 移动端底部导航的"玻璃配置指纹"。仅当这个值变化时才允许重建
/// OCLiquidGlassGroup/OCLiquidGlass 节点，避免无关 notify 引起的 shader 重置。
@immutable
class _NavGlassKey {
  final String effect;
  final double op;
  final bool follow;
  final int primary;
  final int second;
  const _NavGlassKey({
    required this.effect,
    required this.op,
    required this.follow,
    required this.primary,
    required this.second,
  });

  @override
  bool operator ==(Object other) =>
      other is _NavGlassKey &&
      other.effect == effect &&
      other.op == op &&
      other.follow == follow &&
      other.primary == primary &&
      other.second == second;

  @override
  int get hashCode => Object.hash(effect, op, follow, primary, second);
}

class _MobileBottomNavState extends State<MobileBottomNav> {
  /// 拖动中遮罩中心的水平位置（相对 bar 内容区，null = 未在拖动）。
  double? _dragX;
  /// 拖动开始时手指相对遮罩中心的偏移：抓取点不跳变。
  double _dragGrabOffset = 0;

  /// 底部导航 OCLiquidGlass 静态 settings：dark/light 差异化由 tint/shadow 承担，
  /// 这样所有 build 都使用同一份 const 实例，避免每次新建 settings 触发
  /// shader uniform 重置（移动端表现为液态玻璃"来回跳跃"闪烁）。
  static const _navLiquidSettings = OCLiquidGlassSettings(
    refractStrength: -0.03,
    blurRadiusPx: 1.0,
    specStrength: 0.0,
    specWidth: 1,
    lightbandStrength: 0.0,
    lightbandColor: Colors.white,
  );

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
    // 仅订阅玻璃渲染 + 主题色相关字段，避免日志/进度/任务状态等无关 notify
    // 把整个底部导航（含 OCLiquidGlassGroup + OCLiquidGlass）反复销毁重建，
    // 导致 GPU shader uniform 重置、液态玻璃视觉上"来回跳跃"闪烁。
    final glassKey = context.select<AppState, _NavGlassKey>((s) {
      final c = s.config;
      return _NavGlassKey(
        effect: c.glassEffect,
        op: c.cardOpacity,
        follow: c.glassFollowTheme,
        primary: c.themeColor,
        second: c.themeColor2,
      );
    });
    final lang = context.select<AppState, String>((s) => s.config.language);
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

    final effect = glassKey.effect;
    final op = glassKey.op.clamp(0.0, 1.0);
    final baseAlpha = (op * 255).round().clamp(0, 255);
    final follow = glassKey.follow;
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
      // 关键修复：liquid 模式下 OCLiquidGlass 自身已经接收 color=tint 作为
      // 玻璃的 tint（GPU shader 内部叠加）；如果 buildBarIn 的外层 Container
      // 再叠一层 color=tint，相当于「主题色 + 主题色」双重染色，
      // 切换页面瞬间会出现「一大片主题色块」闪烁。
      // liquid 模式 inner 用透明，只保留边框；blur/none 模式保留 tint。
      return Container(
        height: barHeight,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: effect == 'liquid' ? Colors.transparent : tint,
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
            // ── 点按：直接切换到手指位置最近的药丸（遮罩 + PageView 滑动动画） ──
            onTapUp: (d) {
              final dx = d.localPosition.dx;
              int nearest = 0;
              var bestDist = double.infinity;
              for (var i = 0; i < items.length; i++) {
                final dist = (dx - _itemCenter(i, itemW, pillGap)).abs();
                if (dist < bestDist) {
                  bestDist = dist;
                  nearest = i;
                }
              }
              widget.onSelected(itemToPage[nearest] ?? 0);
            },
            // ── 长按（按住）：遮罩放大反馈 + 开始抓取，后续移动跟随手指 ──
            onLongPressStart: (d) => setState(() {
              // 按在哪个药丸上，遮罩就从哪个药丸中心开始抓取
              final dx = d.localPosition.dx;
              int nearest = 0;
              var bestDist = double.infinity;
              for (var i = 0; i < items.length; i++) {
                final dist = (dx - _itemCenter(i, itemW, pillGap)).abs();
                if (dist < bestDist) {
                  bestDist = dist;
                  nearest = i;
                }
              }
              final grabCenter = _itemCenter(nearest, itemW, pillGap);
              _dragGrabOffset = d.localPosition.dx - grabCenter;
              _dragX = grabCenter;
            }),
            onLongPressMoveUpdate: (d) => setState(() {
              _dragX = (d.localPosition.dx - _dragGrabOffset)
                  .clamp(itemW / 2, cons.maxWidth - itemW / 2);
            }),
            onLongPressEnd: (_) => _endDrag(itemW, items.length, pillGap, itemToPage),
            onLongPressCancel: () => setState(() => _dragX = null),
            // ── 快速水平滑动（<500ms）：同样走拖动跟随 ──
            onHorizontalDragStart: (d) => setState(() {
              final dx = d.localPosition.dx;
              int nearest = 0;
              var bestDist = double.infinity;
              for (var i = 0; i < items.length; i++) {
                final dist = (dx - _itemCenter(i, itemW, pillGap)).abs();
                if (dist < bestDist) {
                  bestDist = dist;
                  nearest = i;
                }
              }
              final grabCenter = _itemCenter(nearest, itemW, pillGap);
              _dragGrabOffset = d.localPosition.dx - grabCenter;
              _dragX = grabCenter;
            }),
            onHorizontalDragUpdate: (d) => setState(() {
              _dragX = (d.localPosition.dx - _dragGrabOffset)
                  .clamp(itemW / 2, cons.maxWidth - itemW / 2);
            }),
            onHorizontalDragEnd: (_) => _endDrag(itemW, items.length, pillGap, itemToPage),
            onHorizontalDragCancel: () => setState(() => _dragX = null),
            child: SizedBox(
              width: cons.maxWidth,
              height: cons.maxHeight,
              child: Stack(children: [
              // 滑动遮罩胶囊：切换菜单时在条目间平滑滑动；拖动时跟随手指。
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
                  // 长按/拖动时放大，明确标识「已抓取/被选中」
                  scale: dragging ? 1.25 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: RepaintBoundary(child: _mask(scheme, isDark, effect)),
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
    // 调低调光参数避免「光污染」：specStrength 大幅降低，lightband 接近关闭，
    // 并整体包 RepaintBoundary 隔离 shader 绘制，避免与上方内容互相触发重绘（闪屏）。
    //
    // 关键修复：
    // 1) 使用 const _navLiquidSettings（dark 差异化交给 tint/shadow），
    //    避免每次 build 都新建 OCLiquidGlassSettings 触发 shader uniform 重置；
    // 2) 给 OCLiquidGlassGroup/OCLiquidGlass 加 ValueKey(_NavGlassKey)，仅当玻璃
    //    配置变化时才真的销毁/重建液态玻璃节点；无关 notify（进度/日志/任务）
    //    会让 key 不变，Element 复用，shader 内部状态稳定。
    final navGlassKey = ValueKey<_NavGlassKey>(glassKey);
    return OCLiquidGlassGroup(
      key: navGlassKey,
      settings: _navLiquidSettings,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
        child: RepaintBoundary(
          child: OCLiquidGlass(
            key: navGlassKey,
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
      ),
    );
  }

  /// 松手：根据遮罩中心落在哪个药丸区间判定目标页，并复位拖动状态。
  void _endDrag(double itemW, int itemCount, double gap, Map<int, int> pageMap) {
    final dx = _dragX;
    setState(() => _dragX = null);
    if (dx != null) {
      int target = 0;
      for (var i = 0; i < itemCount; i++) {
        final center = _itemCenter(i, itemW, gap);
        if ((dx - center).abs() < itemW / 2) {
          target = i;
          break;
        }
      }
      widget.onSelected(pageMap[target] ?? 0);
    }
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

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    // 纯展示：点按/拖动统一由父级 GestureDetector 处理，避免手势竞争。
    return Semantics(
      selected: selected,
      button: true,
      label: label,
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
    );
  }
}
