import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
// cachedGlassBlur：轨道玻璃的 σ 走进程级实例缓存（避免设置页里几十个滑块
// 各自在每帧 build 时新建一份持有 native handle 的 ImageFilter）；
// effectiveGlassSigma：桌面端的 σ 上限钳制。
import 'liquid_glass_fallback.dart' show cachedGlassBlur, effectiveGlassSigma;

// ═══════════════════════════════════════════
// 统一滑块 / 进度条（全应用唯一来源）
// ═══════════════════════════════════════════
//
// 为什么要有这个文件：
// 之前各页面直接 new `Slider` / `RangeSlider` / `LinearProgressIndicator`，于是同一个
// 应用里出现了三种轨道高度、两套配色（有的页面自己拼 `SliderThemeData`，有的用
// framework 默认），甚至同一个屏幕里上下两个滑动条高度都不一样。这里把
// 「轨道 + 填充 + 拖动反馈 + 数值动画」固化成唯一实现，各页面只传数据
// （value/min/max/onChanged），不再各自拼主题。
//
// ★ 统一规格（2026-09-14 改版 —— 用户提供参考图：粗胶囊 + 实心填充 + 玻璃留空，
//   并明确要求「此改动包括滑动条和进度条」）：
// - 轨道：高 [kAppTrackHeight] 的**胶囊**（两端全圆角，圆角 = 高度 / 2），
//   左右各留 [_kTrackInsetX]；未填充与已填充段同高（不再有 M3 的
//   `additionalActiveTrackHeight = 2`，否则两段对不齐）；
// - 已填充段（= 参考图里的黑色部分）= **主题色实心胶囊**，宽度 = 当前值比例 ×
//   轨道宽。`AppSlider.color` 仍可覆盖它（字幕编辑器的色相/饱和度/亮度条）；
// - **没有 thumb**：填充段的边缘就是把手（用户历史上要求「不要有 o」），
//   因此按下时不会再出现圆点或圆形光晕；
// - 未填充段（= 参考图里的白色部分）= **高斯模糊玻璃**
//   （[AppTrackGlass]：BackdropFilter + 极淡底色 + 细描边，形状同为胶囊）。
//   玻璃必须由 widget 层绘制 —— CustomPainter 的 canvas 无法创建 backdrop
//   滤镜层，所以 trackShape 只画填充段，未填充段的颜色传透明
//   （见 [_appSliderTheme] 的 `glassTrack`）。
//
// 为什么用 SliderTheme 包住 framework 的 Slider，而不是从头自绘：
// framework 的 Slider/RangeSlider 已经处理好了命中区域、拖拽与键盘交互、divisions
// 吸附、数值气泡（label）、RTL 镜像、Semantics 无障碍、拖动去抖等细节；自绘必须
// 重新实现这些且极易引入行为回归。这里只替换「轨道形状 / thumb 形状 / 配色」
// 这几处纯外观插槽，其余行为完全沿用 framework。
//
// 唯一自绘的是 [AppProgressBar]：CustomPainter 统一掌控圆角轨道、确定进度的彗星
// 高光和不确定态的运动，避免 SDK 版本或主题差异改变进度条的形状与节奏。

/// 统一轨道高度 —— **胶囊**（两端全圆角）。
///
/// 滑动条与进度条共用：用户要求「滑动条和进度条」统一成参考图那种粗胶囊。
/// 想整体调粗细只改这一个值（`AppProgressBar.height` 与各进度条的 height 都取它）。
const double kAppTrackHeight = 16;

/// [AppSlider.compact] 模式的轨道高度（密集表单）。
const double kAppCompactTrackHeight = 11;

/// 胶囊左右各留出的空隙。现在没有 thumb 要占位，胶囊几乎铺满整行。
const double _kTrackInsetX = 2;

/// 留空段玻璃的高斯模糊 σ。轨道只有十几 px 高，小 σ 足够且便宜。
const double _kTrackGlassSigma = 9;

/// 「隐藏 thumb」的占位尺寸。
///
/// framework 用 overlay/thumb 的 preferred size 推导 Slider 的固有高度
/// （`max(轨道高, thumb 高, overlay 高)`）与固有宽度。真正的 handle 现在已经变成
/// 「填充段的边缘」，但**占位高度必须留在 44** —— 否则行高会从 44 掉到轨道高、
/// 纵向可拖动区域一起缩水（历史上移除 overlay 时就踩过这个坑）。
const Size _kSliderPlaceholder = Size(18, 44);

/// 数值变化动画时长。取 180ms：比 framework 自己的 75ms 离散吸附动画略长，
/// 肉眼能看出「滑过去」但不会显得拖沓。
const Duration _kValueAnimationDuration = Duration(milliseconds: 180);

/// overlay 透明度：Material 默认 0.12 → 31/255。
/// 现在 overlay 形状什么都不画（见 [_InvisibleOverlayShape]），此值仅为保持
/// 主题字段完整、避免其它调用点拿到 null。
const int _kOverlayAlpha = 31;

/// 进度条不确定态彗星穿过轨道的周期。
const int _kIndeterminateDurationMs = 1800;

// The same tapered highlight is drawn against the real fill in every track.
// Slider motion only ticks while the tail is settling or fading out.
final class _SliderCometMotion {
  _SliderCometMotion(TickerProvider vsync)
    : _animation = AnimationController(vsync: vsync) {
    _animation.addListener(_repaint);
  }

  static const _settleDuration = Duration(milliseconds: 150);
  static const _fadeDuration = Duration(milliseconds: 160);

  final AnimationController _animation;
  RenderBox? track;
  Thumb? _thumb;
  bool _enabled = false;
  bool _releasing = false;
  double _peakSpeed = 0;
  double _lastDirection = 0;
  Duration? _lastMoveAt;

  double get _speed =>
      _peakSpeed * (1 - Curves.easeOutQuad.transform(_animation.value));

  void setEnabled(bool enabled) {
    if (_enabled == enabled) {
      return;
    }
    _enabled = enabled;
    if (!enabled) {
      reset();
      track = null;
    }
  }

  void reset() {
    final wasVisible = _thumb != null;
    _animation.stop();
    _thumb = null;
    _releasing = false;
    _lastDirection = 0;
    _lastMoveAt = null;
    if (wasVisible) {
      _repaint();
    }
  }

  void move(double deltaFraction, {Thumb thumb = Thumb.end}) {
    if (!_enabled || deltaFraction == 0) {
      return;
    }
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final elapsed = now - (_lastMoveAt ?? now);
    // Several pointer updates may arrive in one frame. Use a frame-sized
    // minimum, and limit how much a stationary pause dampens the next move.
    final seconds = (elapsed.inMicroseconds / Duration.microsecondsPerSecond)
        .clamp(1 / 60, 0.05);
    final speed = (deltaFraction.abs() / seconds / 2.4).clamp(0.0, 1.0);
    final direction = deltaFraction.sign;
    final priorSpeed = _thumb == thumb && _lastDirection == direction
        ? _speed
        : 0.0;
    _peakSpeed = math.max(speed, priorSpeed);
    _lastDirection = direction;
    _lastMoveAt = now;
    _thumb = thumb;
    _releasing = false;
    _animation.duration = _settleDuration;
    _animation.forward(from: 0);
  }

  void release() {
    if (_thumb == null) {
      return;
    }
    _peakSpeed = _speed;
    _releasing = true;
    _animation.duration = _fadeDuration;
    _animation.forward(from: 0);
  }

  void paint(
    Canvas canvas, {
    required RRect fill,
    required bool startOnLeft,
    required Color color,
  }) {
    if (_thumb case final thumb?) {
      _drawComet(
        canvas,
        fill: fill,
        headAtLeft: (thumb == Thumb.start) == startOnLeft,
        fillColor: color,
        speed: _speed,
        opacity: _releasing ? 1 - _animation.value : 1,
      );
    }
  }

  void _repaint() {
    if (_releasing && _animation.isCompleted) {
      _thumb = null;
      _releasing = false;
    }
    // The actual framework track owns the rendered thumb position. Repaint it
    // without rebuilding the slider or recomputing the thumb from its value.
    final renderBox = track;
    if (renderBox != null && renderBox.attached) {
      renderBox.markNeedsPaint();
    }
  }

  void dispose() {
    track = null;
    _animation.dispose();
  }
}

// ═══════════════════════════════════════════
// 表面配置指纹（玻璃 / 彗星拖尾开关）
// ═══════════════════════════════════════════

/// 轨道渲染所需的配置指纹：只订阅影响渲染的字段，
/// 进度 / 日志等高频 notify 不会重建滑块（与 AppCard 的 `_CardGlassKey` 同一思路）。
@immutable
class _TrackCfg {
  /// 「样式 → 不使用卡片玻璃效果」：不做高斯模糊，退回半透明底色（低配省电档）。
  final bool noGlass;

  /// 「样式 → 玻璃底色遵循主题色」：玻璃底色改用主题色而不是白/灰。
  final bool follow;

  /// 「样式 → 滑块彗星拖尾」：拖动时是否出现彗星拖尾。
  final bool particles;

  const _TrackCfg({
    required this.noGlass,
    required this.follow,
    required this.particles,
  });

  @override
  bool operator ==(Object other) =>
      other is _TrackCfg &&
      other.noGlass == noGlass &&
      other.follow == follow &&
      other.particles == particles;

  @override
  int get hashCode => Object.hash(noGlass, follow, particles);
}

_TrackCfg _trackCfgOf(BuildContext context) =>
    context.select<AppState, _TrackCfg>(
      (s) => _TrackCfg(
        noGlass: s.config.noCardGlass,
        follow: s.config.glassFollowTheme,
        particles: s.config.sliderParticles,
      ),
    );

// ═══════════════════════════════════════════
// 留空段的玻璃底（滑块 / 进度条 / 分段进度条共用）
// ═══════════════════════════════════════════

/// 轨道「未填充段」的玻璃底 —— 全应用唯一实现。
///
/// * 默认：高斯模糊（BackdropFilter，取样的是卡片/页面**真实**的背景）
///   + 极淡的白色底 + 细描边 → 参考图里那段「留白」；
/// * `noGlass`（设置 → 样式 → 不使用卡片玻璃效果）：跳过模糊，只用半透明底色，
///   给低配设备留一个省电档；
/// * `follow`（玻璃底色遵循主题色）：底色改用主题色淡染，与卡片/药丸一致。
///
/// 形状恒为胶囊（圆角 = 高度 / 2），与填充段同高，因此填充段压上去之后
/// 看到的是一条完整的胶囊。
class AppTrackGlass extends StatelessWidget {
  const AppTrackGlass({super.key, required this.height, this.radius});

  /// 轨道高度（= 胶囊直径）。
  final double height;

  /// 覆盖圆角（默认两端全圆角）。分段进度条等多段场景可传入自定义圆角。
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cfg = _trackCfgOf(context);
    final br = radius ?? BorderRadius.circular(height / 2);

    // 底色：默认极淡的白（浅色主题下是磨砂白、深色主题下是磨砂黑），
    // 开启「遵循主题色」时用主题色淡染。
    final Color base = cfg.follow ? scheme.primary : Colors.white;
    final Color tint = cfg.noGlass
        ? scheme.surfaceContainerHighest.withAlpha(isDark ? 200 : 220)
        : base.withAlpha(cfg.follow ? (isDark ? 34 : 46) : (isDark ? 28 : 104));

    final Widget fill = DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: br,
        border: Border.all(
          color: cfg.noGlass
              ? scheme.outlineVariant.withAlpha(isDark ? 60 : 80)
              : Colors.white.withAlpha(isDark ? 46 : 150),
          width: 0.7,
        ),
      ),
    );

    if (cfg.noGlass) {
      // 省电档：不建 BackdropFilter，也就没有离屏纹理与额外 saveLayer。
      return SizedBox(height: height, width: double.infinity, child: fill);
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      // ClipRRect 同时起到两个作用：把胶囊外的模糊裁掉 + 限定 BackdropFilter
      // 的取样范围（不裁剪的 backdrop 滤镜会按整块离屏分配）。
      child: ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          // 轨道 σ 恒定，走缓存 → 设置页里几十个滑块不再各自新建 filter。
          filter: cachedGlassBlur(effectiveGlassSigma(_kTrackGlassSigma)),
          child: fill,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 自绘形状：胶囊轨道 + 隐藏 thumb
// ═══════════════════════════════════════════

/// 「只占位、不绘制」的 overlay 形状。
///
/// 用途：既满足「滑块附近不能出现圆」（framework 默认的 RoundSliderOverlayShape 是
/// 圆形光晕），又保留 overlay 在布局上的作用 —— 它决定了 Slider 的固有高度
/// （见 [_kSliderPlaceholder]）。paint 里什么都不画。
class _InvisibleOverlayShape extends SliderComponentShape {
  const _InvisibleOverlayShape(this.size);

  final Size size;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => size;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {}
}

/// 「不绘制」的单值 thumb。
///
/// 参考图里没有圆点：把手就是填充段的边缘，所以 thumb 只在布局上占位
/// （preferred size 为 0；真正撑住行高的是 overlay，见 [_kSliderPlaceholder]）。
class _HiddenThumbShape extends SliderComponentShape {
  const _HiddenThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.zero;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {}
}

/// 「不绘制」的区间 thumb（RangeSlider 用的是 [RangeSliderThumbShape] 接口，
/// 与 [SliderComponentShape] 不通用，因此必须单独一个类）。
class _HiddenRangeThumbShape extends RangeSliderThumbShape {
  const _HiddenRangeThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.zero;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool isOnTop = false,
    TextDirection textDirection = TextDirection.ltr,
    required SliderThemeData sliderTheme,
    Thumb thumb = Thumb.start,
    bool isPressed = false,
  }) {}
}

/// 胶囊轨道几何：轨道不再给 thumb 让位，左右各留 [_kTrackInsetX]，
/// 竖直方向在 Slider 盒内居中（与 [AppTrackGlass] 的摆放完全一致）。
Rect _capsuleRect({
  required RenderBox parentBox,
  required Offset offset,
  required double trackHeight,
}) {
  final double top = offset.dy + (parentBox.size.height - trackHeight) / 2;
  return Rect.fromLTRB(
    offset.dx + _kTrackInsetX,
    top,
    offset.dx + parentBox.size.width - _kTrackInsetX,
    top + trackHeight,
  );
}

/// 轨道公共绘制：未填充段（仅非玻璃模式）+ 已填充段（主题色实心胶囊）。
void _paintCapsuleTrack(
  Canvas canvas, {
  required Rect trackRect,
  required bool glass,
  required Color inactiveColor,
  required Color activeColor,
  required Color borderColor,
  required Offset? activeFrom,
  required Offset? activeTo,
  _SliderCometMotion? comet,
}) {
  final Radius radius = Radius.circular(trackRect.height / 2);

  // ── 未填充段 ──
  // glass = true 时不画：留空段由 AppTrackGlass 提供（含真实高斯模糊），
  // 这里再画一层会把玻璃盖住。
  if (!glass) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      Paint()..color = inactiveColor,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect.deflate(0.35), radius),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = borderColor,
    );
  }

  // ── 已填充段 ──
  // 两端都是圆角（半径 = 半高）：填充很短时 Skia 会自动收窄半径，
  // 画出来是一个小圆头而不是方块。
  final Offset? from = activeFrom;
  final Offset? to = activeTo;
  if (from == null || to == null) return;
  final double left = math.min(from.dx, to.dx);
  final double right = math.max(from.dx, to.dx);
  final double w = right - left;
  if (w <= 0.01) return;
  final fill = RRect.fromRectAndRadius(
    Rect.fromLTRB(left, trackRect.top, right, trackRect.bottom),
    radius,
  );
  canvas.drawRRect(fill, Paint()..color = activeColor);
  comet?.paint(
    canvas,
    fill: fill,
    startOnLeft: from.dx < to.dx,
    color: activeColor,
  );
}

/// 单值滑块轨道：胶囊形，只画已填充段。
class _CapsuleTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _CapsuleTrackShape({
    required this.glass,
    required this.borderColor,
    this.comet,
  });

  final _SliderCometMotion? comet;

  /// true = 留空段交给 [AppTrackGlass]（未填充色传的是透明）。
  final bool glass;

  /// 非玻璃模式下未填充段的细描边色。
  final Color borderColor;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) => _capsuleRect(
    parentBox: parentBox,
    offset: offset,
    trackHeight: sliderTheme.trackHeight ?? kAppTrackHeight,
  );

  /// 必须 false。`isRounded = true` 时 framework 会把 thumb 中心按
  /// `trackRect.height` 内缩（见 RenderSlider._calcThumbCenter 的 padding），
  /// 在厚轨道下会让填充段在 value=0 时露出一小截、value=1 时又到不了右端。
  @override
  bool get isRounded => false;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final Color inactive =
        ColorTween(
          begin: sliderTheme.disabledInactiveTrackColor,
          end: sliderTheme.inactiveTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;
    final Color active =
        ColorTween(
          begin: sliderTheme.disabledActiveTrackColor,
          end: sliderTheme.activeTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;

    // LTR：填充段从轨道左端长到 thumb 中心；RTL：从右端长过去。
    comet?.track = parentBox;
    _paintCapsuleTrack(
      context.canvas,
      trackRect: trackRect,
      glass: glass,
      inactiveColor: inactive,
      activeColor: active,
      borderColor: borderColor,
      activeFrom: textDirection == TextDirection.ltr
          ? trackRect.centerLeft
          : trackRect.centerRight,
      activeTo: Offset(thumbCenter.dx, trackRect.center.dy),
      comet: comet,
    );
  }
}

/// 区间滑块轨道：胶囊形；两个 thumb 之间为已填充段。
///
/// 注意基类是 [RangeSliderTrackShape]（与 [SliderTrackShape] 不通用）：
/// 它的 paint 多出 endThumbCenter、且**没有** additionalActiveTrackHeight。
class _CapsuleRangeTrackShape extends RangeSliderTrackShape
    with BaseSliderTrackShape {
  const _CapsuleRangeTrackShape({
    required this.glass,
    required this.borderColor,
    this.comet,
  });

  final bool glass;
  final Color borderColor;
  final _SliderCometMotion? comet;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) => _capsuleRect(
    parentBox: parentBox,
    offset: offset,
    trackHeight: sliderTheme.trackHeight ?? kAppTrackHeight,
  );

  /// 同 [_CapsuleTrackShape.isRounded]：区间滑块有同一套内缩逻辑。
  @override
  bool get isRounded => false;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset startThumbCenter,
    required Offset endThumbCenter,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final Color inactive =
        ColorTween(
          begin: sliderTheme.disabledInactiveTrackColor,
          end: sliderTheme.inactiveTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;
    final Color active =
        ColorTween(
          begin: sliderTheme.disabledActiveTrackColor,
          end: sliderTheme.activeTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;

    comet?.track = parentBox;
    _paintCapsuleTrack(
      context.canvas,
      trackRect: trackRect,
      glass: glass,
      inactiveColor: inactive,
      activeColor: active,
      borderColor: borderColor,
      activeFrom: startThumbCenter,
      activeTo: endThumbCenter,
      comet: comet,
    );
  }
}

/// 主题层统一入口：`AppTheme` 的 sliderTheme 直接使用它，保证「显式用 AppSlider 的
/// 地方」与「仍用原生 Slider 的地方」外观完全一致 ——
/// 全应用只有这一处滑块规格定义（见文件头注释）。
///
/// 注意 `glassTrack`：原生 Slider 没有地方放 [AppTrackGlass]（那需要一层 widget），
/// 所以默认 false —— 此时未填充段用一块近似毛玻璃的**半透明白**实心填充兜底，
/// 观感与玻璃几乎一致；`AppSlider` / `AppRangeSlider` 传 true，留空段改由真正的
/// 高斯模糊层负责。
SliderThemeData appSliderThemeFor(
  ColorScheme scheme, {
  bool compact = false,
  Color? accent,
  bool glassTrack = false,
}) => _appSliderTheme(
  scheme: scheme,
  accent: accent ?? scheme.primary,
  trackHeight: compact ? kAppCompactTrackHeight : kAppTrackHeight,
  glassTrack: glassTrack,
);

/// 构造整套滑块主题（单值 / 区间共用）。
///
/// 只显式给「配色 + 三个形状」，其余字段留 null：framework 会用
/// `sliderTheme.xxx ?? defaults.xxx` 填默认值，所以禁用态颜色、tickMark、
/// 数值气泡等仍然沿用 Material 默认，不会因为这里少写而变成 null。
SliderThemeData _appSliderTheme({
  required ColorScheme scheme,
  required Color accent,
  required double trackHeight,
  required bool glassTrack,
  _SliderCometMotion? comet,
}) {
  final bool isDark = scheme.brightness == Brightness.dark;
  // 细描边用白色系：玻璃底与填充都是浅/主题色，一道浅色描边能把边界勾出来。
  final Color borderColor = Colors.white.withAlpha(isDark ? 46 : 150);
  return SliderThemeData(
    trackHeight: trackHeight,
    activeTrackColor: accent,
    // 玻璃模式下必须是**透明**：未填充段由 AppTrackGlass 画（含真实模糊），
    // 这里再填一块实色就把玻璃盖住了。
    inactiveTrackColor: glassTrack
        ? Colors.transparent
        : Colors.white.withAlpha(isDark ? 28 : 104),
    thumbColor: accent,
    overlayColor: accent.withAlpha(_kOverlayAlpha),
    // 没有圆点把手：填充段的边缘就是把手（参考图如此）。
    thumbShape: const _HiddenThumbShape(),
    trackShape: _CapsuleTrackShape(
      glass: glassTrack,
      borderColor: borderColor,
      comet: comet,
    ),
    rangeThumbShape: const _HiddenRangeThumbShape(),
    rangeTrackShape: _CapsuleRangeTrackShape(
      glass: glassTrack,
      borderColor: borderColor,
      comet: comet,
    ),
    // 不要按下时的圆形光晕，但也不能用 SliderComponentShape.noOverlay：
    // overlay 的尺寸参与 framework 的固有高度计算（见 _kSliderPlaceholder）。
    overlayShape: const _InvisibleOverlayShape(_kSliderPlaceholder),
    // 离散刻度的默认形状是 RoundSliderTickMarkShape（⌀4 圆点）；用户要「不要圆」，
    // 因此关闭刻度点（divisions 的吸附行为不受影响）。
    tickMarkShape: SliderTickMarkShape.noTickMark,
  );
}

// ═══════════════════════════════════════════
// AppSlider：单值滑块
// ═══════════════════════════════════════════

/// 统一的单值滑块。参数与 framework 的 [Slider] 对齐，
/// 只是外观固定为项目统一规格（见文件头注释）。
///
/// 与 [Slider] 的行为差异只有一处：**非拖动状态下** value 被外部改动时，
/// thumb 用 [_kValueAnimationDuration] 平滑滑到新值；拖动过程中则完全跟手。
///
/// 节流语义不受影响：本组件不缓存、不延迟 [onChanged] / [onChangeEnd]，
/// 调用方仍然可以「拖动只改本地 state、onChangeEnd 才写全局配置」（见
/// ai_settings_mobile.dart 的 _TemperatureSlider），也可以像步骤编辑器那样
/// 每次 onChanged 都写参数，二者都保持原样。
class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
    this.onChanged,
    this.onChangeEnd,
    this.color,
    this.compact = false,
    this.particles = true,
  });

  /// 当前值（受控，由调用方持有，与 [Slider.value] 语义一致）。
  final double value;

  /// 最小值，默认 0。
  final double min;

  /// 最大值，默认 1。
  final double max;

  /// 分段数（非 null 时为离散滑块，会显示刻度并吸附）。
  final int? divisions;

  /// 数值气泡文案（显示在 thumb 上方）。
  final String? label;

  /// 值变化回调；为 null 时滑块禁用。
  final ValueChanged<double>? onChanged;

  /// 拖动结束回调（framework 的 onChangeEnd 语义，用于「松手才提交」）。
  final ValueChanged<double>? onChangeEnd;

  /// 覆盖主题色。用于「滑块本身就是颜色」的场景（字幕编辑器的色相/饱和度/亮度条）。
  final Color? color;

  /// 紧凑尺寸（轨道 11 / 填充与轨道同高），用于密集表单。
  /// 默认 false：统一规格就是 [kAppTrackHeight]，除确有必要不要打开。
  final bool compact;

  /// 拖动时是否允许彗星拖尾（调用方想单独关掉时用；全局开关在设置 → 样式）。
  final bool particles;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> with TickerProviderStateMixin {
  /// 拖动中的本地值。非 null 表示用户正在拖动 —— 此时直接跟手、不做数值动画，
  /// 既避免填充边缘落后手指，也避免和上层回传的 value 互相打架
  /// （上层可能只在 onChangeEnd 才写全局配置，拖动期间 value 根本不变）。
  double? _dragValue;
  double? _lastDragValue;
  late final _SliderCometMotion _comet;

  /// 实际绘制出来的值：拖动时 = 手指值，其余时候 = 数值动画的当前帧。
  late double _shown = _clamp(widget.value);

  // 在 initState 里创建（而不是用 late 字段初始化器）：late 只在首次访问时才求值，
  // 若组件在首次 build 前就被移除，dispose() 反而会创建一个已失效的 Ticker。
  late final AnimationController _valueController;

  Animation<double>? _valueTween;

  double _clamp(double v) =>
      v < widget.min ? widget.min : (v > widget.max ? widget.max : v);

  @override
  void initState() {
    super.initState();
    _valueController = AnimationController(
      vsync: this,
      duration: _kValueAnimationDuration,
    );
    _valueController.addListener(_handleValueTick);
    _comet = _SliderCometMotion(this);
  }

  void _handleValueTick() {
    final Animation<double>? tween = _valueTween;
    if (!mounted || tween == null) return;
    setState(() => _shown = _clamp(tween.value));
  }

  @override
  void didUpdateWidget(covariant AppSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有「非拖动状态下 value 被外部改动」才做平滑动画：重置按钮、预设 chip、
    // 从配置里载入数值等场景，填充边缘滑过去而不是瞬移。
    if (widget.value != oldWidget.value && _dragValue == null) {
      _animateTo(widget.value);
    }
  }

  void _animateTo(double target) {
    final double to = _clamp(target);
    if (MediaQuery.disableAnimationsOf(context)) {
      _valueController.stop();
      _valueTween = null;
      _shown = to;
      return;
    }
    if ((to - _shown).abs() < 1e-9) {
      // 直接赋值即可：本方法只从 didUpdateWidget 调用，之后紧接着就是本组件的重建，
      // 不需要（也不应该在 build 期间）再 setState。
      _shown = to;
      return;
    }
    _valueTween = Tween<double>(begin: _shown, end: to).animate(
      CurvedAnimation(parent: _valueController, curve: Curves.easeOutCubic),
    );
    _valueController.forward(from: 0);
  }

  @override
  void dispose() {
    _comet.dispose();
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = widget.color ?? scheme.primary;
    final double trackHeight = widget.compact
        ? kAppCompactTrackHeight
        : kAppTrackHeight;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool cometOn =
        _trackCfgOf(context).particles &&
        widget.particles &&
        widget.onChanged != null &&
        !reduceMotion;
    _comet.setEnabled(cometOn);
    if (reduceMotion && _valueController.isAnimating) {
      _valueController.stop();
      _valueTween = null;
      _shown = _clamp(widget.value);
    }

    return SliderTheme(
      data: _appSliderTheme(
        scheme: scheme,
        accent: accent,
        trackHeight: trackHeight,
        glassTrack: true,
        comet: cometOn ? _comet : null,
      ),
      child: Stack(
        children: [
          // 轨道留空段的玻璃（在最底层：Slider 只画填充段，压在上面）。
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: _kTrackInsetX,
                  ),
                  child: AppTrackGlass(height: trackHeight),
                ),
              ),
            ),
          ),
          Slider(
            value: _clamp(_dragValue ?? _shown),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: widget.label,
            onChangeStart: (double value) {
              _lastDragValue = value;
              _comet.reset();
              _valueController.stop();
            },
            onChanged: widget.onChanged == null
                ? null
                : (double value) {
                    final span = widget.max - widget.min;
                    if (_lastDragValue case final previous? when span > 0) {
                      _comet.move((value - previous) / span);
                      _lastDragValue = value;
                    }
                    setState(() {
                      _dragValue = value;
                      _shown = _clamp(value);
                    });
                    // 拖动期间停掉数值动画，保证完全跟手。
                    _valueController.stop();
                    widget.onChanged!(value);
                  },
            onChangeEnd: (double value) {
              _lastDragValue = null;
              _comet.release();
              setState(() {
                _dragValue = null;
                _shown = _clamp(value);
              });
              widget.onChangeEnd?.call(value);
            },
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// AppRangeSlider：双滑块
// ═══════════════════════════════════════════

/// 统一的双滑块（区间）组件，外观与 [AppSlider] 一致：两个 thumb 之间是主题色
/// 实心胶囊，两端未选中的部分是玻璃。
///
/// 除外观外完全等同于 framework 的 [RangeSlider]（含 minThumbSeparation、
/// divisions 吸附、labels 气泡），因此调用方只需把 `RangeSlider(` 换成
/// `AppRangeSlider(` 并补上 import。
class AppRangeSlider extends StatefulWidget {
  const AppRangeSlider({
    super.key,
    required this.values,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.labels,
    this.onChanged,
    this.onChangeEnd,
    this.color,
    this.compact = false,
    this.particles = true,
  });

  /// 当前区间。
  final RangeValues values;

  final double min;
  final double max;

  /// 分段数（非 null 时为离散，会吸附并显示刻度）。
  final int? divisions;

  /// 两个 thumb 的气泡文案。
  final RangeLabels? labels;

  /// 区间变化回调；为 null 时禁用。
  final ValueChanged<RangeValues>? onChanged;

  /// 拖动结束回调。
  final ValueChanged<RangeValues>? onChangeEnd;

  /// 覆盖主题色。
  final Color? color;

  /// 紧凑尺寸（与 [AppSlider.compact] 同义）。
  final bool compact;

  /// 拖动时是否允许彗星拖尾。
  final bool particles;

  @override
  State<AppRangeSlider> createState() => _AppRangeSliderState();
}

class _AppRangeSliderState extends State<AppRangeSlider>
    with SingleTickerProviderStateMixin {
  bool _dragging = false;

  /// 保留本地区间，保证上层仅在 onChangeEnd 写回时也能跟手。
  RangeValues? _dragValues;
  RangeValues? _lastDragValues;
  late final _SliderCometMotion _comet;

  @override
  void initState() {
    super.initState();
    _comet = _SliderCometMotion(this);
  }

  @override
  void didUpdateWidget(covariant AppRangeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final RangeValues? local = _dragValues;
    if (local == null || _dragging) return;
    // 上层已追上 -> 交回受控值；外部显式改动（预设/重置）-> 同样以外部为准。
    // 注意不能在 onChangeEnd 里立刻清：上层可能异步写回，清了 thumb 会回弹。
    if (widget.values == local || widget.values != oldWidget.values) {
      _dragValues = null;
    }
  }

  @override
  void dispose() {
    _comet.dispose();
    super.dispose();
  }

  void _updateComet(RangeValues values) {
    final span = widget.max - widget.min;
    if (_lastDragValues case final previous? when span > 0) {
      final startDelta = values.start - previous.start;
      final endDelta = values.end - previous.end;
      // RangeSlider reports both values. Once one changes, use that handle as
      // the head. A stationary press leaves the handle undetermined.
      if (startDelta.abs() > endDelta.abs()) {
        _comet.move(startDelta / span, thumb: Thumb.start);
      } else {
        _comet.move(endDelta / span);
      }
      _lastDragValues = values;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = widget.color ?? scheme.primary;
    final double trackHeight = widget.compact
        ? kAppCompactTrackHeight
        : kAppTrackHeight;
    final bool cometOn =
        _trackCfgOf(context).particles &&
        widget.particles &&
        widget.onChanged != null &&
        !MediaQuery.disableAnimationsOf(context);
    _comet.setEnabled(cometOn);
    final RangeValues shown = _dragValues ?? widget.values;

    return SliderTheme(
      data: _appSliderTheme(
        scheme: scheme,
        accent: accent,
        trackHeight: trackHeight,
        glassTrack: true,
        comet: cometOn ? _comet : null,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: _kTrackInsetX,
                  ),
                  child: AppTrackGlass(height: trackHeight),
                ),
              ),
            ),
          ),
          RangeSlider(
            values: shown,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            labels: widget.labels,
            onChangeStart: (values) {
              _lastDragValues = values;
              _comet.reset();
              _dragging = true;
            },
            onChanged: widget.onChanged == null
                ? null
                : (RangeValues values) {
                    _updateComet(values);
                    setState(() => _dragValues = values);
                    widget.onChanged!(values);
                  },
            onChangeEnd: (RangeValues values) {
              _lastDragValues = null;
              _comet.release();
              setState(() {
                _dragging = false;
                // 保留最后值，等上层写回后再由 didUpdateWidget 交还控制权。
                _dragValues = values;
              });
              widget.onChangeEnd?.call(values);
            },
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 进度条
// ═══════════════════════════════════════════

/// 统一进度条，与滑块共用胶囊轨道和 [_drawComet] 高光。
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    this.value,
    this.color,
    this.backgroundColor,
    this.height = kAppTrackHeight,
    this.animationDuration = const Duration(milliseconds: 220),
    this.semanticsLabel,
  });

  /// 进度 0..1；null 表示不确定进度。
  final double? value;

  /// 进度色，默认主题色。
  final Color? color;

  /// 轨道色。null = 走统一玻璃底；显式传入时用该实色（例如需要与底色形成对比）。
  final Color? backgroundColor;

  /// 轨道高度，默认 [kAppTrackHeight]（与滑块一致，不要轻易改）。
  final double height;

  /// 确定进度的过渡时长。
  final Duration animationDuration;

  /// 无障碍标签（例如「下载进度」）。
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color barColor = color ?? scheme.primary;
    final double? v = value;
    final Color? trackColor = backgroundColor;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final TextDirection textDirection = Directionality.of(context);
    // 「设置 → 样式 → 彗星拖尾」现在是**全局**开关：滑块、确定进度、
    // 不确定进度、开屏加载条都走同一条 [_drawComet]。关掉后连绘制都不做
    // （不是画完再透明），低配设备能真正省掉这部分开销。
    final bool cometOn = _trackCfgOf(context).particles && !reduceMotion;

    // 显式指定了轨道色 → 用实色（旧行为，兼容调用方）；否则用统一玻璃底。
    final Widget track = trackColor != null
        ? SizedBox(
            height: height,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: trackColor,
                borderRadius: BorderRadius.circular(height / 2),
              ),
            ),
          )
        : AppTrackGlass(height: height);

    return Semantics(
      label: semanticsLabel,
      value: v == null ? null : '${(v.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            track,
            if (v == null)
              _IndeterminateBar(
                color: barColor,
                animate: !reduceMotion,
                textDirection: textDirection,
                showComet: cometOn,
              )
            else
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: v.clamp(0.0, 1.0)),
                duration: reduceMotion ? Duration.zero : animationDuration,
                curve: Curves.easeOutCubic,
                builder:
                    (BuildContext context, double animated, Widget? child) =>
                        CustomPaint(
                          painter: _AppProgressBarPainter(
                            valueColor: barColor,
                            value: animated,
                            textDirection: textDirection,
                            showComet: cometOn,
                          ),
                        ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Paints a capsule fill and its restrained leading-edge comet highlight.
class _AppProgressBarPainter extends CustomPainter {
  const _AppProgressBarPainter({
    required this.valueColor,
    required this.value,
    required this.textDirection,
    this.showComet = true,
  });

  final Color valueColor;
  final double value;
  final TextDirection textDirection;

  /// 「设置 → 样式 → 彗星拖尾」：关闭时只画纯胶囊填充，不画光带与光晕。
  final bool showComet;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double fillWidth = size.width * value.clamp(0.0, 1.0);
    if (fillWidth <= 0.01) return;

    final bool isLtr = textDirection == TextDirection.ltr;
    final double fillLeft = isLtr ? 0 : size.width - fillWidth;
    final double fillRight = isLtr ? fillWidth : size.width;
    final RRect fill = RRect.fromRectAndRadius(
      Rect.fromLTRB(fillLeft, 0, fillRight, size.height),
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(fill, Paint()..color = valueColor);

    if (showComet) {
      _drawComet(canvas, fill: fill, headAtLeft: !isLtr, fillColor: valueColor);
    }
  }

  @override
  bool shouldRepaint(_AppProgressBarPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.valueColor != valueColor ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.showComet != showComet;
}

/// Paints a single highlight with a round head and a short, tapered tail.
///
/// The head touches its fill edge on the centreline. The tail always extends
/// into the fill, including when the value moves towards its origin.
void _drawComet(
  Canvas canvas, {
  required RRect fill,
  required bool headAtLeft,
  required Color fillColor,
  double speed = 0,
  double opacity = 1,
}) {
  if (fill.width <= 0.5 || fill.height <= 0 || opacity <= 0) {
    return;
  }
  final height = fill.height;
  final maxLength = math.min(56.0, height * (2.2 + 1.15 * speed));
  final length = math.min(fill.width, maxLength);
  final headX = headAtLeft ? fill.left : fill.right;
  final tailDirection = headAtLeft ? 1.0 : -1.0;
  final centerY = fill.center.dy;
  double xAt(double distance) => headX + distance * tailDirection;

  final tailX = xAt(length);
  final shoulder = math.min(length * 0.28, height * 0.56);
  final shoulderX = xAt(shoulder);
  final taperX = xAt(shoulder + (length - shoulder) * 0.24);
  final tipControlX = xAt(length * 0.68);
  final halfHeight = height * (0.29 + 0.04 * speed);
  final top = centerY - halfHeight;
  final bottom = centerY + halfHeight;
  final profile = Path()
    ..moveTo(tailX, centerY)
    ..cubicTo(tipControlX, centerY, taperX, top, shoulderX, top)
    ..quadraticBezierTo(headX, top, headX, centerY)
    ..quadraticBezierTo(headX, bottom, shoulderX, bottom)
    ..cubicTo(taperX, bottom, tipControlX, centerY, tailX, centerY)
    ..close();

  // A white highlight reads as light on every theme. Reduce its contrast on
  // already light fills so the edge retains the original accent colour.
  final contrast = fillColor.computeLuminance() > 0.62 ? 0.72 : 1.0;
  final peak = contrast * (0.58 + 0.09 * speed) * opacity;
  final light = Paint()
    ..shader = ui.Gradient.linear(
      Offset(tailX, centerY),
      Offset(headX, centerY),
      [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: peak * 0.16),
        Colors.white.withValues(alpha: peak * 0.58),
        Colors.white.withValues(alpha: peak),
      ],
      const [0, 0.40, 0.76, 1],
    );
  canvas.save();
  canvas.clipRRect(fill);
  canvas.drawPath(profile, light);
  canvas.restore();
}

/// Static or animated indeterminate progress; static mode creates no ticker.
///
/// The comet is clipped to the capsule so it never paints square ends outside
/// the track. The track itself is supplied by [AppTrackGlass].
class _IndeterminateBar extends StatefulWidget {
  const _IndeterminateBar({
    required this.color,
    required this.animate,
    required this.textDirection,
    this.showComet = true,
  });

  final Color color;
  final bool animate;
  final TextDirection textDirection;

  /// 「设置 → 样式 → 彗星拖尾」的全局开关。
  final bool showComet;

  @override
  State<_IndeterminateBar> createState() => _IndeterminateBarState();
}

class _IndeterminateBarState extends State<_IndeterminateBar>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant _IndeterminateBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.animate) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: _kIndeterminateDurationMs),
      );
      _controller!.repeat();
    } else {
      // A SingleTickerProvider can create only one ticker over its lifetime.
      // Keep the controller for subsequent accessibility preference changes.
      _controller?.stop();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.infinite,
    painter: _IndeterminateBarPainter(
      valueColor: widget.color,
      animation: widget.animate ? _controller : null,
      textDirection: widget.textDirection,
      staticPhase: 0.5,
      showComet: widget.showComet,
    ),
  );
}

/// Moves a single comet across the track, reversing in RTL layouts.
class _IndeterminateBarPainter extends CustomPainter {
  _IndeterminateBarPainter({
    required this.valueColor,
    required this.animation,
    required this.textDirection,
    required this.staticPhase,
    this.showComet = true,
  }) : super(repaint: animation);

  final Color valueColor;
  final Animation<double>? animation;
  final TextDirection textDirection;
  final double staticPhase;
  final bool showComet;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final RRect track = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    final bool isLtr = textDirection == TextDirection.ltr;
    final double cometLength = math.min(
      size.width,
      math.max(size.height * 2.2, size.width * 0.26),
    );
    final double phase = (animation?.value ?? staticPhase).clamp(0.0, 1.0);
    final double headX = isLtr
        ? -cometLength + (size.width + cometLength * 2) * phase
        : size.width + cometLength - (size.width + cometLength * 2) * phase;
    final double tailX = headX + (isLtr ? -cometLength : cometLength);
    final fill = RRect.fromRectAndRadius(
      Rect.fromLTRB(
        math.min(tailX, headX),
        0,
        math.max(tailX, headX),
        size.height,
      ),
      Radius.circular(size.height / 2),
    );
    if (fill.right <= 0 || fill.left >= size.width) {
      return;
    }
    canvas.save();
    canvas.clipRRect(track);
    // Loading remains visible when the optional decoration is disabled.
    canvas.drawRRect(fill, Paint()..color = valueColor);
    if (showComet) {
      _drawComet(canvas, fill: fill, headAtLeft: !isLtr, fillColor: valueColor);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IndeterminateBarPainter oldDelegate) =>
      oldDelegate.valueColor != valueColor ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.staticPhase != staticPhase ||
      oldDelegate.animation != animation ||
      oldDelegate.showComet != showComet;
}
