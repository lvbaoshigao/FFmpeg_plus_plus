import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../theme/mobile_ui.dart';
import 'app_card.dart' show SurfaceStyle;
import 'liquid_glass_fallback.dart';

/// 移动端「药丸」容器 —— 顶部菜单栏样式（AppConfig.pillStyle）由它接管。
///
/// 四种样式：
/// - liquid：oc_liquid_glass 液态玻璃（GPU fragment shader）
/// - blur：扁平高斯模糊（BackdropFilter）
/// - theme：跟随主题色（纯色药丸）
/// - gray：灰色（纯色药丸）
///
/// 供顶栏标题药丸、顶栏操作长药丸、搜索框药丸等复用。
///
/// [pressable] 为 true 时（用于「内部无可点击元素」的药丸，如左上角标题药丸），
/// 按下轻微压缩，拖动时限幅形变，松手用弹簧回弹；不改变布局尺寸。
class MobileGlassPill extends StatefulWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final bool pressable;
  final VoidCallback? onTap;

  /// 固定药丸总高度（内容垂直居中）。顶栏里左右药丸高度不同（标题药丸因
  /// 字体行高约 38px、操作药丸约 44~50px）会造成视觉不一致；传 44 统一。
  final double? height;

  /// Optional surface override for panels that reuse this renderer.
  final String? style;

  const MobileGlassPill({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.margin,
    this.pressable = false,
    this.onTap,
    this.height,
    this.style,
  });

  @override
  State<MobileGlassPill> createState() => _MobileGlassPillState();
}

/// 药丸内紧凑圆形图标按钮 —— **全应用移动端顶栏动作按钮的唯一实现**。
/// 与主界面（项目页）"搜索/导入/容器/+"按钮逐像素一致。
///
/// 为什么不用 IconButton：Material IconButton 会按主题色渲染 splash/focus/hover，
/// 在液态玻璃药丸里会显示一片主题色块（特别是搜索→关闭切换瞬间的涟漪 + 蓝色边框），
/// 且自带 48×48 最小尺寸约束，会把药丸撑得比标题药丸更高。
/// 这里手写一个透明 InkWell 的紧凑按钮：
/// - 默认无背景；[bg] 传入后变成实心主题色圆形（用于"+"加号 CTA）
/// - splash/highlight 都透明，避免蓝色涟漪
/// - 尺寸/图标/内边距统一取自 [MobileUi]（34/19/h1|h2）
///
/// 移动端横向内边距取 1（比桌面 2 更紧凑），与主界面一致。
class MobileGlassPillAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color? color;
  final Color? bg;
  final VoidCallback? onTap;

  /// 按钮直径（默认 [MobileUi.actionButtonSize]）
  final double size;

  /// 图标尺寸（默认 [MobileUi.actionIconSize]）
  final double iconSize;

  /// 覆盖默认内边距（默认移动端 h1/v2，桌面端 h2/v2）
  final EdgeInsetsGeometry? padding;

  const MobileGlassPillAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.bg,
    this.size = MobileUi.actionButtonSize,
    this.iconSize = MobileUi.actionIconSize,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final pad =
        padding ??
        EdgeInsets.symmetric(horizontal: isMobilePlatform ? 1 : 2, vertical: 2);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(size / 2),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: pad,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Icon(icon, size: iconSize, color: color),
          ),
        ),
      ),
    );
  }
}

/// 药丸样式渲染相关的"配置指纹"。只有它变化时玻璃节点才该重建。
@immutable
class _PillGlassKey {
  /// 顶部药丸样式（pillStyle 四值：theme/liquid/blur/gray）
  final String style;
  final double op;
  final int primary;
  final bool useThemeColor;
  final int second;

  /// 「设置 → 样式 → 玻璃底色遵循主题色」：玻璃 tint 用主题色而非 surface 灰
  /// （此前只有桌面端 GlassPanel 读它，移动端药丸不读 → 开关表现为「无效」）。
  final bool follow;

  /// 玻璃细节（模糊度 / 通透度 / 高光强度与位置 / 边缘光）
  final GlassTuning tuning;

  /// 主题色协调度（避免直接铺 scheme.primary 过亮）
  final double tone;
  const _PillGlassKey({
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
      other is _PillGlassKey &&
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

class _MobileGlassPillState extends State<MobileGlassPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pressController;
  int? _pointer;
  Offset? _origin;
  final ValueNotifier<Offset> _drag = ValueNotifier(Offset.zero);

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController.unbounded(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _pressController.value = 0;
      return;
    }
    if (pressed) {
      // Keep the response immediate, while the release below uses a real
      // under-damped spring instead of a linear/timed snap-back.
      _pressController.animateTo(
        1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
      );
      return;
    }

    final simulation = SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 420, damping: 28),
      _pressController.value,
      0,
      _pressController.velocity,
    );
    _pressController.animateWith(simulation);
  }

  void _pointerDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _origin = event.position;
    _drag.value = Offset.zero;
    _setPressed(true);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _origin == null) return;
    final delta = event.position - _origin!;
    _drag.value = Offset(
      (delta.dx * 0.12).clamp(-6.0, 6.0),
      (delta.dy * 0.12).clamp(-4.0, 4.0),
    );
    // Pointer updates only notify the paint transform.
  }

  void _pointerEnd(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _origin = null;
    _setPressed(false);
  }

  Widget _pressedTransform(Widget child) {
    return AnimatedBuilder(
      animation: Listenable.merge([_pressController, _drag]),
      child: child,
      builder: (context, child) {
        final amount = _pressController.value.clamp(-0.2, 1.0);
        // Compress vertically while allowing the sides to bulge slightly.
        // This remains a paint-only transform: the glass subtree (and its
        // shader uniforms/backdrop) is kept as AnimatedBuilder's child.
        final scale = 1 - (amount * 0.025);
        final horizontal = scale * (1 + (amount * 0.012));
        final vertical = scale * (1 - (amount * 0.012));
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(horizontal, vertical, 1)
            ..setTranslationRaw(
              _drag.value.dx * amount,
              _drag.value.dy * amount,
              0,
            ),
          child: child,
        );
      },
    );
  }

  // 仅当这些字段变化时才重建 OCLiquidGlass 节点；
  // 关键修复：原代码用 context.watch<AppState>() 订阅整个 AppState，
  // 进度/日志/任务等高频 notify 会反复重建 OCLiquidGlassGroup + OCLiquidGlass，
  // 导致 GPU shader uniform 重新初始化 → 视觉上"液态玻璃来回跳跃"。
  // 改用 Selector 精细订阅 + 稳定 key 后，shader 内部状态得以保留。
  // 液态玻璃 settings 统一用 liquid_glass_fallback.kLiquidGlassSettings（全应用
  // 唯一一份 const 基准实例，与底部导航 / 卡片同源，避免多份重复常量漂移）：
  // 实例恒定，就不会因为 build 重新下发 shader uniform（这是移动端
  //「玻璃来回跳跃」闪烁的根因）。

  /// 把玻璃渲染所需的所有字段打包成一个值。
  /// 只有这些字段变化时 Selector 才会重新构建 builder，避免 OCLiquidGlass
  /// 被无关的 notifyListeners()（日志/进度/任务状态等）反复销毁重建。
  static _PillGlassKey _keyOf(AppState s) {
    final cfg = s.config;
    return _PillGlassKey(
      style: cfg.pillStyle,
      op: cfg.cardOpacity,
      primary: cfg.themeColor,
      useThemeColor: cfg.useThemeColor,
      second: cfg.themeColor2,
      follow: cfg.glassFollowTheme,
      tuning: GlassTuning(
        blur: cfg.glassBlur,
        clarity: cfg.glassClarity,
        highlight: cfg.glassHighlight,
        lightPos: cfg.glassLightPos,
        edge: cfg.glassEdge,
      ),
      tone: cfg.themeTone,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final key = context.select<AppState, _PillGlassKey>(_keyOf);
    // 模糊 σ 来自「设置 → 样式 → 玻璃细节 → 模糊度」（默认 16，与改动前一致），
    // Windows 上由 effectiveGlassSigma 钳到 ≤12；是否走 shader 由
    // gpuGlassEnabledOf 统一判定（PC 端默认关闭）。
    final GlassTuning tuning = key.tuning;
    final double pillSigma = effectiveGlassSigma(tuning.blur);
    final double tScale = tuning.tintScale;
    final style = widget.style ?? key.style;
    final op = key.op.clamp(0.0, 1.0);
    // 玻璃样式（liquid/blur）的 tint 与底部导航栏对齐：* 255 无截断，
    // 让玻璃质感与底部栏一致；纯色样式（theme/gray）强制完全不透明（255）
    // ——纯色语义即实心，不再跟随 cardOpacity（此前 ~88% 保底仍透底）。
    final solid = style == SurfaceStyle.theme || style == SurfaceStyle.gray;
    final baseAlpha = solid
        ? 255
        : ((op * (isDark ? 100 : 128)) * tScale).round().clamp(0, 255);
    final baseColor = style == SurfaceStyle.theme
        // Neutral mode retains a monochrome solid surface.
        ? (key.useThemeColor
              ? harmonizedAccent(scheme, key.tone)
              : neutralGray(scheme.surfaceContainerHigh))
        : style == SurfaceStyle.gray
        // 灰色：去饱和，避免 fromSeed 的种子色偏（「灰色夹杂主题色」）
        ? neutralGray(scheme.surfaceContainerHigh)
        // 「玻璃底色遵循主题色」：玻璃样式（liquid/blur）的 tint 用主题色
        : themedGlassBase(
            scheme,
            key.tone,
            key.follow && key.useThemeColor,
            second: key.useThemeColor ? key.second : -1,
          );
    final tint = baseColor.withAlpha(baseAlpha);

    // 关键修复：liquid 模式下 OCLiquidGlass 自身已经接收 color=tint 作为
    // 玻璃的 tint（GPU shader 内部叠加）；如果 inner Container 再额外叠一层
    // color=tint，相当于「主题色 + 主题色」双重染色，
    // 切换页面瞬间会出现「一大片主题色块」闪烁。
    // liquid 模式 inner 用透明，只保留边框；blur/theme/gray 模式保留 tint。
    // 边框（=「边缘光」）随玻璃细节缩放：基准 1.0 时与改动前逐像素一致。
    final edgeBlur = edgeBorder(80 / 255, 0.5, tuning.edge);
    final edgeWhite = edgeBorder(isDark ? 0.12 : 0.18, 0.7, tuning.edge);
    final gpuGlass = gpuGlassEnabledOf(context);
    final inner = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: style == SurfaceStyle.liquid && gpuGlass
            ? Colors.transparent
            : tint,
        // A shallow reflection adds volume without another backdrop layer.
        gradient: style == SurfaceStyle.liquid
            ? LinearGradient(
                begin: Alignment(-1 + tuning.lightPos * 2, -1),
                end: Alignment(1 - tuning.lightPos * 2, 1),
                colors: [
                  Colors.white.withValues(
                    alpha: (0.065 * tuning.highlight * op).clamp(0.0, 0.16),
                  ),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.035 * op),
                ],
                stops: const [0, 0.48, 1],
              )
            : null,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: style == SurfaceStyle.blur
              ? scheme.outlineVariant.withAlpha(
                  (edgeBlur.alpha * 255).round().clamp(0, 255),
                )
              : Colors.white.withValues(alpha: edgeWhite.alpha),
          width: style == SurfaceStyle.blur ? edgeBlur.width : edgeWhite.width,
        ),
      ),
      // 固定总高度：把内容区压到 height - padding.vertical 并垂直居中，
      // 统一顶栏左右药丸的高度（否则标题药丸 ~38px、操作药丸 ~50px 参差不齐）。
      //
      // 关键修复（配置库/队列右上角操作药丸被拉得过长）：Center（Align）在
      // 收到「有限宽度」约束时会撑满最大宽度——队列页、配置库页顶栏右侧的
      // 操作药丸都包在 Flexible → Align 里，Flexible 给出的 loose-finite 宽度
      // 让 Center 一路膨胀到整行剩余宽度，玻璃底板于是远长于内部图标。
      // widthFactor: 1.0 让宽度始终收缩为子元素宽度，只保留垂直居中。
      child: widget.height == null
          ? widget.child
          : SizedBox(
              height:
                  (widget.height! -
                          widget.padding
                              .resolve(Directionality.of(context))
                              .vertical)
                      .clamp(0.0, double.infinity),
              child: Center(widthFactor: 1.0, child: widget.child),
            ),
    );

    Widget pill;
    if (solid) {
      pill = inner;
    } else if (style == SurfaceStyle.blur) {
      // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
      pill = ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: cachedGlassBlur(pillSigma),
          child: CustomPaint(
            // 高光 / 边缘光与液态玻璃回退共用同一支画笔
            painter: LiquidGlassPainter(
              borderRadius: BorderRadius.circular(widget.radius),
              opacity: op,
              highlight: tuning.highlight,
              lightPos: tuning.lightPos,
              edge: tuning.edge,
            ),
            child: inner,
          ),
        ),
      );
    } else if (gpuGlass) {
      // liquid：液态玻璃 shader（Impeller 可用时）
      // 关闭高光带（lightband）与压低镜面高光：高光带按固定像素偏移绘制，
      // 在较「高」的内容（如设置项卡片）上会变成一条横向"分界线"，
      // 视觉上把内容截成两段 —— 这里去掉它，仅保留折射 + 柔和高光。
      //
      // 关键修复：
      // 1) settings 用 kLiquidGlassSettings（全应用唯一 const 基准实例，dark
      //    差异化交给 tint + shadow），避免每次 build 新建 OCLiquidGlassSettings
      //    触发 shader uniform 重置；
      // 2) 给 OCLiquidGlassGroup 加 ValueKey(key)，仅当玻璃配置
      //    变化时才真的销毁/重建液态玻璃节点；普通 AppState notify（进度、
      //    日志、任务状态等）会让 key 不变，Element 复用，shader 内部状态稳定；
      // 3) OCLiquidGlass 使用独立 key（避免与父级 OCLiquidGlassGroup 重复）；
      // 4) RepaintBoundary 放在 OCLiquidGlassGroup 内部、OCLiquidGlass 外部，
      //    让 shader 能正确采样画布背景，同时隔离内部重绘。
      final glassKey = ValueKey<_PillGlassKey>(key);
      final innerKey = ValueKey<String>('${key.hashCode}_inner');
      pill = RepaintBoundary(
        child: OCLiquidGlassGroup(
          key: glassKey,
          // 参数化 settings（带实例缓存，参数不变即复用同一实例）
          settings: liquidGlassSettingsFor(tuning),
          child: OCLiquidGlass(
            key: innerKey,
            borderRadius: widget.radius,
            color: tint,
            shadow: BoxShadow(
              color: Colors.black.withAlpha(isDark ? 60 : 22),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
            child: inner,
          ),
        ),
      );
    } else {
      // liquid 但无 Impeller（Windows 桌面端默认 Skia）：shader backdrop 会被
      // _RenderLiquidGlassGroup 整体跳过 → 玻璃完全不可见（此前配置库页签药丸
      // 就是这样「没渲染」的）。回退为高斯模糊 + 液态玻璃倒角高光，保证可见。
      // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
      pill = LiquidGlassBackdrop(
        borderRadius: BorderRadius.circular(widget.radius),
        // σ = 14（固定基准值，Windows 上已由 effectiveGlassSigma 钳到 ≤12）
        sigma: pillSigma,
        opacity: op,
        shadow: BoxShadow(
          color: Colors.black.withAlpha(isDark ? 60 : 22),
          blurRadius: 16,
          offset: const Offset(0, 5),
        ),
        child: inner,
      );
    }

    // 「样式 → 添加边框」：开启时在药丸表面之上叠一层同圆角描边（关闭时原样
    // 返回 pill，零额外层级）。放在点击/外边距包装之内：描边严格贴合药丸本体
    //（而不是含 margin 的外框），并随按压缩放一起动画。
    Widget result = withConfigurableBorder(
      context,
      pill,
      radius: BorderRadius.circular(widget.radius),
    );

    if (widget.pressable || widget.onTap != null) {
      // Raw pointer feedback preserves child gestures and cancels cleanly.
      result = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _pointerDown,
        onPointerMove: _pointerMove,
        onPointerUp: _pointerEnd,
        onPointerCancel: _pointerEnd,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: _pressedTransform(result),
        ),
      );
    }

    // 应用 margin
    if (widget.margin != null) {
      result = Padding(padding: widget.margin!, child: result);
    }

    return result;
  }
}
