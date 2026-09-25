import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../platform/app_platform.dart';
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
      other.second == second &&
      other.follow == follow &&
      other.tuning == tuning &&
      other.tone == tone;

  @override
  int get hashCode =>
      Object.hash(style, op, primary, second, follow, tuning, tone);
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
      : ((op * 255) * pal.tuning.tintScale).round().clamp(0, 255);
  // 主题色基底：跟随主题色 / 玻璃遵循主题色时都用「与表面色混合后的协调色」，
  // 避免 scheme.primary（暗色下 tone 80）大面积铺开过亮；
  // 灰色样式额外去饱和，保证是真正的中性灰（原有 fromSeed 种子色偏）。
  final accent = harmonizedAccent(scheme, pal.tone);
  final baseColor = style == SurfaceStyle.theme
      ? accent
      : style == SurfaceStyle.gray
          ? neutralGray(scheme.surfaceContainerHigh)
          : (pal.follow ? accent : scheme.surface);
  // 边缘光 → 描边的透明度/线宽缩放（基准 1.0 = 与改动前一致）
  final edgeBlur = edgeBorder(70 / 255, 0.5, pal.tuning.edge);
  final edgeWhite = edgeBorder(isDark ? 0.16 : 0.32, 0.7, pal.tuning.edge);
  return NavGlassLook(
    style: style,
    solid: solid,
    tint: baseColor.withAlpha(baseAlpha),
    borderColor: style == SurfaceStyle.blur
        ? scheme.outlineVariant.withAlpha((edgeBlur.alpha * 255).round().clamp(0, 255))
        : Colors.white.withValues(alpha: edgeWhite.alpha),
    borderWidth: style == SurfaceStyle.blur ? edgeBlur.width : edgeWhite.width,
    // 遮罩已改为「完全透明 + 中性描边」（见 navMaskPill），选中态由图标/文字
    // 颜色表达：blur/liquid/gray 用主题色或 onSurface（透明底上需要足够的
    // 图标对比度，onPrimary 白在无实心底时会看不清）；theme 底栏本身即主题色，
    // 选中项继续用 onPrimary 反白。
    selectedColor: style == SurfaceStyle.theme
        ? scheme.onPrimary
        : style == SurfaceStyle.gray
            ? scheme.onSurface
            : scheme.primary,
    unselectedColor: scheme.onSurfaceVariant,
  );
}

/// 遮罩胶囊外观（用户反馈定稿）：**完全透明**填充 + 中性描边，不引入任何主题色。
///
/// 旧实现按样式分化：blur=实心主题色、theme=白色高亮、gray=中性高亮、
/// liquid=白→主题色渐变 —— 用户反馈「难看、受主题色干扰」；且各样式都带
/// offset(0,2) 的投影，视觉上胶囊「往下坠」，对称性差。
/// 现在统一改为：透明填充 + 一条中性（暗色白 / 亮色黑）发丝描边 + 无阴影，
/// 选中态完全交给图标/文字颜色（[NavGlassLook.selectedColor]）表达。
/// [style] 参数保留在签名里（调用方语义不变、未来若要按样式微调描边不用改调用点）。
Widget navMaskPill(ColorScheme scheme, bool isDark, String style) {
  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      color: Colors.transparent,
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.30)
            : Colors.black.withValues(alpha: 0.14),
        width: 1.0,
      ),
    ),
  );
}

/// OCLiquidGlass 静态 settings：dark/light 差异化由 tint/shadow 承担，
/// 这样所有 build 都使用同一份 const 实例，避免每次新建 settings 触发
/// shader uniform 重置（移动端表现为液态玻璃"来回跳跃"闪烁）。
// 液态玻璃 settings 统一用 liquid_glass_fallback.kLiquidGlassSettings（全应用唯一一份
// const 基准实例，与顶部药丸 / 卡片同源，避免多份重复常量漂移）：实例恒定，就不会因为
// build 重新下发 shader uniform（这是液态玻璃「来回跳跃」闪烁的根因）。

/// navStyle 感知的玻璃外壳：把 [child] 按「底部菜单栏样式」四值套上外皮——
/// theme/gray 直出、blur 高斯模糊、liquid GPU 液态玻璃（无 Impeller 时回退）。
/// 主底部导航与子页面切换栏共用，保证子页面底栏与全局导航观感一致。
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
  final Widget child;

  const NavGlassShell({
    super.key,
    required this.pal,
    required this.radius,
    required this.keyPrefix,
    this.placement = MobileNavPlacement.bottom,
    required this.child,
  });

  /// 外壳内边距。
  ///
  /// * 底部形态：(14, 2, 14, **底部安全区 + 8**) —— 与改动前逐像素一致；
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
        return EdgeInsets.fromLTRB(14, 2, 14, safe.bottom + 8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final look = navGlassLook(scheme, isDark, pal);
    // 模糊 σ 来自「设置 → 样式 → 玻璃细节 → 模糊度」（默认 16，与改动前一致），
    // Windows 上由 effectiveGlassSigma 钳到 ≤12；是否走 shader 由
    // gpuGlassEnabledOf 统一判定（PC 端默认关闭）。
    final GlassTuning tuning = pal.tuning;
    final double shellSigma = effectiveGlassSigma(tuning.blur);
    final EdgeInsets shellPad =
        shellPadding(MediaQuery.of(context).padding, placement);
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
      return Padding(
        padding: shellPad,
        child: borderedChild,
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
    // 4) RepaintBoundary 放在 OCLiquidGlassGroup 外部隔离重绘。
    return RepaintBoundary(
      child: OCLiquidGlassGroup(
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
      ),
    );
  }
}

/// 移动端主导航栏 —— 样式由「底部菜单栏样式」（AppConfig.navStyle）接管，
/// **位置**由 [MobileBottomNav.placement] 接管（底部胶囊 / 左右竖排导轨）。
///
/// - 整体是一颗悬浮「药丸」（胶囊）；四种样式：
///   liquid 液态玻璃（oc_liquid_glass GPU shader）、blur 扁平高斯模糊
///   （BackdropFilter）、theme 跟随主题色（纯色）、gray 灰色（纯色）；
/// - 选中项使用胶囊「药丸」指示器；按下拖动（无需长按）遮罩即跟随手指，
///   松手吸附到最近药丸并切换页面；点按直接切换（带滑动动画）；
/// - 位置：默认 [MobileNavPlacement.bottom]（悬浮底部，与改动前逐像素一致）。
///   宽屏移动端（平板 / 横屏）或用户在设置里强制指定时，变为
///   [MobileNavPlacement.left] / [MobileNavPlacement.right] 的**竖排导轨**：
///   药丸行改竖排、拖动轴换成纵轴、遮罩按纵轴定位、外壳让出「贴屏那一侧」的
///   安全区（见 NavGlassShell.shellPadding）。
/// - 遵循设置→主题→样式→底部菜单栏样式（navStyle 四值）。
class MobileBottomNav extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  /// 菜单栏摆放位置。由 app.dart 用
  /// `resolveMobileNavPlacement(config.mobileNavPlacement, 屏宽, 屏高)` 解析后下发
  /// —— 判定逻辑只此一份，导航栏本身不做平台/尺寸判定。
  final MobileNavPlacement placement;
  /// 可选：主界面 PageView 的控制器。传入后遮罩在「页面滑动中」会连续跟随
  /// PageView 的实时位置（0.0~3.0 的小数页），而不是等 onPageChanged 按整页
  /// 跳变 —— 修复从第 1 页快速滑到第 4 页时遮罩在第 3 项短暂停留再跳走的
  /// 「动画跳跃」问题。仅遮罩子树订阅该 Listenable，每帧重建成本极小。
  final PageController? pageController;
  /// 滑动自动收起：true = 整条菜单栏滑出屏幕下缘（仅底部形态由 app.dart 下发；
  /// 侧边导轨恒为 false）。动画由 [_MobileBottomNavState] 的弹簧模拟驱动，
  /// 到位后带一次过冲回弹。
  final bool hidden;

  const MobileBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.placement = MobileNavPlacement.bottom,
    this.pageController,
    this.hidden = false,
  });

  @override
  State<MobileBottomNav> createState() => _MobileBottomNavState();
}

class _MobileBottomNavState extends State<MobileBottomNav>
    with SingleTickerProviderStateMixin {
  /// 滑动自动收起动画：0 = 展开、1 = 完全收起（欠阻尼弹簧驱动，过冲量即
  /// 「到位后回弹」）。Transform.translate 只改绘制不改布局，收起全程不会
  /// 触发 PageView / 玻璃外壳重新布局。
  late final AnimationController _hideCtrl;
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

  bool get _pageIsScrolling => _pagePosition?.isScrollingNotifier.value ?? false;

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
    // late 注入必须在 initState 首行完成（项目契约 7）。
    _hideCtrl = AnimationController(
      vsync: this,
      value: widget.hidden ? 1.0 : 0.0,
    );
    // 首次进入主界面即预加载 oc_liquid_glass 的 fragment shader，
    // 避免底部导航第一次渲染时的异步加载闪烁。
    // 与 main.dart 的 shader 预热走同一条门控：shaderGlassSupported 为 false 时
    // 玻璃渲染永远走不到 shader 分支（gpuGlassEnabledOf 已 gate），但这次调用
    // 仍会真的加载并编译一份用不到的 SkSL 运行时效应 —— 白占内存，直接跳过。
    if (shaderGlassSupported) OCLiquidGlassGroup.precacheShader();
  }

  @override
  void didUpdateWidget(covariant MobileBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hidden == widget.hidden) return;
    // 欠阻尼弹簧（ratio < 1）：到达目标值时过冲再回落 = 用户要求的
    // 「移动到指定位置后回弹」。刚度 260 ≈ 300ms 内完成主行程。
    _hideCtrl.animateWith(SpringSimulation(
      SpringDescription.withDampingRatio(mass: 1, stiffness: 260, ratio: 0.55),
      _hideCtrl.value,
      widget.hidden ? 1.0 : 0.0,
      _hideCtrl.velocity,
    ));
  }

  @override
  void dispose() {
    _dragX.dispose();
    _pagePosition?.isScrollingNotifier.removeListener(_onPageSideChanged);
    _pagePosition?.removeListener(_onPageSideChanged);
    _pagePosition = null;
    _pageTick.dispose();
    // 若 initState 之前就抛错，_hideCtrl 可能未被注入（契约 7：dispose 访问
    // late 字段必须 try/catch）。
    try {
      _hideCtrl.dispose();
    } catch (_) {}
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

    const barHeight = 60.0;
    const radius = barHeight / 2;
    final selectedColor = look.selectedColor;
    final unselectedColor = look.unselectedColor;

    // 药丸间距：每个药丸之间留 4px 间隔
    const pillGap = 4.0;

    // ── 竖排导轨（左 / 右）────────────────────────────────────────────────
    //
    // 与横排**完全独立**的构建分支：横排分支一字未改（底部形态是绝大多数用户
    // 的形态，不能为了竖排把它的像素、手势、遮罩动画改坏）。竖排复用同一套
    // 「主轴线」状态与吸附逻辑（_dragX / _itemCenter / _endDrag），只把
    // dx↔dy、Row↔Column、宽↔高对调，因此两种形态的选中反馈完全一致。
    //
    // 尺寸：短边（屏幕上的宽度）与底部形态的栏高同为 60；每项在主轴（纵轴）上
    // 固定 54，**不撑满可用高度** —— 导轨是一颗悬浮胶囊，拉满整屏高会退化成像
    // 素系统侧边栏，与现有玻璃语言不符；内容总高由药丸数决定，再由外层 Row 的
    // 交叉轴对齐把它居中。
    Widget buildRailBar() {
      // 宽度取自文件级常量：AppShell 要让出同宽给内容区（见 kMobileNavRailExtent）
      const barExtent = kMobileNavRailExtent;
      // 圆角直接用外层的 radius（= 栏高 60 / 2），两处同为 30，不重复声明
      const itemExtent = 54.0;
      // 交叉轴可用宽度 = 短边 − 上下各 4px 内边距（与横排的 padding 对称）
      const crossExtent = barExtent - 8;
      final totalMain =
          itemExtent * items.length + pillGap * (items.length - 1);
      return Container(
        width: barExtent,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          // 与横排同一条规则：liquid 的 tint 由 OCLiquidGlass 承担，内层不再叠色
          color: style == SurfaceStyle.liquid ? Colors.transparent : look.tint,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: look.borderColor, width: look.borderWidth),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: totalMain,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // ── 点按：切到纵轴上最近的药丸（与横排同一套「最近中心」判定） ──
            onTapUp: (d) => widget.onSelected(itemToPage[_nearestIndex(
                    d.localPosition.dy, itemExtent, pillGap, items.length)] ??
                0),
            // ── 长按：遮罩放大反馈 + 抓取，随后跟随手指 ──
            onLongPressStart: (d) => setState(() {
              _longPressActive = true;
              final nearest = _nearestIndex(
                  d.localPosition.dy, itemExtent, pillGap, items.length);
              final grabCenter = _itemCenter(nearest, itemExtent, pillGap);
              _dragGrabOffset = d.localPosition.dy - grabCenter;
              _dragX.value = grabCenter;
            }),
            onLongPressMoveUpdate: (d) {
              _dragX.value = (d.localPosition.dy - _dragGrabOffset)
                  .clamp(itemExtent / 2, totalMain - itemExtent / 2);
            },
            onLongPressEnd: (_) {
              _longPressActive = false;
              _endDrag(itemExtent, items.length, pillGap, itemToPage);
            },
            onLongPressCancel: () {
              _longPressActive = false;
              _dragX.value = null;
            },
            // ── 纵向快速滑动：同样走拖动跟随（轴向换成 dy） ──
            onVerticalDragStart: (d) {
              final nearest = _nearestIndex(
                  d.localPosition.dy, itemExtent, pillGap, items.length);
              final grabCenter = _itemCenter(nearest, itemExtent, pillGap);
              _dragGrabOffset = d.localPosition.dy - grabCenter;
              _dragX.value = grabCenter;
            },
            onVerticalDragUpdate: (d) {
              _dragX.value = (d.localPosition.dy - _dragGrabOffset)
                  .clamp(itemExtent / 2, totalMain - itemExtent / 2);
            },
            onVerticalDragEnd: (_) =>
                _endDrag(itemExtent, items.length, pillGap, itemToPage),
            onVerticalDragCancel: () {
              // 长按已接管时由长按流程收尾（与横排同规则）
              if (_longPressActive) return;
              _dragX.value = null;
            },
            child: Stack(children: [
              _buildRailMask(itemIdx, itemExtent, pillGap, items.length,
                  scheme: scheme, isDark: isDark, style: style),
              // 药丸列：主轴按固定 54 依次排布，交叉轴 stretch 撑满 52
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(height: pillGap),
                    SizedBox(
                      height: itemExtent,
                      child: _NavItem(
                        icon: items[i].$1,
                        activeIcon: items[i].$2,
                        label: items[i].$3,
                        selected: i == itemIdx,
                        selectedColor: selectedColor,
                        unselectedColor: unselectedColor,
                        maxWidth: crossExtent,
                      ),
                    ),
                  ],
                ],
              ),
            ]),
          ),
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
              _dragX.value = grabCenter;
            }),
            onLongPressMoveUpdate: (d) {
              _dragX.value = (d.localPosition.dx - _dragGrabOffset)
                  .clamp(itemW / 2, cons.maxWidth - itemW / 2);
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
              _dragX.value = (d.localPosition.dx - _dragGrabOffset)
                  .clamp(itemW / 2, cons.maxWidth - itemW / 2);
            },
            onHorizontalDragEnd: (_) => _endDrag(itemW, items.length, pillGap, itemToPage),
            onHorizontalDragCancel: () {
              // 长按已接管时由长按流程收尾，这里不要复位遮罩（否则先跳回旧项）。
              if (_longPressActive) return;
              _dragX.value = null;
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
                    if (i > 0) const SizedBox(width: pillGap),
                    SizedBox(
                      width: itemW,
                      child: _NavItem(
                        icon: items[i].$1,
                        activeIcon: items[i].$2,
                        label: items[i].$3,
                        selected: i == itemIdx,
                        selectedColor: selectedColor,
                        unselectedColor: unselectedColor,
                        maxWidth: itemW,
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
    final Widget shell = NavGlassShell(
      pal: pal,
      radius: radius,
      keyPrefix: 'nav',
      // 竖排导轨时外壳内边距改为让「贴屏那一侧」的安全区（见 shellPadding）
      placement: widget.placement,
      child: buildBarIn(),
    );

    // 滑动自动收起（仅底部形态生效；侧边导轨 app.dart 恒下发 hidden=false）：
    // 整条菜单栏下移滑出屏幕，欠阻尼弹簧的过冲即「到位后回弹」。位移量 =
    // 栏高 + 底部安全区 + 悬浮边距，保证完全离屏。Transform 只改绘制不改
    // 布局，收起全程 PageView 与玻璃外壳不重排；隐藏过半即拦截点击。
    if (_hideCtrl.value == 0 && !widget.hidden) return shell;
    final double hideDistance =
        barHeight + MediaQuery.paddingOf(context).bottom + 24;
    return AnimatedBuilder(
      animation: _hideCtrl,
      child: shell,
      builder: (context, child) {
        final t = _hideCtrl.value;
        if (t == 0) return child!;
        return IgnorePointer(
          ignoring: t > 0.5,
          child: Transform.translate(
            offset: Offset(0, t * hideDistance),
            child: child,
          ),
        );
      },
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
  double _itemCenter(int i, double itemW, double gap) => i * (itemW + gap) + itemW / 2;

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
          dragX, itemIdx, itemW, pillGap, itemCount,
          scheme: scheme, isDark: isDark, style: style,
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
    final mask = AnimatedScale(
      // 长按/拖动时放大，明确标识「已抓取/被选中」
      scale: dragging ? 1.25 : 1.0,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      child: RepaintBoundary(child: navMaskPill(scheme, isDark, style)),
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
        // = [0,1,3,4]，正好是 4 个 Tab 的 PageView 下标），故可直接按项宽定位。
        followLeft = p.clamp(0.0, itemCount - 1).toDouble() * (itemW + pillGap);
      }
    }

    // 位置来源③：吸附（260ms）。follow 分支用 Duration.zero —— AnimationController
    // 对 0 时长直接赋值（_animateToInternal 的 simulationDuration == Duration.zero
    // 分支），因此就是逐帧 1:1 跟随，不会引入一帧延迟。
    return AnimatedPositioned(
      duration: followLeft != null
          ? Duration.zero
          : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      left: followLeft ?? _itemLeft(itemIdx, itemW, pillGap),
      top: 2,
      bottom: 2,
      width: itemW,
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
  /// [navMaskPill]（glass 样式差异自动跟随 navStyle）。
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
          final mask = AnimatedScale(
            // 与横排同规则：长按/拖动时放大，明确标识「已抓取/被选中」
            scale: dragging ? 1.25 : 1.0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: RepaintBoundary(child: navMaskPill(scheme, isDark, style)),
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
            duration: followTop != null
                ? Duration.zero
                : const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            top: followTop ?? _itemLeft(itemIdx, itemExtent, gap),
            left: 2,
            right: 2,
            height: itemExtent,
            child: mask,
          );
        },
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
  /// 图标/文字尺寸：主导航 60px 高用默认值，较矮的子页面切换栏可调小。
  final double iconSize;
  final double labelSize;
  /// 可用宽度（= 父级 SizedBox 给出的 itemW）。
  /// [FIX UI-文字缩放溢出] 把内容宽度钉死为 itemW，使 FittedBox(scaleDown)
  /// 只做**纵向**缩放；否则 FittedBox 会以无界宽度测量子节点，长标签会从
  /// 「省略号」变成「整体缩小」，破坏既有排版语义。
  final double maxWidth;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.maxWidth,
    this.iconSize = 27,
    this.labelSize = 9.0,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    // 纯展示：点按/拖动统一由父级 GestureDetector 处理，避免手势竞争。
    //
    // [FIX UI-文字缩放溢出] 原实现把 Column 直接放进 Row(crossAxisAlignment:
    // stretch) 的**紧高度**约束里：图标 27 + 间距 1 + 文字 (labelSize ×
    // textScale × height 1.1)。textScale 上限是 AppTextScale.maxScale = 2.6
    // （系统字号 × 应用内字号，见 app.dart），此时内容高约 53.7px，而栏内可用
    // 高度只有 60 - 上下 padding 8 = 52px（子页面切换栏更矮：54 - 8 = 46px，
    // 溢出更早更明显）→ 必然抛「A RenderFlex overflowed by N pixels」并在
    // debug 下画黄黑溢出条纹。现在外面套一层 FittedBox(scaleDown)：内容超高时
    // 整体等比缩小到刚好放下；正常字号不会触发缩放（像素与改动前一致）。
    // 宽度用 maxWidth 钉死为 itemW，保证 Text 仍在 itemW 内做 ellipsis，
    // 而不是被无界测量后整体缩小。
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: maxWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
        ),
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
    // 与 main.dart 的 shader 预热走同一条门控：shaderGlassSupported 为 false 时
    // 玻璃渲染永远走不到 shader 分支（gpuGlassEnabledOf 已 gate），但这次调用
    // 仍会真的加载并编译一份用不到的 SkSL 运行时效应 —— 白占内存，直接跳过。
    if (shaderGlassSupported) OCLiquidGlassGroup.precacheShader();
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
                      if (i > 0) const SizedBox(width: pillGap),
                      SizedBox(
                        width: itemW,
                        child: _NavItem(
                          icon: widget.items[i].$1,
                          activeIcon: widget.items[i].$1,
                          label: widget.items[i].$2,
                          selected: i == widget.selectedIndex,
                          selectedColor: look.selectedColor,
                          unselectedColor: look.unselectedColor,
                          maxWidth: itemW,
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