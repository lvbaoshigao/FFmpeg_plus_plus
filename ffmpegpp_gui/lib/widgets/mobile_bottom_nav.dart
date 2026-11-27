import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../theme/app_neutral_surface.dart';
import '../theme/app_strings.dart';
import '../theme/mobile_ui.dart';
import 'app_card.dart' show SurfaceStyle;
import 'liquid_glass_fallback.dart';
import 'selection_highlight.dart';
import 'tabler_icon.dart';

// ═══════════════════════════════════════════════════════════════
// 侧边导轨（MobileNavRail）与子页面玻璃切换栏（MobileNavStyleTabBar）
// 共享的样式实现：navStyle 四值取值、tint/边框/遮罩胶囊、玻璃外壳。
// ═══════════════════════════════════════════════════════════════

/// 玻璃样式配置指纹。仅当这个值变化时才允许重建
/// OCLiquidGlassGroup/OCLiquidGlass 节点，避免无关 notify 引起的 shader 重置。
@immutable
class NavGlassPal {
  /// 侧边导轨样式（navStyle 四值：theme/liquid/blur/gray）
  final String style;
  final double op;
  final int primary;
  final bool useThemeColor;
  final int second;

  /// 「设置 → 样式 → 玻璃底色遵循主题色」：玻璃 tint 用主题色而非 surface 灰。
  /// 此前只有桌面端 GlassPanel 读它，移动端底栏/药丸完全不读 → 该开关在移动端
  /// 表现为「无效」。这里纳入指纹并落到 tint 上（默认 false，观感不变）。
  final bool follow;

  /// 玻璃细节（模糊度 / 通透度 / 高光强度与位置 / 边缘光）
  final GlassTuning tuning;

  /// 主题色协调度（避免直接铺 scheme.primary 过亮）
  final double tone;
  const NavGlassPal({
    required this.style,
    required this.op,
    required this.primary,
    required this.useThemeColor,
    required this.second,
    required this.follow,
    required this.tuning,
    required this.tone,
  });

  @override
  bool operator ==(Object other) =>
      other is NavGlassPal &&
      other.style == style &&
      other.op == op &&
      other.primary == primary &&
      other.useThemeColor == useThemeColor &&
      other.second == second &&
      other.follow == follow &&
      other.tuning == tuning &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(
    style,
    op,
    primary,
    useThemeColor,
    second,
    follow,
    tuning,
    tone,
  );
}

/// 订阅玻璃渲染 + 主题色相关字段（不订阅日志/进度/任务等高频 notify）。
NavGlassPal navGlassPalOf(BuildContext context) =>
    context.select<AppState, NavGlassPal>((s) {
      final c = s.config;
      return NavGlassPal(
        style: c.navStyle,
        op: c.cardOpacity,
        primary: c.themeColor,
        useThemeColor: c.useThemeColor,
        second: c.themeColor2,
        follow: c.glassFollowTheme,
        tuning: GlassTuning(
          blur: c.glassBlur,
          clarity: c.glassClarity,
          highlight: c.glassHighlight,
          lightPos: c.glassLightPos,
          edge: c.glassEdge,
        ),
        tone: c.themeTone,
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
  // 通透度 → 基准 alpha 的等比缩放（默认 1.0，观感不变）
  final baseAlpha = solid
      ? 255
      : ((op * (isDark ? 100 : 128)) * pal.tuning.tintScale).round().clamp(
          0,
          255,
        );
  // 主题色基底：跟随主题色 / 玻璃遵循主题色时都用「与表面色混合后的协调色」，
  // 避免 scheme.primary（暗色下 tone 80）大面积铺开过亮；
  // 灰色样式额外去饱和，保证是真正的中性灰（原有 fromSeed 种子色偏）。
  final accent = pal.useThemeColor
      ? harmonizedAccent(scheme, pal.tone)
      : AppNeutralSurface.card(scheme.brightness);
  final baseColor = style == SurfaceStyle.theme
      ? accent
      : style == SurfaceStyle.gray
      ? AppNeutralSurface.card(scheme.brightness)
      : themedGlassBase(
          scheme,
          pal.tone,
          pal.follow && pal.useThemeColor,
          second: pal.useThemeColor ? pal.second : -1,
        );
  if (isMobilePlatform) {
    final neutral = AppNeutralSurface.card(scheme.brightness);
    return NavGlassLook(
      style: style,
      solid: solid,
      // The glass shell owns the tint and rim for both glass variants.
      tint: solid
          ? (style == SurfaceStyle.theme
                ? Color.lerp(neutral, accent, 0.16)!
                : neutral)
          : Colors.transparent,
      borderColor: scheme.onSurface.withValues(alpha: 0.16),
      borderWidth: solid ? 1 : 0,
      selectedColor: scheme.onSurface,
      unselectedColor: Color.lerp(
        scheme.onSurface,
        scheme.onSurfaceVariant,
        0.40,
      )!,
    );
  }
  // 边缘光 → 描边的透明度/线宽缩放（基准 1.0 = 与改动前一致）
  final edgeBlur = edgeBorder(70 / 255, 0.5, pal.tuning.edge);
  final edgeWhite = edgeBorder(isDark ? 0.16 : 0.32, 0.7, pal.tuning.edge);
  return NavGlassLook(
    style: style,
    solid: solid,
    tint: baseColor.withAlpha(baseAlpha),
    borderColor: style == SurfaceStyle.blur
        ? scheme.outlineVariant.withAlpha(
            (edgeBlur.alpha * 255).round().clamp(0, 255),
          )
        : Colors.white.withValues(alpha: edgeWhite.alpha),
    borderWidth: style == SurfaceStyle.blur ? edgeBlur.width : edgeWhite.width,
    // Shell colors stay independent of SelectionHighlight; callers adjust the
    // selected foreground for its theme surface and high-contrast mode.
    selectedColor: style == SurfaceStyle.theme
        ? scheme.onPrimary
        : style == SurfaceStyle.gray
        ? scheme.onSurface
        : scheme.primary,
    unselectedColor: scheme.onSurfaceVariant,
  );
}

/// Moving indicator geometry is independent of the configured surface style.
/// 选中态遮罩在主轴上两端各让出的内缩量（px）。
///
/// 遮罩宽度原本等于整个药丸槽宽，两端各只剩 [pillGap]（4px）与相邻项分隔，
/// 视觉上「遮罩左右间距过小」（用户反馈）。内缩 3px 后相邻间距约 7px；
/// 药丸内容自身还有内边距，选中图标不会被挤到。
const double kMobileNavMaskInset = 3.0;

/// 遮罩内缩后的实际宽度（下限 8，避免极小槽宽算出负值触发断言）。
double mobileNavMaskWidth(double itemW) {
  final w = itemW - kMobileNavMaskInset * 2;
  return w < 8 ? 8 : w;
}

/// 竖排（导轨）形态下的遮罩长度：主轴变成纵轴，同一条内缩规则。
double mobileNavMaskExtent(double itemExtent) {
  final v = itemExtent - kMobileNavMaskInset * 2;
  return v < 8 ? 8 : v;
}

/// OCLiquidGlass 静态 settings：dark/light 差异化由 tint/shadow 承担，
/// 这样所有 build 都使用同一份 const 实例，避免每次新建 settings 触发
/// shader uniform 重置（移动端表现为液态玻璃"来回跳跃"闪烁）。
// 液态玻璃 settings 统一用 liquid_glass_fallback.kLiquidGlassSettings（全应用唯一一份
// const 基准实例，与顶部药丸 / 卡片同源，避免多份重复常量漂移）：实例恒定，就不会因为
// build 重新下发 shader uniform（这是液态玻璃「来回跳跃」闪烁的根因）。

/// navStyle 感知的玻璃外壳：把 [child] 按「菜单栏样式」四值套上外皮——
/// theme/gray 直出、blur 高斯模糊、liquid GPU 液态玻璃（无 Impeller 时回退）。
/// 侧边导轨与子页面切换栏共用。
/// 竖排导轨（左 / 右菜单栏）胶囊的**宽度**。
///
/// 公开出来的原因：AppShell 用「恒定 Stack + 位置参数」摆放导航（见 app.dart），
/// 内容区必须按 [NavGlassShell.shellPadding] + 本宽度让出左侧 / 右侧空间。
/// 这个值与 `buildRailBar` 里胶囊的实际宽度**必须**是同一个来源 —— 各写一份
/// 迟早漂移成「导轨压住内容」或「内容区左边多出一条缝」。
const double kMobileNavRailExtent = 60.0;

class NavGlassShell extends StatelessWidget {
  final NavGlassPal pal;

  /// 胶囊圆角（一般 = 栏高一半）
  final double radius;

  /// OCLiquidGlass 的 key 前缀：同屏多实例（如主导航 + 弹层内切换栏）时防 key 冲突
  final String keyPrefix;

  /// 菜单栏摆放位置：决定外壳四周「让出哪一边的安全区」。子页面切换栏
  /// （MobileNavStyleTabBar）恒在底部，故默认值即其原有行为。
  final MobileNavPlacement placement;

  /// Optional exact margins for hosted tab-bar layouts.
  final EdgeInsets? padding;
  final Widget child;

  const NavGlassShell({
    super.key,
    required this.pal,
    required this.radius,
    required this.keyPrefix,
    this.placement = MobileNavPlacement.bottom,
    this.padding,
    required this.child,
  });

  /// 外壳内边距。
  ///
  /// * 底部形态：左右安全区 + 24，上 6，底部安全区 + 8；
  /// * 左侧导轨：把「让出贴屏那一侧」的规则原样搬到左边 → (左安全区 + 8, 14, 8, 14)；
  /// * 右侧导轨：镜像到右边 → (8, 14, 右安全区 + 8, 14)。
  ///
  /// 注意竖排时**纵向不再吃底部安全区**：导轨与内容并排，底部有安全区的设备
  /// （横屏刘海机、带 Home 指示条的平板）该由页面内容自己去避让，导轨若也跟着
  /// 缩进会在底端留下空隙，看起来像「导轨没贴到底」。
  static EdgeInsets shellPadding(
    EdgeInsets safe,
    MobileNavPlacement placement,
  ) {
    switch (placement) {
      case MobileNavPlacement.left:
        return EdgeInsets.fromLTRB(safe.left + 8, 14, 8, 14);
      case MobileNavPlacement.right:
        return EdgeInsets.fromLTRB(8, 14, safe.right + 8, 14);
      case MobileNavPlacement.bottom:
        return EdgeInsets.fromLTRB(
          safe.left + MobileUi.navInsetH,
          6,
          safe.right + MobileUi.navInsetH,
          safe.bottom + MobileUi.navBottomGap,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final look = navGlassLook(scheme, isDark, pal);
    // 模糊 σ 来自「设置 → 样式 → 玻璃细节 → 模糊度」（默认 16，与改动前一致），
    // 桌面端由 effectiveGlassSigma 钳到 ≤8；是否走 shader 由
    // gpuGlassEnabledOf 统一判定（PC 端默认关闭）。
    final GlassTuning tuning = pal.tuning;
    final double shellSigma = effectiveGlassSigma(tuning.blur);
    final EdgeInsets shellPad =
        padding ?? shellPadding(MediaQuery.of(context).padding, placement);
    final op = pal.op.clamp(0.0, 1.0);
    // 「样式 → 添加边框」：给导航/切换栏胶囊叠一条同圆角描边。
    // 只包 child 而不是整个 build：外壳外面还有一层「栏内边距」（底部形态是
    // (14, 2, 14, 底部安全区 + 8)，由 [shellPadding] 按 placement 给出），
    // 描边必须贴合胶囊本体而不是含内边距的外框；关闭时原样返回 child，
    // 零额外层级，与改动前像素一致。
    final Widget borderedChild = withConfigurableBorder(
      context,
      child,
      radius: BorderRadius.circular(radius),
    );

    // theme/gray：纯色药丸（无玻璃光效）
    if (look.solid) {
      return Padding(padding: shellPad, child: borderedChild);
    }

    if (isMobilePlatform) {
      return Padding(
        padding: shellPad,
        child: MobileGlassSurface(
          borderRadius: BorderRadius.circular(radius),
          tuning: tuning,
          opacity: op,
          liquid: look.style != SurfaceStyle.blur,
          accent: pal.follow && pal.useThemeColor
              ? themedGlassBase(scheme, pal.tone, true, second: pal.second)
              : null,
          child: borderedChild,
        ),
      );
    }

    // blur：扁平高斯模糊（无 3D 液态光效），遮罩为实心主题色
    if (look.style == SurfaceStyle.blur) {
      return Padding(
        padding: shellPad,
        // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            // σ 由「玻璃细节 → 模糊度」控制（Windows 上已由 effectiveGlassSigma 钳制）
            filter: cachedGlassBlur(shellSigma),
            child: CustomPaint(
              // 高光 / 边缘光：与卡片、药丸共用同一支画笔
              painter: LiquidGlassPainter(
                borderRadius: BorderRadius.circular(radius),
                opacity: op,
                highlight: tuning.highlight,
                lightPos: tuning.lightPos,
                edge: tuning.edge,
              ),
              child: borderedChild,
            ),
          ),
        ),
      );
    }

    // liquid：oc_liquid_glass 液态玻璃（GPU fragment shader）。
    // 走 shader 的条件 = 引擎支持（Impeller）且（移动端 || 设置里显式开启 PC GPU
    // 玻璃）—— 桌面默认关闭：shader backdrop 的纹理取向/坐标空间在桌面后端不一致
    // （用户反馈「PC 玻璃背景倒置且不是壁纸」）；无 Impeller（Windows 默认 Skia）
    // 时也走这里 → 回退为高斯模糊 + 倒角高光，避免 shader backdrop 被整体跳过、
    // 底部导航玻璃整块消失。
    if (!gpuGlassEnabledOf(context)) {
      return Padding(
        padding: shellPad,
        // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
        child: LiquidGlassBackdrop(
          borderRadius: BorderRadius.circular(radius),
          // σ 由「玻璃细节 → 模糊度」控制（Windows 上已由 effectiveGlassSigma 钳制）
          sigma: shellSigma,
          opacity: op,
          shadow: BoxShadow(
            color: Colors.black.withAlpha(isDark ? 70 : 26),
            blurRadius: 22,
            offset: const Offset(0, 6),
          ),
          child: borderedChild,
        ),
      );
    }

    // 关键修复（沿用主底部导航的防闪烁策略）：
    // 1) settings 用 kLiquidGlassSettings（全应用唯一 const 实例），避免每次
    //    build 新建 settings 触发 shader uniform 重置；
    // 2) OCLiquidGlassGroup 用 ValueKey(NavGlassPal)，仅玻璃配置变化才重建节点；
    // 3) OCLiquidGlass 独立 key（带 keyPrefix 防多实例冲突）；
    // Keep the live backdrop in the parent scene instead of a cached boundary.
    return OCLiquidGlassGroup(
      key: ValueKey<NavGlassPal>(pal),
      // 参数化 settings（带实例缓存，参数不变即复用同一实例，避免 uniform 重置）
      settings: liquidGlassSettingsFor(tuning),
      child: Padding(
        padding: shellPad,
        child: OCLiquidGlass(
          key: ValueKey<String>('${pal.hashCode}_${keyPrefix}_inner'),
          borderRadius: radius,
          color: look.tint,
          shadow: BoxShadow(
            color: Colors.black.withAlpha(isDark ? 70 : 26),
            blurRadius: 22,
            offset: const Offset(0, 6),
          ),
          child: borderedChild,
        ),
      ),
    );
  }
}

/// Optional vertical navigation rail for wide mobile layouts. The bottom bar
/// is provided by `liquid_glass_tab_bar`.
class MobileNavRail extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 导轨摆放位置。由 app.dart 用
  /// `resolveMobileNavPlacement(config.mobileNavPlacement, 屏宽, 屏高)` 解析后下发
  /// —— 判定逻辑只此一份，导航栏本身不做平台/尺寸判定。
  final MobileNavPlacement placement;

  /// 可选：主界面 PageView 的控制器。传入后遮罩在「页面滑动中」会连续跟随
  /// PageView 的实时位置（0.0~3.0 的小数页），而不是等 onPageChanged 按整页
  /// 跳变 —— 修复从第 1 页快速滑到第 4 页时遮罩在第 3 项短暂停留再跳走的
  /// 「动画跳跃」问题。仅遮罩子树订阅该 Listenable，每帧重建成本极小。
  final PageController? pageController;

  const MobileNavRail({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.placement,
    this.pageController,
  }) : assert(placement != MobileNavPlacement.bottom);

  @override
  State<MobileNavRail> createState() => _MobileNavRailState();
}

class _MobileNavRailState extends State<MobileNavRail> {
  /// 是否竖排导轨（左 / 右）：横排与竖排共用同一套「主轴线位置」状态
  /// （[_dragX] = 主轴线上的遮罩中心、[itemExtent] = 每个药丸在主轴上的长度），
  /// 只有轴向映射与手势类型不同。
  bool get _vertical => widget.placement != MobileNavPlacement.bottom;

  /// 拖动中遮罩中心在**主轴线**上的位置（相对 bar 内容区；横排 = 水平 dx、
  /// 竖排 = 垂直 dy；null = 未在拖动）。
  ///
  /// 用 ValueNotifier 而非 State 字段：拖动期间 `onLongPressMoveUpdate` /
  /// `onHorizontalDragUpdate` 以 60–120Hz 触发，若走 setState 会重建整个
  /// 导航栏（含 OCLiquidGlassGroup / OCLiquidGlass 的 GPU shader 组件），
  /// 造成 shader uniform 重置与移动端掉帧。改为只让遮罩定位子树订阅。
  final ValueNotifier<double?> _dragX = ValueNotifier<double?>(null);

  /// 拖动开始时手指相对遮罩中心的偏移：抓取点不跳变。
  double _dragGrabOffset = 0;

  /// 长按手势是否已接管拖动（接管后 horizontalDrag 的 cancel 不得复位遮罩，
  /// 否则遮罩会先跳回旧选中项、再被长按移动拉回，出现可见的双吸附抖动）。
  bool _longPressActive = false;

  /// 遮罩位置相关的「页面侧」变化信号：PageView 位置变化 + 滚动活动开始/结束。
  /// 用 `ValueNotifier<int>`（而不是 setState）只让遮罩子树重建 —— 页面滑动期间
  /// 每帧都会变，重建整条导航栏（含 OCLiquidGlassGroup 的 shader 组件）代价太大。
  final ValueNotifier<int> _pageTick = ValueNotifier<int>(0);

  /// 当前绑定的 PageView 滚动位置（PageView 尚未 attach 时为 null）。
  ScrollPosition? _pagePosition;

  /// 是否处于「手指拖菜单栏松手后」的吸附窗口：这段时间内即使 PageView 收到
  /// 程序驱动的 animateToPage（app.dart 的 _selectMobileNav 紧接着就会调用它），
  /// 遮罩也必须用 260ms 从松手点吸附到目标药丸，不能改成跟随页面 —— 否则会先
  /// 弹回旧页面位置再跟着页面走（用户反馈的「弹一下才移动」）。页面停稳后自动清除。
  bool _releasedFromDrag = false;

  bool get _pageIsScrolling =>
      _pagePosition?.isScrollingNotifier.value ?? false;

  /// 绑定 / 解绑 pageController 的 ScrollPosition（幂等，可在 build 中安全调用）。
  /// 之所以要拿 position：需要 isScrollingNotifier 判断「PageView 是否真的在滑动」，
  /// 这是区分「跟随页面」与「吸附到选中项」的唯一可靠信号（只看 pc.page 是否为
  /// 小数做不到，见 _buildMaskFor 的注释）。
  void _syncPagePosition() {
    final pc = widget.pageController;
    final pos = (pc != null && pc.hasClients) ? pc.position : null;
    if (identical(pos, _pagePosition)) return;
    _pagePosition?.isScrollingNotifier.removeListener(_onPageSideChanged);
    _pagePosition?.removeListener(_onPageSideChanged);
    _pagePosition = pos;
    _pagePosition?.isScrollingNotifier.addListener(_onPageSideChanged);
    _pagePosition?.addListener(_onPageSideChanged);
    // 注意：此处可能发生在 build 中，不能 _pageTick.value++（那会在 build 期间触发
    // 监听者 setState）；本次 build 的遮罩子树紧接着就会用新绑定重算位置。
  }

  void _onPageSideChanged() => _pageTick.value++;

  @override
  void initState() {
    super.initState();
    // 首次进入主界面即预加载 oc_liquid_glass 的 fragment shader，
    // 避免底部导航第一次渲染时的异步加载闪烁。
    // 与 main.dart 的 shader 预热走同一条门控：shaderGlassSupported 为 false 时
    // 玻璃渲染永远走不到 shader 分支（gpuGlassEnabledOf 已 gate），但这次调用
    // 仍会真的加载并编译一份用不到的 SkSL 运行时效应 —— 白占内存，直接跳过。
    if (shaderGlassSupported) OCLiquidGlassGroup.precacheShader();
  }

  @override
  void dispose() {
    _dragX.dispose();
    _pagePosition?.isScrollingNotifier.removeListener(_onPageSideChanged);
    _pagePosition?.removeListener(_onPageSideChanged);
    _pagePosition = null;
    _pageTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 幂等同步 PageView 的 ScrollPosition（首帧布局后才 attach，之后同实例直接返回）。
    _syncPagePosition();
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

    final items = <(TablerGlyph, String)>[
      (TablerGlyph.movie, s.navProjects),
      (TablerGlyph.listDetails, s.navQueue),
      (TablerGlyph.folders, lang == 'zh' ? '配置库' : 'Configs'),
      (TablerGlyph.settings, s.navSettings),
    ];

    // 页面索引映射：0=项目, 1=队列, 2=配置库, 3=设置
    const pageToItem = {0: 0, 1: 1, 2: 2, 3: 3};
    const itemToPage = {0: 0, 1: 1, 2: 2, 3: 3};
    final itemIdx = pageToItem[widget.selectedIndex] ?? 0;

    final itemContentHeight =
        27 + 1 + MediaQuery.textScalerOf(context).scale(9) * 1.1 + 8;
    final barHeight = (itemContentHeight + 8).clamp(60.0, double.infinity);
    final radius = barHeight / 2;
    final indicatorStyle = context.select<AppState, String>(
      (state) => state.config.selectionIndicatorStyle,
    );
    final highContrast = MediaQuery.highContrastOf(context);
    final selectedColor = highContrast || isMobilePlatform
        ? scheme.onSurface
        : indicatorStyle == 'theme'
        ? scheme.onSecondaryContainer
        : look.selectedColor;
    final unselectedColor = highContrast
        ? scheme.onSurface
        : look.unselectedColor;

    // 药丸间距：每个药丸之间留 4px 间隔
    const pillGap = 4.0;

    Widget buildRailBar() {
      const padding = EdgeInsets.all(4);
      return Container(
        width: kMobileNavRailExtent,
        padding: padding,
        decoration: BoxDecoration(
          color: style == SurfaceStyle.liquid ? Colors.transparent : look.tint,
          borderRadius: BorderRadius.circular(radius),
          border: look.borderWidth > 0
              ? Border.all(color: look.borderColor, width: look.borderWidth)
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Use the actual viewport after safe areas, the keyboard and the
            // glass shell. Keep the floating rail's regular size when it fits.
            const minItemExtent = 44.0;
            final regularItemExtent = itemContentHeight.clamp(
              54.0,
              double.infinity,
            );
            final totalGap = pillGap * (items.length - 1);
            final itemExtent =
                ((constraints.maxHeight - totalGap) / items.length)
                    .clamp(minItemExtent, regularItemExtent)
                    .toDouble();
            final totalExtent = itemExtent * items.length + totalGap;
            final scrolls = totalExtent > constraints.maxHeight + 0.01;
            const crossExtent = kMobileNavRailExtent - 8;

            void startDrag(double position) {
              final nearest = _nearestIndex(
                position,
                itemExtent,
                pillGap,
                items.length,
              );
              final center = _itemCenter(nearest, itemExtent, pillGap);
              _dragGrabOffset = position - center;
              _dragX.value = center;
            }

            void updateDrag(double position) {
              _dragX.value = (position - _dragGrabOffset).clamp(
                itemExtent / 2,
                totalExtent - itemExtent / 2,
              );
            }

            void endDrag() =>
                _endDrag(itemExtent, items.length, pillGap, itemToPage);

            return SingleChildScrollView(
              primary: false,
              // With clipped items a plain swipe scrolls the viewport. A
              // long press can still drag the selection, as in the full rail.
              physics: scrolls
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              child: SizedBox(
                height: totalExtent,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTapUp: (details) {
                    final index = _nearestIndex(
                      details.localPosition.dy,
                      itemExtent,
                      pillGap,
                      items.length,
                    );
                    widget.onSelected(itemToPage[index]!);
                  },
                  onLongPressStart: (details) {
                    _longPressActive = true;
                    startDrag(details.localPosition.dy);
                  },
                  onLongPressMoveUpdate: (details) =>
                      updateDrag(details.localPosition.dy),
                  onLongPressEnd: (_) {
                    _longPressActive = false;
                    endDrag();
                  },
                  onLongPressCancel: () {
                    _longPressActive = false;
                    _dragX.value = null;
                  },
                  onVerticalDragStart: scrolls
                      ? null
                      : (details) => startDrag(details.localPosition.dy),
                  onVerticalDragUpdate: scrolls
                      ? null
                      : (details) => updateDrag(details.localPosition.dy),
                  onVerticalDragEnd: scrolls ? null : (_) => endDrag(),
                  onVerticalDragCancel: scrolls
                      ? null
                      : () {
                          if (!_longPressActive) _dragX.value = null;
                        },
                  child: Stack(
                    children: [
                      _buildRailMask(
                        itemIdx,
                        itemExtent,
                        pillGap,
                        items.length,
                        scheme: scheme,
                        isDark: isDark,
                        style: style,
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) const SizedBox(height: pillGap),
                            SizedBox(
                              height: itemExtent,
                              child: _NavItem(
                                key: ValueKey(
                                  'mobile-rail-item-${itemToPage[i]}',
                                ),
                                glyph: items[i].$1,
                                label: items[i].$2,
                                selected: i == itemIdx,
                                selectedColor: selectedColor,
                                unselectedColor: unselectedColor,
                                maxWidth: crossExtent,
                                onActivate: () =>
                                    widget.onSelected(itemToPage[i]!),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    Widget buildBarIn() {
      // 竖排（左 / 右导轨）：走独立分支，横排代码保持原样
      if (_vertical) return buildRailBar();
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
          border: look.borderWidth > 0
              ? Border.all(color: look.borderColor, width: look.borderWidth)
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (ctx, cons) {
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
                _dragX.value = grabCenter;
              }),
              onLongPressMoveUpdate: (d) {
                _dragX.value = (d.localPosition.dx - _dragGrabOffset).clamp(
                  itemW / 2,
                  cons.maxWidth - itemW / 2,
                );
              },
              onLongPressEnd: (_) {
                _longPressActive = false;
                _endDrag(itemW, items.length, pillGap, itemToPage);
              },
              onLongPressCancel: () {
                _longPressActive = false;
                _dragX.value = null;
              },
              // ── 快速水平滑动（<500ms）：同样走拖动跟随 ──
              onHorizontalDragStart: (d) {
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
                _dragX.value = grabCenter;
              },
              onHorizontalDragUpdate: (d) {
                _dragX.value = (d.localPosition.dx - _dragGrabOffset).clamp(
                  itemW / 2,
                  cons.maxWidth - itemW / 2,
                );
              },
              onHorizontalDragEnd: (_) =>
                  _endDrag(itemW, items.length, pillGap, itemToPage),
              onHorizontalDragCancel: () {
                // 长按已接管时由长按流程收尾，这里不要复位遮罩（否则先跳回旧项）。
                if (_longPressActive) return;
                _dragX.value = null;
              },
              child: SizedBox(
                width: cons.maxWidth,
                height: cons.maxHeight,
                child: Stack(
                  children: [
                    // 滑动遮罩胶囊：切换菜单时在条目间平滑滑动；拖动时跟随手指；
                    // 页面滑动（PageView）中连续跟随页面位置（见 pageController），
                    // 不再「途经项停留后跳变」。
                    _buildMaskPositioned(
                      itemIdx,
                      itemW,
                      pillGap,
                      items.length,
                      scheme: scheme,
                      isDark: isDark,
                      style: style,
                    ),
                    // 药丸行：每个药丸之间有间距，crossAxisAlignment.stretch 让药丸填满高度
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0) const SizedBox(width: pillGap),
                          SizedBox(
                            width: itemW,
                            child: _NavItem(
                              glyph: items[i].$1,
                              label: items[i].$2,
                              selected: i == itemIdx,
                              selectedColor: selectedColor,
                              unselectedColor: unselectedColor,
                              maxWidth: itemW,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    // 外壳（solid 直出 / blur 高斯模糊 / liquid GPU 玻璃 + 回退）由
    // NavGlassShell 按 navStyle 统一套皮——与子页面切换栏共享同一实现。
    final Widget shell = NavGlassShell(
      pal: pal,
      radius: radius,
      keyPrefix: 'nav',
      // 竖排导轨时外壳内边距改为让「贴屏那一侧」的安全区（见 shellPadding）
      placement: widget.placement,
      child: buildBarIn(),
    );

    return shell;
  }

  /// 松手：吸附到「离遮罩中心最近」的药丸并切换页面。
  ///
  /// 修复双吸附抖动：旧实现先 `setState(_dragX = null)`（遮罩开始朝旧选中项
  /// 回放），再 onSelected 切页（遮罩二次朝新项移动），肉眼看到两段吸附；
  /// 且旧判定 `(dx-center).abs() < itemW/2` 在药丸 4px 缝隙处存在死区，
  /// 死区内全部不命中 → target 默认为 0（误跳回首页）。
  /// 现在：先切页（父组件同帧更新 selectedIndex），再复位拖动态；
  /// 目标用最近中心选取，无缝隙死区。
  void _endDrag(
    double itemW,
    int itemCount,
    double gap,
    Map<int, int> pageMap,
  ) {
    // 进入「吸附窗口」：app.dart 的 _selectMobileNav 会紧接着对该 PageView 调用
    // animateToPage，此时遮罩必须继续用 260ms 从松手点吸附到目标药丸，而不能切到
    // 「跟随页面」（否则会先弹回旧页面位置 —— 见 _buildMaskFor 的注释）。
    _releasedFromDrag = true;
    final dx = _dragX.value;
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
    _dragX.value = null;
  }

  /// 第 i 个药丸的左边缘位置（考虑间距）。
  double _itemLeft(int i, double itemW, double gap) => i * (itemW + gap);

  /// 第 i 个药丸的中心位置（考虑间距）。
  double _itemCenter(int i, double itemW, double gap) =>
      i * (itemW + gap) + itemW / 2;

  /// 构建遮罩胶囊的定位子树。
  ///
  /// 位置来源有三种，且**互斥**（这是「弹一下」的修复核心）：
  /// 1. 手指拖菜单栏（_dragX != null）：严格 1:1 跟随手指，时长 0；
  /// 2. PageView 正在滑动（isScrollingNotifier == true）且不处于「拖菜单栏松手后的
  ///    吸附窗口」：跟随 pc.page 的实时小数位置，时长 0 —— 与页面 1:1 同步；
  /// 3. 其余（静止 / 等待吸附）：260ms easeOutCubic 吸附到选中项。
  ///
  /// 为什么不能再按「pc.page 是否为小数」来切换：app.dart 点按菜单是
  /// 「先更新 selectedIndex，再 animateToPage」，中间存在一帧 pc.page 仍是整数：
  /// 那一帧遮罩会走 260ms 吸附、朝**新**选中项起步，下一帧 pc.page 变成小数又切回
  /// 跟随，于是被拉回**旧**页面位置再跟页面走 —— 肉眼就是「先弹一下才移动」。
  /// 现在改用「页面是否真的在滚动」判断，并让三个来源共用同一个 AnimatedPositioned
  /// （Element 复用不重建子树，ImplicitlyAnimatedWidget 还会用当前动画值作为新
  /// tween 起点，因此 拖动 → 吸附 的交接是连续的）。
  ///
  /// 仅此子树订阅 _dragX / _pageTick，页面滑动与拖动期间导航栏其余部分
  /// （药丸行、玻璃 shader 组件）不随每帧重建。
  Widget _buildMaskPositioned(
    int itemIdx,
    double itemW,
    double pillGap,
    int itemCount, {
    required ColorScheme scheme,
    required bool isDark,
    required String style,
  }) {
    return ValueListenableBuilder<double?>(
      valueListenable: _dragX,
      builder: (context, dragX, _) => ValueListenableBuilder<int>(
        valueListenable: _pageTick,
        builder: (context, _, _) => _buildMaskFor(
          dragX,
          itemIdx,
          itemW,
          pillGap,
          itemCount,
          scheme: scheme,
          isDark: isDark,
          style: style,
        ),
      ),
    );
  }

  Widget _buildMaskFor(
    double? dragX,
    int itemIdx,
    double itemW,
    double pillGap,
    int itemCount, {
    required ColorScheme scheme,
    required bool isDark,
    required String style,
  }) {
    final dragging = dragX != null;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final mask = AnimatedScale(
      // Deliberate tactile feedback while the user presses or drags the mask.
      scale: dragging && !reducedMotion ? 1.25 : 1.0,
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 150),
      curve: Curves.easeOutBack,
      child: isMobilePlatform
          ? const MobileGlassSelection(radius: 22)
          : const SelectionHighlight(radius: 22),
    );

    // 退出「拖菜单栏松手后的吸附窗口」的条件：PageView 已停稳且停在选中项上
    // （页面若根本没动 —— 例如点按当前项 —— 本次 build 就会清除）。
    if (_releasedFromDrag) {
      final pc = widget.pageController;
      final p = (pc != null && pc.hasClients) ? pc.page : null;
      if (!_pageIsScrolling && (p == null || (p - itemIdx).abs() <= 0.01)) {
        _releasedFromDrag = false;
      }
    }

    // 位置来源①：跟随手指（时长 0）
    double? followLeft;
    if (dragging) {
      followLeft = dragX - itemW / 2;
    } else if (!_releasedFromDrag && _pageIsScrolling) {
      // 位置来源②：跟随 PageView。用户拖页面、松手后的惯性吸附、以及点按菜单后的
      // animateToPage 都与页面实时位置 1:1（不再与吸附动画互相覆盖或抖动）。
      final pc = widget.pageController;
      final p = (pc != null && pc.hasClients) ? pc.page : null;
      if (p != null) {
        // PageView 的下标空间与菜单项序号同序（app.dart 的 _kMobileNavOrder
        // = [0,1,2,3]，正好是 4 个 Tab 的 PageView 下标），故可直接按项宽定位。
        followLeft = p.clamp(0.0, itemCount - 1).toDouble() * (itemW + pillGap);
      }
    }

    // 位置来源③：吸附（260ms）。follow 分支用 Duration.zero —— AnimationController
    // 对 0 时长直接赋值（_animateToInternal 的 simulationDuration == Duration.zero
    // 分支），因此就是逐帧 1:1 跟随，不会引入一帧延迟。
    return AnimatedPositioned(
      duration: reducedMotion || followLeft != null
          ? Duration.zero
          : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      // 左右各内缩 kMobileNavMaskInset：遮罩不再顶到相邻项
      left:
          (followLeft ?? _itemLeft(itemIdx, itemW, pillGap)) +
          kMobileNavMaskInset,
      top: 2,
      bottom: 2,
      width: mobileNavMaskWidth(itemW),
      child: mask,
    );
  }

  /// 主轴上离 [pos] 最近的药丸序号。横排的「点按 / 长按 / 滑动起点」三处
  /// 都是这个公式（只是喂 dx），竖排复用同一份，避免两份判定漂移。
  int _nearestIndex(double pos, double extent, double gap, int count) {
    var nearest = 0;
    var best = double.infinity;
    for (var i = 0; i < count; i++) {
      final d = (pos - _itemCenter(i, extent, gap)).abs();
      if (d < best) {
        best = d;
        nearest = i;
      }
    }
    return nearest;
  }

  /// 竖排导轨的遮罩定位子树 —— 与横排 [_buildMaskFor] 同一套「三来源」策略
  /// （① 跟手 ② 跟随 PageView ③ 260ms 吸附），只把 `left + width` 换成
  /// `top + height`，因此「拖动 → 吸附」的交接动画与横排完全一致。
  ///
  /// 直接复用 [_dragX] / [_pageTick] / [_releasedFromDrag] / [_pageIsScrolling]：
  /// 任一时刻树上只有一个形态，两套定位不会互相干扰；遮罩本身也仍是同一个
  /// [SelectionHighlight]（材质跟随独立的 selectionIndicatorStyle）。
  Widget _buildRailMask(
    int itemIdx,
    double itemExtent,
    double gap,
    int itemCount, {
    required ColorScheme scheme,
    required bool isDark,
    required String style,
  }) {
    return ValueListenableBuilder<double?>(
      valueListenable: _dragX,
      builder: (context, dragPos, _) => ValueListenableBuilder<int>(
        valueListenable: _pageTick,
        builder: (context, _, _) {
          final dragging = dragPos != null;
          final reducedMotion = MediaQuery.disableAnimationsOf(context);
          final mask = AnimatedScale(
            scale: dragging && !reducedMotion ? 1.25 : 1.0,
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 150),
            curve: Curves.easeOutBack,
            child: isMobilePlatform
                ? const MobileGlassSelection(radius: 22)
                : const SelectionHighlight(radius: 22),
          );

          // 退出「拖菜单栏松手后的吸附窗口」的判定与横排一致：页面已停稳且
          // 停在选中项上即退出（页面若根本没动，本次 build 就会清除）。
          if (_releasedFromDrag) {
            final pc = widget.pageController;
            final p = (pc != null && pc.hasClients) ? pc.page : null;
            if (!_pageIsScrolling &&
                (p == null || (p - itemIdx).abs() <= 0.01)) {
              _releasedFromDrag = false;
            }
          }

          // 位置来源①：跟随手指（时长 0）
          double? followTop;
          if (dragging) {
            followTop = dragPos - itemExtent / 2;
          } else if (!_releasedFromDrag && _pageIsScrolling) {
            // 位置来源②：跟随 PageView。PageView 仍是横向翻页，但菜单项序号与
            // 页序号同序（app.dart 的 _kMobileNavOrder），故可直接按主轴位移映射
            // —— 左右拖页面时，竖排导轨的遮罩同样跟着实时位置走。
            final pc = widget.pageController;
            final p = (pc != null && pc.hasClients) ? pc.page : null;
            if (p != null) {
              followTop =
                  p.clamp(0.0, itemCount - 1).toDouble() * (itemExtent + gap);
            }
          }

          // 位置来源③：吸附（260ms）。follow 分支用 Duration.zero —— 逐帧 1:1
          // 跟随，不引入一帧延迟（与横排同一实现）。
          return AnimatedPositioned(
            duration: reducedMotion || followTop != null
                ? Duration.zero
                : const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            // 上下各内缩 kMobileNavMaskInset：与横排同一条间距规则，
            // 竖排导轨的遮罩不再顶着相邻药丸
            top:
                (followTop ?? _itemLeft(itemIdx, itemExtent, gap)) +
                kMobileNavMaskInset,
            left: 2,
            right: 2,
            height: mobileNavMaskExtent(itemExtent),
            child: mask,
          );
        },
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final TablerGlyph glyph;
  final String label;
  final bool selected;
  final Color selectedColor;
  final Color unselectedColor;
  final double maxWidth;
  final VoidCallback? onActivate;

  const _NavItem({
    super.key,
    required this.glyph,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.maxWidth,
    this.onActivate,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _showFocus = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected
        ? widget.selectedColor
        : widget.unselectedColor;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final scheme = Theme.of(context).colorScheme;
    final highContrast = MediaQuery.highContrastOf(context);
    final focusColor = highContrast
        ? (scheme.brightness == Brightness.dark ? Colors.white : Colors.black)
        : scheme.onSurface;
    // Rail slots grow with text size; long labels truncate without shrinking.
    final content = Tooltip(
      message: widget.label,
      child: Center(
        child: SizedBox(
          width: widget.maxWidth,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: color),
            duration: duration,
            builder: (context, color, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TablerIcon(widget.glyph, size: 27, color: color),
                const SizedBox(height: 1),
                Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: color,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // The rail's GestureDetector still handles pointer tap, long press and drag.
    final activate = widget.onActivate;
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      label: widget.label,
      onTap: activate,
      child: activate == null
          ? ExcludeSemantics(child: content)
          : FocusableActionDetector(
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    activate();
                    return null;
                  },
                ),
                ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
                  onInvoke: (_) {
                    activate();
                    return null;
                  },
                ),
              },
              onShowFocusHighlight: (show) => setState(() => _showFocus = show),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ExcludeSemantics(child: content),
                  if (_showFocus)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: DecoratedBox(
                            key: const ValueKey('mobile-rail-focus-ring'),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: focusColor,
                                width: highContrast ? 3 : 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
