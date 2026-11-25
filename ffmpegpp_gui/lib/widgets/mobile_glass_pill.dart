import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../theme/app_neutral_surface.dart';
import '../theme/app_press_feedback.dart';
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
/// 按下显示轻薄的轮廓内高光，松手柔和消退；玻璃与内容都不变形。
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
/// [size] controls the visible disk. The mobile touch area is at least 44
/// logical pixels where constraints allow and includes the padding.
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

  /// 移动端最小可点尺寸（默认 [MobileUi.pillHeight] = 44）。
  /// 只有次要的紧凑药丸（如节点编辑器缩放条）才传更小的值，且不低于 40。
  final double minTarget;

  /// 是否在图标下绘制 [bg] 指定的圆形底盘（默认 true，桌面端生效）。
  ///
  /// 移动端本来就**不画**圆盘（见下方 build 里的说明）。桌面端顶栏如果也把
  /// [bg] 画成一圈实色圆，会出现两个问题：圆盘直径（size + 内边距）比药丸内
  /// 边距更宽，视觉上顶到玻璃边缘；动态主题色也会混进中性玻璃面。
  /// 需要「只有图标、没有彩色圆圈」的调用点传 false，此时图标前景色完全由
  /// [color] 决定（调用方自己保证在玻璃面上可读）。
  final bool showDisk;

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
    this.minTarget = MobileUi.pillHeight,
    this.showDisk = true,
  });

  @override
  Widget build(BuildContext context) {
    final mobile = isMobilePlatform;
    final pad =
        padding ??
        EdgeInsets.symmetric(horizontal: mobile ? 1 : 2, vertical: 2);
    // 移动端玻璃药丸里不再画主题色（莫奈）实心圆：圆盘既会溢出药丸内边距，
    // 又让动态色混进中性玻璃。图标统一用中性前景色，层级靠分组表达。
    // 桌面端默认仍保留调用方要求的圆盘，但可以由 [showDisk] 显式关掉。
    final Color? disk = (mobile || !showDisk) ? null : bg;
    final Color? glyphColor = mobile && bg != null
        ? Theme.of(context).colorScheme.onSurface
        : color;
    final decoration = BoxDecoration(color: disk, shape: BoxShape.circle);
    final glyph = SizedBox.square(
      dimension: size,
      child: Icon(icon, size: iconSize, color: glyphColor),
    );
    Widget face = Padding(
      padding: pad,
      child: DecoratedBox(decoration: decoration, child: glyph),
    );
    if (mobile) {
      face = ConstrainedBox(
        constraints: BoxConstraints(minWidth: minTarget, minHeight: minTarget),
        child: Align(widthFactor: 1, heightFactor: 1, child: face),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final action = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(mobile ? 22 : size / 2),
      splashFactory: mobile ? NoSplash.splashFactory : null,
      overlayColor: mobile
          ? WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return scheme.onSurface.withValues(alpha: 0.10);
              }
              if (states.contains(WidgetState.focused)) {
                return scheme.onSurface.withValues(alpha: 0.16);
              }
              if (states.contains(WidgetState.hovered)) {
                return scheme.onSurface.withValues(alpha: 0.06);
              }
              return null;
            })
          : null,
      child: face,
    );
    return Tooltip(
      message: tooltip,
      child: mobile
          ? Semantics(
              button: true,
              enabled: onTap != null,
              child: Material(type: MaterialType.transparency, child: action),
            )
          : action,
    );
  }
}

/// Paints feedback above the stable glass without creating an opacity layer.
class _PillPressPainter extends CustomPainter {
  const _PillPressPainter({
    required this.amount,
    required this.radius,
    required this.color,
  });

  final double amount;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0 || size.isEmpty) return;
    final shape = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.5),
      Radius.circular(radius),
    );
    canvas.drawRRect(
      shape,
      Paint()..color = color.withValues(alpha: color.a * amount),
    );
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: color.a * amount * 0.8),
    );
  }

  @override
  bool shouldRepaint(_PillPressPainter oldDelegate) =>
      oldDelegate.amount != amount ||
      oldDelegate.color != color ||
      oldDelegate.radius != radius;
}

/// Directional edge light only: never wash a gradient across labels or icons.
class _MobileGlassRimPainter extends CustomPainter {
  const _MobileGlassRimPainter({
    required this.radius,
    required this.opacity,
    required this.tuning,
  });
  final double radius;
  final double opacity;
  final GlassTuning tuning;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.shortestSide < 8 || tuning.edge <= 0 || opacity <= 0) return;
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(
      rect.deflate(0.6),
      Radius.circular(radius),
    ).scaleRadii();
    final strength = (opacity * tuning.edge).clamp(0.0, 1.0);
    final angle = tuning.lightPos.clamp(0.0, 1.0);
    final light = Alignment(-1 + 2 * angle, -1);
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..shader = LinearGradient(
          begin: light,
          end: Alignment(-light.x, -light.y),
          colors: [
            Colors.white.withValues(alpha: 0.56 * strength),
            Colors.white.withValues(alpha: 0.06 * strength),
            Colors.white.withValues(alpha: 0.28 * strength),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_MobileGlassRimPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.opacity != opacity ||
      oldDelegate.tuning != tuning;
}

/// 药丸样式渲染相关的配置指纹，只有它变化时玻璃节点才重建。
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

class _MobileGlassPillState extends State<MobileGlassPill> {
  int? _pointer;
  Offset? _origin;
  final _pressed = ValueNotifier(false);
  bool _showFocus = false;

  void _setPressed(bool value) => _pressed.value = value;

  @override
  void dispose() {
    _pressed.dispose();
    super.dispose();
  }

  void _pointerDown(PointerDownEvent event) {
    if (_pointer != null || event.buttons != 1) return;
    _pointer = event.pointer;
    _origin = event.position;
    _setPressed(true);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if (_origin != null && (event.position - _origin!).distance > 12) {
      // A scroll/drag keeps its original gesture arena; only release the light.
      _setPressed(false);
    }
  }

  void _pointerEnd(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _origin = null;
    _setPressed(false);
  }

  Widget _pressSurface(Widget child) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    // 液态玻璃的按压压缩 / 回弹只作用于移动端；桌面端保持原来的纯光效反馈。
    final mobile = isMobilePlatform;
    final scheme = Theme.of(context).colorScheme;
    final color = MediaQuery.highContrastOf(context)
        ? scheme.onSurface.withValues(alpha: 0.16)
        : AppPressFeedback.softOverlay(scheme, true);
    return ValueListenableBuilder<bool>(
      valueListenable: _pressed,
      child: child,
      builder: (context, pressed, child) => TweenAnimationBuilder<double>(
        key: const ValueKey('pill_press_feedback'),
        tween: Tween(end: pressed ? 1 : 0),
        // 液态玻璃按压：约 110ms 轻压到 0.96，松开约 420ms 弹性回到原位。
        duration: reduced
            ? Duration.zero
            : Duration(
                milliseconds: mobile
                    ? (pressed ? 110 : 420)
                    : (pressed ? 70 : 125),
              ),
        curve: mobile && !pressed ? Curves.easeOutBack : Curves.easeOutCubic,
        child: child,
        builder: (context, amount, child) {
          final painted = CustomPaint(
            foregroundPainter: _PillPressPainter(
              amount: amount.clamp(0.0, 1.0),
              radius: widget.radius,
              color: color,
            ),
            child: child,
          );
          if (!mobile || reduced) return painted;
          // easeOutBack 会略微越过 0：缩放随之轻微回弹到 >1 再落定。
          return Transform.scale(
            key: const ValueKey('pill_press_scale'),
            scale: 1.0 - 0.04 * amount,
            child: painted,
          );
        },
      ),
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
    // 桌面端由 effectiveGlassSigma 钳到 ≤8；是否走 shader 由
    // gpuGlassEnabledOf 统一判定（PC 端默认关闭）。
    final GlassTuning tuning = key.tuning;
    final double pillSigma = effectiveGlassSigma(tuning.blur);
    final double tScale = tuning.tintScale;
    final style = SurfaceStyle.normalize(widget.style ?? key.style);
    if (isMobilePlatform) return _buildMobile(scheme, key, style);
    final op = key.op.clamp(0.0, 1.0);
    // 玻璃样式（liquid/blur）的 tint 与底部导航栏对齐：* 255 无截断，
    // 让玻璃质感与底部栏一致；纯色样式（theme/gray）强制完全不透明（255）
    // ——纯色语义即实心，不再跟随 cardOpacity（此前 ~88% 保底仍透底）。
    final solid = style == SurfaceStyle.theme || style == SurfaceStyle.gray;
    final highContrast = MediaQuery.highContrastOf(context);
    final liquid = style == SurfaceStyle.liquid;
    // Floating glass transmits the content, rather than painting a gray card.
    // Keep the existing opaque styles and a stronger accessibility scrim.
    final tintWeight = liquid && isMobilePlatform
        ? (highContrast ? (isDark ? 210 : 230) : (isDark ? 72 : 88))
        : (isDark ? 100 : 128);
    final baseAlpha = solid
        ? 255
        : ((op * tintWeight) * tScale).round().clamp(0, 255);
    final baseColor = style == SurfaceStyle.theme
        // Neutral mode retains a monochrome solid surface.
        ? (key.useThemeColor
              ? harmonizedAccent(scheme, key.tone)
              : AppNeutralSurface.card(scheme.brightness))
        : style == SurfaceStyle.gray
        // 灰色：去饱和，避免 fromSeed 的种子色偏（「灰色夹杂主题色」）
        ? AppNeutralSurface.card(scheme.brightness)
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
    Widget inner = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: style == SurfaceStyle.liquid && gpuGlass
            ? Colors.transparent
            : tint,
        // 光照交给玻璃引擎处理，避免内容上再叠一层独立的斜向亮暗带。
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

    if (liquid && gpuGlass) {
      inner = CustomPaint(
        foregroundPainter: _MobileGlassRimPainter(
          radius: widget.radius,
          opacity: op,
          tuning: tuning,
        ),
        child: inner,
      );
    }

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
      // Do not isolate the backdrop in a RepaintBoundary: content must remain
      // live as it scrolls behind this floating control.
      final glassKey = ValueKey<_PillGlassKey>(key);
      final innerKey = ValueKey<String>('${key.hashCode}_inner');
      pill = OCLiquidGlassGroup(
        key: glassKey,
        // 参数化 settings（带实例缓存，参数不变即复用同一实例）
        settings: liquidGlassSettingsFor(tuning, soft: true),
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
      );
    } else {
      // liquid 但无 Impeller（Windows 桌面端默认 Skia）：shader backdrop 会被
      // _RenderLiquidGlassGroup 整体跳过 → 玻璃完全不可见（此前配置库页签药丸
      // 就是这样「没渲染」的）。回退为高斯模糊 + 液态玻璃倒角高光，保证可见。
      // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
      pill = LiquidGlassBackdrop(
        borderRadius: BorderRadius.circular(widget.radius),
        // σ = 14（固定基准值，桌面端已由 effectiveGlassSigma 钳到 ≤8）
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
    //（而不是含 margin 的外框），按压仅影响前景光层。
    final result = withConfigurableBorder(
      context,
      pill,
      radius: BorderRadius.circular(widget.radius),
    );

    return _finish(result);
  }

  Widget _buildMobile(ColorScheme scheme, _PillGlassKey key, String style) {
    final corners = BorderRadius.circular(widget.radius);
    final height = widget.height;
    final padding = widget.padding.resolve(Directionality.of(context));
    Widget surface = Padding(
      padding: padding,
      child: height == null
          ? widget.child
          : SizedBox(
              height: (height - padding.vertical).clamp(0.0, double.infinity),
              child: Center(widthFactor: 1, child: widget.child),
            ),
    );
    final solid = style == SurfaceStyle.theme || style == SurfaceStyle.gray;
    if (solid) {
      final tint = style == SurfaceStyle.theme && key.useThemeColor
          ? harmonizedAccent(scheme, key.tone)
          : AppNeutralSurface.card(scheme.brightness);
      surface = DecoratedBox(
        decoration: BoxDecoration(color: tint, borderRadius: corners),
        child: surface,
      );
    } else {
      surface = MobileGlassSurface(
        borderRadius: corners,
        tuning: key.tuning,
        opacity: key.op,
        liquid: style != SurfaceStyle.blur,
        accent: key.follow && key.useThemeColor
            ? themedGlassBase(scheme, key.tone, true, second: key.second)
            : null,
        child: surface,
      );
    }
    return _finish(withConfigurableBorder(context, surface, radius: corners));
  }

  Widget _finish(Widget result) {
    final activate = widget.onTap;
    if (widget.pressable || activate != null) {
      if (_showFocus && activate != null) {
        result = DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(
              color: Theme.of(context).colorScheme.onSurface,
              width: 2,
            ),
          ),
          child: result,
        );
      }
      result = _pressSurface(result);
      if (activate != null && isMobilePlatform) {
        result = ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: MobileUi.pillHeight,
            minHeight: MobileUi.pillHeight,
          ),
          child: Align(widthFactor: 1, heightFactor: 1, child: result),
        );
      }
      // Pointer feedback preserves child gestures and cancels on scroll.
      result = Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _pointerDown,
        onPointerMove: _pointerMove,
        onPointerUp: _pointerEnd,
        onPointerCancel: _pointerEnd,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: activate,
          child: result,
        ),
      );
      if (activate != null) {
        Object? invoke(Intent _) {
          activate();
          return null;
        }

        result = Semantics(
          button: true,
          child: FocusableActionDetector(
            onShowFocusHighlight: (show) {
              if (_showFocus != show) setState(() => _showFocus = show);
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: invoke),
              ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
                onInvoke: invoke,
              ),
            },
            child: result,
          ),
        );
      }
    }
    final margin = widget.margin;
    return margin == null ? result : Padding(padding: margin, child: result);
  }
}
