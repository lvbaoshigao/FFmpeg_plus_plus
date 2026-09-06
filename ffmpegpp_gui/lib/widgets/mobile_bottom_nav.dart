import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import 'app_card.dart' show SurfaceStyle;
import 'liquid_glass_fallback.dart';

// ═══════════════════════════════════════════════════════════════
// 主底部导航（MobileBottomNav）与子页面玻璃切换栏（MobileNavStyleTabBar）
// 共享的样式实现：navStyle 四值取值、tint/边框/遮罩胶囊、玻璃外壳。
// ═══════════════════════════════════════════════════════════════

/// 玻璃样式配置指纹。仅当这个值变化时才允许重建
/// OCLiquidGlassGroup/OCLiquidGlass 节点，避免无关 notify 引起的 shader 重置。
@immutable
class NavGlassPal {
  /// 底部菜单栏样式（navStyle 四值：theme/liquid/blur/gray）
  final String style;
  final double op;
  final int primary;
  final int second;
  const NavGlassPal({
    required this.style,
    required this.op,
    required this.primary,
    required this.second,
  });

  @override
  bool operator ==(Object other) =>
      other is NavGlassPal &&
      other.style == style &&
      other.op == op &&
      other.primary == primary &&
      other.second == second;

  @override
  int get hashCode => Object.hash(style, op, primary, second);
}

/// 订阅玻璃渲染 + 主题色相关字段（不订阅日志/进度/任务等高频 notify）。
NavGlassPal navGlassPalOf(BuildContext context) =>
    context.select<AppState, NavGlassPal>((s) {
      final c = s.config;
      return NavGlassPal(
        style: c.navStyle,
        op: c.cardOpacity,
        primary: c.themeColor,
        second: c.themeColor2,
      );
    });

/// 由 navStyle + 透明度 + 主题派生的即时视觉值。
class NavGlassLook {
  final String style;
  /// theme/gray 为纯色实心（不透明）
  final bool solid;
  /// 容器染色（liquid 模式作为 OCLiquidGlass 的 color，其余作 Container 底色）
  final Color tint;
  final Color borderColor;
  final double borderWidth;
  final Color selectedColor;
  final Color unselectedColor;
  const NavGlassLook({
    required this.style,
    required this.solid,
    required this.tint,
    required this.borderColor,
    required this.borderWidth,
    required this.selectedColor,
    required this.unselectedColor,
  });
}

NavGlassLook navGlassLook(ColorScheme scheme, bool isDark, NavGlassPal pal) {
  final style = pal.style;
  final op = pal.op.clamp(0.0, 1.0);
  // 纯色样式（theme/gray）强制完全不透明（255）——纯色语义即实心，
  // 不再跟随 cardOpacity（此前 ~88% 保底仍透底，被反馈为「仍有透明度」）。
  final solid = style == SurfaceStyle.theme || style == SurfaceStyle.gray;
  final baseAlpha = solid ? 255 : (op * 255).round().clamp(0, 255);
  final baseColor = style == SurfaceStyle.theme
      ? scheme.primary
      : style == SurfaceStyle.gray
          ? scheme.surfaceContainerHigh
          : scheme.surface;
  return NavGlassLook(
    style: style,
    solid: solid,
    tint: baseColor.withAlpha(baseAlpha),
    borderColor: style == SurfaceStyle.blur
        ? scheme.outlineVariant.withAlpha(70)
        : Colors.white.withValues(alpha: isDark ? 0.16 : 0.32),
    borderWidth: style == SurfaceStyle.blur ? 0.5 : 0.7,
    // blur/theme 时遮罩是实色块，选中项用 onPrimary 反白；其余用主题色。
    selectedColor: style == SurfaceStyle.blur || style == SurfaceStyle.theme
        ? scheme.onPrimary
        : scheme.primary,
    unselectedColor: scheme.onSurfaceVariant,
  );
}

/// 遮罩胶囊外观：blur=实心主题色；theme=白色高亮（底栏本身即主题色）；
/// liquid/gray=白→主题色渐变。
Widget navMaskPill(ColorScheme scheme, bool isDark, String style) {
  if (style == SurfaceStyle.blur) {
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
  if (style == SurfaceStyle.theme) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Colors.white.withAlpha(isDark ? 64 : 84),
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.35 : 0.55),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.06),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
  final indicator = scheme.primary.withValues(alpha: isDark ? 0.28 : 0.20);
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

/// OCLiquidGlass 静态 settings：dark/light 差异化由 tint/shadow 承担，
/// 这样所有 build 都使用同一份 const 实例，避免每次新建 settings 触发
/// shader uniform 重置（移动端表现为液态玻璃"来回跳跃"闪烁）。
const _navLiquidSettings = OCLiquidGlassSettings(
  // 3D 液态玻璃：u_size 修复后这些参数才真正生效。
  // refractStrength（负 = 凹透镜）给水滴折射；spec 给镜面高光；lightband 给光带。
  // 数值取中等：可见 3D，但不复现早期的「光污染/横线」。
  // specStrength 3.0→0.5、specPower 100→48：shader 的 L1/L2 两盏对向灯会在
  // 圆角的左上/右下角各打出一个镜面光点，原参数峰值 +2.5 直接过曝成明显白点；
  // 降低强度并放宽高光锐度后变成柔和的角部光泽，不再抢眼。
  // blurRadiusPx/lightbandStrength 与 mobile_glass_pill 同步归零：
  // 1px 径向模糊每像素 49 次纹理采样，进度刷新时导航栏每帧重采样浪费 GPU；
  // 光带在药丸中线上形成横向分界线（上下分层），彻底关闭。
  refractStrength: -0.10,
  blurRadiusPx: 0.0,
  specStrength: 0.5,
  specPower: 48,
  specWidth: 10,
  lightbandStrength: 0.0,
  lightbandColor: Colors.white,
);

/// navStyle 感知的玻璃外壳：把 [child] 按「底部菜单栏样式」四值套上外皮——
/// theme/gray 直出、blur 高斯模糊、liquid GPU 液态玻璃（无 Impeller 时回退）。
/// 主底部导航与子页面切换栏共用，保证子页面底栏与全局导航观感一致。
class NavGlassShell extends StatelessWidget {
  final NavGlassPal pal;
  /// 胶囊圆角（一般 = 栏高一半）
  final double radius;
  /// OCLiquidGlass 的 key 前缀：同屏多实例（如主导航 + 弹层内切换栏）时防 key 冲突
  final String keyPrefix;
  final Widget child;

  const NavGlassShell({
    super.key,
    required this.pal,
    required this.radius,
    required this.keyPrefix,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final look = navGlassLook(scheme, isDark, pal);
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final op = pal.op.clamp(0.0, 1.0);

    // theme/gray：纯色药丸（无玻璃光效）
    if (look.solid) {
      return Padding(
        padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
        child: child,
      );
    }

    // blur：扁平高斯模糊（无 3D 液态光效），遮罩为实心主题色
    if (look.style == SurfaceStyle.blur) {
      return Padding(
        padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
        // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: child,
          ),
        ),
      );
    }

    // liquid：oc_liquid_glass 液态玻璃（GPU fragment shader）。
    // 无 Impeller（Windows 默认 Skia）时回退为高斯模糊 + 倒角高光，
    // 避免 shader backdrop 被整体跳过、底部导航玻璃整块消失。
    if (!shaderGlassSupported) {
      return Padding(
        padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
        // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
        child: LiquidGlassBackdrop(
          borderRadius: BorderRadius.circular(radius),
          sigma: 16,
          opacity: op,
          shadow: BoxShadow(
            color: Colors.black.withAlpha(isDark ? 70 : 26),
            blurRadius: 22,
            offset: const Offset(0, 6),
          ),
          child: child,
        ),
      );
    }

    // 关键修复（沿用主底部导航的防闪烁策略）：
    // 1) const _navLiquidSettings，避免每次 build 新建 settings 触发 shader 重置；
    // 2) OCLiquidGlassGroup 用 ValueKey(NavGlassPal)，仅玻璃配置变化才重建节点；
    // 3) OCLiquidGlass 独立 key（带 keyPrefix 防多实例冲突）；
    // 4) RepaintBoundary 放在 OCLiquidGlassGroup 外部隔离重绘。
    return RepaintBoundary(
      child: OCLiquidGlassGroup(
        key: ValueKey<NavGlassPal>(pal),
        settings: _navLiquidSettings,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 2, 14, bottomSafe + 8),
          child: OCLiquidGlass(
            key: ValueKey<String>('${pal.hashCode}_${keyPrefix}_inner'),
            borderRadius: radius,
            color: look.tint,
            shadow: BoxShadow(
              color: Colors.black.withAlpha(isDark ? 70 : 26),
              blurRadius: 22,
              offset: const Offset(0, 6),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 移动端底部导航栏 —— 样式由「底部菜单栏样式」（AppConfig.navStyle）接管。
///
/// - 整体是一颗悬浮「药丸」（胶囊）；四种样式：
///   liquid 液态玻璃（oc_liquid_glass GPU shader）、blur 扁平高斯模糊
///   （BackdropFilter）、theme 跟随主题色（纯色）、gray 灰色（纯色）；
/// - 选中项使用胶囊「药丸」指示器；按下拖动（无需长按）遮罩即跟随手指，
///   松手吸附到最近药丸并切换页面；点按直接切换（带滑动动画）；
/// - 遵循设置→主题→样式→底部菜单栏样式（navStyle 四值）。
class MobileBottomNav extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  /// 可选：主界面 PageView 的控制器。传入后遮罩在「页面滑动中」会连续跟随
  /// PageView 的实时位置（0.0~3.0 的小数页），而不是等 onPageChanged 按整页
  /// 跳变 —— 修复从第 1 页快速滑到第 4 页时遮罩在第 3 项短暂停留再跳走的
  /// 「动画跳跃」问题。仅遮罩子树订阅该 Listenable，每帧重建成本极小。
  final PageController? pageController;

  const MobileBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.pageController,
  });

  @override
  State<MobileBottomNav> createState() => _MobileBottomNavState();
}

class _MobileBottomNavState extends State<MobileBottomNav> {
  /// 拖动中遮罩中心的水平位置（相对 bar 内容区，null = 未在拖动）。
  double? _dragX;
  /// 拖动开始时手指相对遮罩中心的偏移：抓取点不跳变。
  double _dragGrabOffset = 0;
  /// 长按手势是否已接管拖动（接管后 horizontalDrag 的 cancel 不得复位遮罩，
  /// 否则遮罩会先跳回旧选中项、再被长按移动拉回，出现可见的双吸附抖动）。
  bool _longPressActive = false;

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
    // 仅订阅玻璃渲染 + 主题色相关字段（navGlassPalOf 内部用 select），避免
    // 日志/进度/任务状态等无关 notify 反复销毁重建整个底部导航（含
    // OCLiquidGlassGroup + OCLiquidGlass），导致 GPU shader uniform 重置、
    // 液态玻璃视觉上"来回跳跃"闪烁。
    final pal = navGlassPalOf(context);
    final lang = context.select<AppState, String>((s) => s.config.language);
    final s = AppStrings.of(lang);
    final look = navGlassLook(scheme, isDark, pal);
    final style = look.style;

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

    final barHeight = 60.0;
    final radius = barHeight / 2;
    final selectedColor = look.selectedColor;
    final unselectedColor = look.unselectedColor;

    // 药丸间距：每个药丸之间留 4px 间隔
    const pillGap = 4.0;

    Widget buildBarIn() {
      // 关键修复：liquid 模式下 OCLiquidGlass 自身已经接收 color=tint 作为
      // 玻璃的 tint（GPU shader 内部叠加）；如果 buildBarIn 的外层 Container
      // 再叠一层 color=tint，相当于「主题色 + 主题色」双重染色，
      // 切换页面瞬间会出现「一大片主题色块」闪烁。
      // liquid 模式 inner 用透明，只保留边框；blur/theme/gray 模式保留 tint。
      return Container(
        height: barHeight,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: style == SurfaceStyle.liquid ? Colors.transparent : look.tint,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: look.borderColor,
            width: look.borderWidth,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (ctx, cons) {
          // 计算每个药丸的宽度（减去间距）
          final totalGap = pillGap * (items.length - 1);
          final itemW = (cons.maxWidth - totalGap) / items.length;
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
              _longPressActive = true;
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
            onLongPressEnd: (_) {
              _longPressActive = false;
              _endDrag(itemW, items.length, pillGap, itemToPage);
            },
            onLongPressCancel: () {
              _longPressActive = false;
              setState(() => _dragX = null);
            },
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
            onHorizontalDragCancel: () {
              // 长按已接管时由长按流程收尾，这里不要复位遮罩（否则先跳回旧项）。
              if (_longPressActive) return;
              setState(() => _dragX = null);
            },
            child: SizedBox(
              width: cons.maxWidth,
              height: cons.maxHeight,
              child: Stack(children: [
              // 滑动遮罩胶囊：切换菜单时在条目间平滑滑动；拖动时跟随手指；
              // 页面滑动（PageView）中连续跟随页面位置（见 pageController），
              // 不再「途经项停留后跳变」。
              _buildMaskPositioned(
                itemIdx, itemW, pillGap, items.length,
                scheme: scheme, isDark: isDark, style: style,
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

    // 外壳（solid 直出 / blur 高斯模糊 / liquid GPU 玻璃 + 回退）由
    // NavGlassShell 按 navStyle 统一套皮——与子页面切换栏共享同一实现。
    return NavGlassShell(
      pal: pal,
      radius: radius,
      keyPrefix: 'nav',
      child: buildBarIn(),
    );
  }

  /// 松手：吸附到「离遮罩中心最近」的药丸并切换页面。
  ///
  /// 修复双吸附抖动：旧实现先 `setState(_dragX = null)`（遮罩开始朝旧选中项
  /// 回放），再 onSelected 切页（遮罩二次朝新项移动），肉眼看到两段吸附；
  /// 且旧判定 `(dx-center).abs() < itemW/2` 在药丸 4px 缝隙处存在死区，
  /// 死区内全部不命中 → target 默认为 0（误跳回首页）。
  /// 现在：先切页（父组件同帧更新 selectedIndex），再复位拖动态；
  /// 目标用最近中心选取，无缝隙死区。
  void _endDrag(double itemW, int itemCount, double gap, Map<int, int> pageMap) {
    final dx = _dragX;
    if (dx != null) {
      int target = 0;
      var bestDist = double.infinity;
      for (var i = 0; i < itemCount; i++) {
        final dist = (dx - _itemCenter(i, itemW, gap)).abs();
        if (dist < bestDist) {
          bestDist = dist;
          target = i;
        }
      }
      // 先通知父组件切换选中页：本帧内 widget.selectedIndex 即更新为新值，
      // 随后的 _dragX=null 复位让遮罩直接从松手点一次动画到新药丸。
      widget.onSelected(pageMap[target] ?? 0);
    }
    setState(() => _dragX = null);
  }

  /// 第 i 个药丸的左边缘位置（考虑间距）。
  double _itemLeft(int i, double itemW, double gap) => i * (itemW + gap);

  /// 第 i 个药丸的中心位置（考虑间距）。
  double _itemCenter(int i, double itemW, double gap) => i * (itemW + gap) + itemW / 2;

  /// 构建遮罩胶囊的定位子树。
  ///
  /// 三种状态：
  /// 1. 药丸拖动（_dragX != null）：Duration.zero 精确跟随手指；
  /// 2. PageView 滑动中（pageController.page 为非整页小数）：遮罩以
  ///    Duration.zero 连续跟随页面实时位置 —— 修复快速滑动跨页时，
  ///    遮罩先在中途项停留一拍再跳到目标项的「跳跃」观感；
  /// 3. 静止：AnimatedPositioned 以 260ms easeOutCubic 吸附到选中项。
  /// 仅此子树订阅 pageController，页面滑动期间每帧只重建这个小 Positioned。
  Widget _buildMaskPositioned(
    int itemIdx,
    double itemW,
    double pillGap,
    int itemCount, {
    required ColorScheme scheme,
    required bool isDark,
    required String style,
  }) {
    final dragging = _dragX != null;
    final mask = AnimatedScale(
      // 长按/拖动时放大，明确标识「已抓取/被选中」
      scale: dragging ? 1.25 : 1.0,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      child: RepaintBoundary(child: navMaskPill(scheme, isDark, style)),
    );

    Widget buildStatic() => AnimatedPositioned(
          duration: dragging ? Duration.zero : const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          left: dragging ? (_dragX! - itemW / 2) : _itemLeft(itemIdx, itemW, pillGap),
          top: 2,
          bottom: 2,
          width: itemW,
          child: mask,
        );

    final pc = widget.pageController;
    if (pc == null || dragging) return buildStatic();

    return AnimatedBuilder(
      animation: pc,
      builder: (ctx, _) {
        double? frac;
        if (pc.hasClients) {
          final p = pc.page ?? itemIdx.toDouble();
          if ((p - itemIdx).abs() > 0.005 &&
              p >= -0.001 &&
              p <= itemCount - 1 + 0.001) {
            frac = p.clamp(0.0, itemCount - 1).toDouble();
          }
        }
        if (frac == null) return buildStatic();
        // 页面滑动中：连续位置。药丸中心间距 = itemW + pillGap。
        return Positioned(
          left: frac * (itemW + pillGap),
          top: 2,
          bottom: 2,
          width: itemW,
          child: mask,
        );
      },
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
  /// 图标/文字尺寸：主导航 60px 高用默认值，较矮的子页面切换栏可调小。
  final double iconSize;
  final double labelSize;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    this.iconSize = 27,
    this.labelSize = 9.0,
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
              size: iconSize,
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
                fontSize: labelSize,
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

/// 子页面级底部玻璃切换栏 —— 与主底部导航（MobileBottomNav）同一套
/// 「底部菜单栏样式」（navStyle 四值 + cardOpacity + 主题色 + 药丸遮罩）。
///
/// 供移动端二级页面使用（如 AI「新建供应商」的 配置/模型 切换），
/// 替代此前各页自绘的 AppCard 底栏——那些底栏只跟随卡片样式，
/// 用户切换全局导航样式时会出现「这里不一样」的割裂感。
///
/// 与主导航的区别：不绑 PageView、无拖拽手势，点按切换（遮罩 260ms 滑动吸附）。
class MobileNavStyleTabBar extends StatefulWidget {
  /// (图标, 文字) 列表，2~4 项为宜
  final List<(IconData, String)> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  /// 栏高（含 4px 内边距），默认 54——比主导航 60 略矮，适合子页面
  final double height;

  const MobileNavStyleTabBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.height = 54,
  });

  @override
  State<MobileNavStyleTabBar> createState() => _MobileNavStyleTabBarState();
}

class _MobileNavStyleTabBarState extends State<MobileNavStyleTabBar> {
  @override
  void initState() {
    super.initState();
    // 与主导航一致：提前预加载 shader，避免首次渲染异步加载闪烁。
    OCLiquidGlassGroup.precacheShader();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pal = navGlassPalOf(context);
    final look = navGlassLook(scheme, isDark, pal);
    final style = look.style;

    final barHeight = widget.height;
    final radius = barHeight / 2;
    const pillGap = 4.0;

    Widget buildBarIn() {
      // 与主底部导航同一规则：liquid 透明（tint 交给 shader），其余用 tint。
      return Container(
        height: barHeight,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: style == SurfaceStyle.liquid ? Colors.transparent : look.tint,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: look.borderColor, width: look.borderWidth),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (ctx, cons) {
          final totalGap = pillGap * (widget.items.length - 1);
          final itemW = (cons.maxWidth - totalGap) / widget.items.length;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 点按最近项：与主导航一致的「就近吸附」手感
            onTapUp: (d) {
              final dx = d.localPosition.dx;
              int nearest = 0;
              var bestDist = double.infinity;
              for (var i = 0; i < widget.items.length; i++) {
                final dist = (dx - (i * (itemW + pillGap) + itemW / 2)).abs();
                if (dist < bestDist) {
                  bestDist = dist;
                  nearest = i;
                }
              }
              if (nearest != widget.selectedIndex) widget.onSelected(nearest);
            },
            child: SizedBox(
              width: cons.maxWidth,
              height: cons.maxHeight,
              child: Stack(children: [
                // 药丸遮罩：切换时 260ms easeOutCubic 滑动吸附（与主导航一致）
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: widget.selectedIndex * (itemW + pillGap),
                  top: 2,
                  bottom: 2,
                  width: itemW,
                  child: RepaintBoundary(
                      child: navMaskPill(scheme, isDark, style)),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < widget.items.length; i++) ...[
                      if (i > 0) SizedBox(width: pillGap),
                      SizedBox(
                        width: itemW,
                        child: _NavItem(
                          icon: widget.items[i].$1,
                          activeIcon: widget.items[i].$1,
                          label: widget.items[i].$2,
                          selected: i == widget.selectedIndex,
                          selectedColor: look.selectedColor,
                          unselectedColor: look.unselectedColor,
                          iconSize: 21,
                          labelSize: 10,
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

    return NavGlassShell(
      pal: pal,
      radius: radius,
      keyPrefix: 'tabbar',
      child: buildBarIn(),
    );
  }
}
