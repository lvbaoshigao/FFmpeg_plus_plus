import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import 'liquid_glass_fallback.dart' show effectiveGlassSigma;

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
// 唯一自绘的是 [AppProgressBar]：它的几何（高度、圆角）以及「是否画末尾停止点」
// 由 SDK 版本 / 主题决定，无法保证与滑块视觉一致，所以自己画圆角轨道 + 进度，
// 并用 TweenAnimationBuilder 做平滑过渡。

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

/// 进度条不确定态（来回滑动）一个周期的时长。
/// 与 framework 的 `_kIndeterminateLinearDuration` 保持一致：它的四条缓动曲线
/// 直接搬过来（见 [_IndeterminateBarPainter]），这样不确定进度的节奏与系统一致。
const int _kIndeterminateDurationMs = 1800;

// ── 拖动星点特效 ──
//
// 用户要求：「拖动时增加粒子特效，就是随机的星星向左滑动（同时兼顾性能）」。
// 性能约定（改这里前先读）：
// * 只在拖动期间 `repeat()`，松手后 [_kStarFadeOut] 内淡出并 `stop()` ——
//   静止时**不建绘制层、不起 Ticker**，零帧开销；
// * 固定 [_kStarCount] 颗星的池子，位置由时间差积分算出，没有逐星 widget、
//   没有逐帧 setState；
// * 星点层单独包 RepaintBoundary：每帧只脏自己这一层，不牵连 Slider 与卡片；
// * 只在填充段内绘制（含淡入淡出），因此星点永远落在主题色块上，白星对比度足够；
// * 设置里可关闭（`AppConfig.sliderStars`），系统开启「减弱动态效果」时也自动关闭。
const int _kStarCount = 14;
const double _kStarLifeMin = 0.55;
const double _kStarLifeMax = 1.05;
const double _kStarSpeedMin = 46;
const double _kStarSpeedMax = 132;
const Duration _kStarFadeOut = Duration(milliseconds: 260);

/// 单帧最大积分步长：页面卡顿/后台回来时不要让星点「瞬移」。
const double _kStarMaxStep = 0.05;

// ═══════════════════════════════════════════
// 表面配置指纹（玻璃 / 星点开关）
// ═══════════════════════════════════════════

/// 轨道渲染所需的配置指纹：只订阅影响渲染的字段，
/// 进度 / 日志等高频 notify 不会重建滑块（与 AppCard 的 `_CardGlassKey` 同一思路）。
@immutable
class _TrackCfg {
  /// 「样式 → 不使用卡片玻璃效果」：不做高斯模糊，退回半透明底色（低配省电档）。
  final bool noGlass;

  /// 「样式 → 玻璃底色遵循主题色」：玻璃底色改用主题色而不是白/灰。
  final bool follow;

  /// 「样式 → 滑块星点特效」：拖动时是否出现星点。
  final bool stars;

  const _TrackCfg({required this.noGlass, required this.follow, required this.stars});

  @override
  bool operator ==(Object other) =>
      other is _TrackCfg &&
      other.noGlass == noGlass &&
      other.follow == follow &&
      other.stars == stars;

  @override
  int get hashCode => Object.hash(noGlass, follow, stars);
}

_TrackCfg _trackCfgOf(BuildContext context) => context.select<AppState, _TrackCfg>(
      (s) => _TrackCfg(
        noGlass: s.config.noCardGlass,
        follow: s.config.glassFollowTheme,
        stars: s.config.sliderStars,
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
          filter: ImageFilter.blur(
            sigmaX: effectiveGlassSigma(_kTrackGlassSigma),
            sigmaY: effectiveGlassSigma(_kTrackGlassSigma),
          ),
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
}) {
  final Radius radius = Radius.circular(trackRect.height / 2);

  // ── 未填充段 ──
  // glass = true 时不画：留空段由 AppTrackGlass 提供（含真实高斯模糊），
  // 这里再画一层会把玻璃盖住。
  if (!glass) {
    canvas.drawRRect(RRect.fromRectAndRadius(trackRect, radius), Paint()..color = inactiveColor);
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
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTRB(left, trackRect.top, right, trackRect.bottom),
      radius,
    ),
    Paint()..color = activeColor,
  );
}

/// 单值滑块轨道：胶囊形，只画已填充段。
class _CapsuleTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _CapsuleTrackShape({required this.glass, required this.borderColor});

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
  }) =>
      _capsuleRect(
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
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) return;
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final Color inactive = ColorTween(
          begin: sliderTheme.disabledInactiveTrackColor,
          end: sliderTheme.inactiveTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;
    final Color active = ColorTween(
          begin: sliderTheme.disabledActiveTrackColor,
          end: sliderTheme.activeTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;

    // LTR：填充段从轨道左端长到 thumb 中心；RTL：从右端长过去。
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
    );
  }
}

/// 区间滑块轨道：胶囊形；两个 thumb 之间为已填充段。
///
/// 注意基类是 [RangeSliderTrackShape]（与 [SliderTrackShape] 不通用）：
/// 它的 paint 多出 endThumbCenter、且**没有** additionalActiveTrackHeight。
class _CapsuleRangeTrackShape extends RangeSliderTrackShape with BaseSliderTrackShape {
  const _CapsuleRangeTrackShape({required this.glass, required this.borderColor});

  final bool glass;
  final Color borderColor;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) =>
      _capsuleRect(
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
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) return;
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final Color inactive = ColorTween(
          begin: sliderTheme.disabledInactiveTrackColor,
          end: sliderTheme.inactiveTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;
    final Color active = ColorTween(
          begin: sliderTheme.disabledActiveTrackColor,
          end: sliderTheme.activeTrackColor,
        ).evaluate(enableAnimation) ??
        Colors.transparent;

    _paintCapsuleTrack(
      context.canvas,
      trackRect: trackRect,
      glass: glass,
      inactiveColor: inactive,
      activeColor: active,
      borderColor: borderColor,
      activeFrom: startThumbCenter,
      activeTo: endThumbCenter,
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
}) =>
    _appSliderTheme(
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
}) {
  final bool isDark = scheme.brightness == Brightness.dark;
  // 细描边用白色系：玻璃底与填充都是浅/主题色，一道浅色描边能把边界勾出来。
  final Color borderColor = Colors.white.withAlpha(isDark ? 46 : 150);
  return SliderThemeData(
    trackHeight: trackHeight,
    activeTrackColor: accent,
    // 玻璃模式下必须是**透明**：未填充段由 AppTrackGlass 画（含真实模糊），
    // 这里再填一块实色就把玻璃盖住了。
    inactiveTrackColor:
        glassTrack ? Colors.transparent : Colors.white.withAlpha(isDark ? 28 : 104),
    thumbColor: accent,
    overlayColor: accent.withAlpha(_kOverlayAlpha),
    // 没有圆点把手：填充段的边缘就是把手（参考图如此）。
    thumbShape: const _HiddenThumbShape(),
    trackShape: _CapsuleTrackShape(glass: glassTrack, borderColor: borderColor),
    rangeThumbShape: const _HiddenRangeThumbShape(),
    rangeTrackShape:
        _CapsuleRangeTrackShape(glass: glassTrack, borderColor: borderColor),
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
    this.stars = true,
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

  /// 拖动时是否允许星点特效（调用方想单独关掉时用；全局开关在设置 → 样式）。
  final bool stars;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> with SingleTickerProviderStateMixin {
  /// 拖动中的本地值。非 null 表示用户正在拖动 —— 此时直接跟手、不做数值动画，
  /// 既避免填充边缘落后手指，也避免和上层回传的 value 互相打架
  /// （上层可能只在 onChangeEnd 才写全局配置，拖动期间 value 根本不变）。
  double? _dragValue;

  /// 实际绘制出来的值：拖动时 = 手指值，其余时候 = 数值动画的当前帧。
  late double _shown = _clamp(widget.value);

  // 在 initState 里创建（而不是用 late 字段初始化器）：late 只在首次访问时才求值，
  // 若组件在首次 build 前就被移除，dispose() 反而会创建一个已失效的 Ticker。
  late final AnimationController _valueController;

  Animation<double>? _valueTween;

  double _clamp(double v) => v < widget.min ? widget.min : (v > widget.max ? widget.max : v);

  /// 填充比例 0..1（= 参考图里黑色部分的占比）。
  double get _fillFraction {
    final double span = widget.max - widget.min;
    if (span <= 0) return 0;
    return ((_dragValue ?? _shown) - widget.min) / span;
  }

  @override
  void initState() {
    super.initState();
    _valueController = AnimationController(vsync: this, duration: _kValueAnimationDuration);
    _valueController.addListener(_handleValueTick);
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
    if ((to - _shown).abs() < 1e-9) {
      // 直接赋值即可：本方法只从 didUpdateWidget 调用，之后紧接着就是本组件的重建，
      // 不需要（也不应该在 build 期间）再 setState。
      _shown = to;
      return;
    }
    _valueTween = Tween<double>(begin: _shown, end: to)
        .animate(CurvedAnimation(parent: _valueController, curve: Curves.easeOutCubic));
    _valueController.forward(from: 0);
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = widget.color ?? scheme.primary;
    final double trackHeight = widget.compact ? kAppCompactTrackHeight : kAppTrackHeight;
    final _TrackCfg cfg = _trackCfgOf(context);
    // 星点颜色跟填充段的明暗走：浅色填充配深色星点，否则白星在浅色块上不可见。
    // 系统开启「减弱动态效果」时完全不做特效（无障碍 + 省电）。
    final bool starsOn = widget.stars &&
        cfg.stars &&
        !MediaQuery.disableAnimationsOf(context);

    return SliderTheme(
      data: appSliderThemeFor(scheme, compact: widget.compact, accent: accent, glassTrack: true),
      child: Stack(
        // 只让 Slider 决定尺寸；玻璃层与星点层都是 Positioned.fill 的纯装饰层。
        children: [
          // ① 轨道留空段的玻璃（在最底层：Slider 只画填充段，压在上面）
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _kTrackInsetX),
                  child: AppTrackGlass(height: trackHeight),
                ),
              ),
            ),
          ),
          // ② 滑块本体（命中区域、拖拽、键盘、无障碍都由 framework 负责）
          Slider(
            value: _clamp(_dragValue ?? _shown),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: widget.label,
            onChanged: widget.onChanged == null
                ? null
                : (double nv) {
                    setState(() {
                      _dragValue = nv;
                      _shown = _clamp(nv);
                    });
                    // 拖动期间停掉数值动画，保证完全跟手。
                    _valueController.stop();
                    widget.onChanged!(nv);
                  },
            onChangeEnd: (double nv) {
              setState(() {
                _dragValue = null;
                _shown = _clamp(nv);
              });
              widget.onChangeEnd?.call(nv);
            },
          ),
          // ③ 拖动时的星点（纯前景装饰，IgnorePointer 保证不抢手势）
          if (starsOn)
            Positioned.fill(
              child: IgnorePointer(
                child: _StarLayer(
                  active: _dragValue != null,
                  fillStart: 0,
                  fillEnd: _fillFraction.clamp(0.0, 1.0),
                  trackHeight: trackHeight,
                  color: accent.computeLuminance() > 0.55 ? Colors.black : Colors.white,
                ),
              ),
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
    this.stars = true,
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

  /// 拖动时是否允许星点特效。
  final bool stars;

  @override
  State<AppRangeSlider> createState() => _AppRangeSliderState();
}

class _AppRangeSliderState extends State<AppRangeSlider> {
  /// 是否有手指按在任一端（决定星点是否飘散）。
  bool _dragging = false;

  double _fractionOf(double v) {
    final double span = widget.max - widget.min;
    if (span <= 0) return 0;
    return ((v - widget.min) / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = widget.color ?? scheme.primary;
    final double trackHeight =
        widget.compact ? kAppCompactTrackHeight : kAppTrackHeight;
    final _TrackCfg cfg = _trackCfgOf(context);
    final bool starsOn = widget.stars &&
        cfg.stars &&
        !MediaQuery.disableAnimationsOf(context);

    return SliderTheme(
      data: appSliderThemeFor(scheme,
          compact: widget.compact, accent: accent, glassTrack: true),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _kTrackInsetX),
                  child: AppTrackGlass(height: trackHeight),
                ),
              ),
            ),
          ),
          RangeSlider(
            values: widget.values,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            labels: widget.labels,
            onChangeStart: (_) => setState(() => _dragging = true),
            onChanged: widget.onChanged,
            onChangeEnd: (RangeValues v) {
              setState(() => _dragging = false);
              widget.onChangeEnd?.call(v);
            },
          ),
          if (starsOn)
            Positioned.fill(
              child: IgnorePointer(
                child: _StarLayer(
                  active: _dragging,
                  fillStart: _fractionOf(widget.values.start),
                  fillEnd: _fractionOf(widget.values.end),
                  trackHeight: trackHeight,
                  color: accent.computeLuminance() > 0.55 ? Colors.black : Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════
// 拖动星点粒子
// ═══════════════════════════════════════════

/// 一颗星点的全部状态（固定池子里的元素，反复复用，不新建对象）。
class _Star {
  double x = 0;
  double y = 0;
  double size = 3;
  double speed = 80;
  double life = 0;
  double lifeMax = 0.8;
  double rot = 0;
  double spin = 0;

  /// 是否已被首次点亮（未点亮的星点不参与绘制，避免开局一堆星挤在边界上）。
  bool alive = false;
}

/// 星点池：按时间步长积分推进所有星点，出界即回到「填充边界」重新发射。
///
/// 放在 State 里持有、由 painter 复用（painter 每帧会被重建，池子不能跟着重建，
/// 否则每帧都会重新随机、星点看起来是闪烁的噪声）。
class _StarField {
  _StarField(this._rnd);

  final math.Random _rnd;
  final List<_Star> stars = List<_Star>.generate(_kStarCount, (_) => _Star());

  /// 上一次积分的时间戳（秒）。
  double lastT = 0;

  /// 是否已按「首次绘制」铺开过整池星点。
  bool _seeded = false;

  void reset() {
    lastT = 0;
    _seeded = false;
    for (final _Star s in stars) {
      s.alive = false;
      s.life = 0;
    }
  }

  void _respawn(_Star s, double boundaryX, double halfHeight) {
    // 从填充边界稍靠左的位置「喷」出来：拖动时星点像是被把手甩出去的。
    s.x = boundaryX - _rnd.nextDouble() * 6;
    // 竖直方向限制在胶囊内部（±0.42 半高），避免星点被圆角裁掉一半。
    s.y = (_rnd.nextDouble() * 2 - 1) * halfHeight * 0.42;
    s.size = 2.2 + _rnd.nextDouble() * 2.6;
    s.speed = _kStarSpeedMin + _rnd.nextDouble() * (_kStarSpeedMax - _kStarSpeedMin);
    s.lifeMax = _kStarLifeMin + _rnd.nextDouble() * (_kStarLifeMax - _kStarLifeMin);
    // 给一点初始寿命：避免松手瞬间 14 颗星同一亮度、看起来像闪一下。
    s.life = _rnd.nextDouble() * s.lifeMax * 0.5;
    s.rot = _rnd.nextDouble() * math.pi * 2;
    s.spin = (_rnd.nextDouble() * 2 - 1) * 1.8;
    s.alive = true;
  }

  /// 拖动开始时把整池星点铺开：位置从边界向左随机散布、年龄也随机，
  /// 于是第一帧就是一条「已流动起来」的星带，而不是 14 颗星挤在把手处齐闪。
  void _seed(double boundaryX, double halfHeight) {
    for (final _Star s in stars) {
      _respawn(s, boundaryX, halfHeight);
      s.life = _rnd.nextDouble() * s.lifeMax;
      s.x -= _rnd.nextDouble() * s.speed * s.lifeMax;
    }
    _seeded = true;
  }

  /// 推进 [dt] 秒；[boundaryX] 是当前填充段的边界（像素，轨道局部坐标）。
  void advance(double dt, double boundaryX, double halfHeight) {
    if (!_seeded) {
      _seed(boundaryX, halfHeight);
      return;
    }
    for (final _Star s in stars) {
      if (!s.alive) {
        _respawn(s, boundaryX, halfHeight);
        continue;
      }
      s.life += dt;
      s.x -= s.speed * dt;
      s.rot += s.spin * dt;
      if (s.life >= s.lifeMax || s.x < -s.size * 2) {
        _respawn(s, boundaryX, halfHeight);
      }
    }
  }
}

/// 四角星（菱形闪光）的**单位路径**（半径 1，中心原点）。
/// 每颗星只做一次 translate/rotate/scale + drawPath，不重复构造 Path。
final Path _kStarPath = Path()
  ..moveTo(0, -1)
  ..lineTo(0.19, -0.19)
  ..lineTo(1, 0)
  ..lineTo(0.19, 0.19)
  ..lineTo(0, 1)
  ..lineTo(-0.19, 0.19)
  ..lineTo(-1, 0)
  ..lineTo(-0.19, -0.19)
  ..close();

/// 星点画笔：每帧只做「积分推进 + 14 次 drawPath」，无分配、无 saveLayer。
class _StarPainter extends CustomPainter {
  _StarPainter({
    required this.field,
    required this.controller,
    required this.fade,
    required this.fillStart,
    required this.fillEnd,
    required this.color,
    required this.textDirection,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _StarField field;
  final AnimationController controller;
  final AnimationController fade;
  final double fillStart;
  final double fillEnd;
  final Color color;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double t =
        (controller.lastElapsedDuration ?? Duration.zero).inMicroseconds / 1e6;
    final double dt = (t - field.lastT).clamp(0.0, _kStarMaxStep);
    field.lastT = t;

    // RTL：值 0 在右侧，填充段从右往左，光点统一向左飘 = 朝向值更小的一侧。
    final bool ltr = textDirection == TextDirection.ltr;
    double px(double frac) => (ltr ? frac : 1 - frac) * size.width;
    final double boundaryX = px(fillEnd.clamp(0.0, 1.0));
    final double regionStart = math.min(px(fillStart.clamp(0.0, 1.0)), boundaryX);
    final double regionEnd = math.max(px(fillStart.clamp(0.0, 1.0)), boundaryX);

    if (dt > 0) field.advance(dt, boundaryX, size.height / 2);

    final double baseAlpha = (1 - fade.value).clamp(0.0, 1.0);
    if (baseAlpha <= 0.001) return;
    final double cy = size.height / 2;
    final Paint paint = Paint()..color = color;
    for (final _Star s in field.stars) {
      if (!s.alive) continue;
      // 只画在已填充段里：星点永远落在主题色块上，白星对比度足够；
      // 也顺带避免了星点飘到玻璃留空段上「看不清」。
      if (s.x < regionStart - s.size || s.x > regionEnd + s.size) continue;
      final double u = (s.life / s.lifeMax).clamp(0.0, 1.0);
      // sin 曲线：出生淡入 / 消亡淡出，中途最亮。
      final double a = math.sin(math.pi * u) * 0.9 * baseAlpha;
      if (a <= 0.01) continue;
      paint.color = color.withAlpha((a * 255).round().clamp(0, 255));
      canvas.save();
      canvas.translate(s.x, cy + s.y);
      canvas.rotate(s.rot);
      canvas.scale(s.size, s.size);
      canvas.drawPath(_kStarPath, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_StarPainter oldDelegate) =>
      oldDelegate.field != field ||
      oldDelegate.fillStart != fillStart ||
      oldDelegate.fillEnd != fillEnd ||
      oldDelegate.color != color ||
      oldDelegate.textDirection != textDirection;
}

/// 星点层：只在拖动期间起 Ticker，松手淡出后自毁（返回零尺寸）。
///
/// [fillStart] / [fillEnd] 是填充段在轨道上的比例（0..1，相对轨道起点）。
class _StarLayer extends StatefulWidget {
  const _StarLayer({
    required this.active,
    required this.fillStart,
    required this.fillEnd,
    required this.trackHeight,
    required this.color,
  });

  final bool active;
  final double fillStart;
  final double fillEnd;
  final double trackHeight;
  final Color color;

  @override
  State<_StarLayer> createState() => _StarLayerState();
}

class _StarLayerState extends State<_StarLayer> with TickerProviderStateMixin {
  // 在 initState 里显式创建（不要用 `late final X = ...` 的惰性初始化器：那样
  // 组件若在首次 build 前就被移除，dispose() 反而会去创建一个已失效的 Ticker）。
  late final AnimationController _tick;
  late final AnimationController _fade;
  final _StarField _field = _StarField(math.Random());

  @override
  void initState() {
    super.initState();
    _tick = AnimationController(vsync: this, duration: const Duration(seconds: 1));
    _fade = AnimationController(vsync: this, duration: _kStarFadeOut);
    _fade.addStatusListener((AnimationStatus st) {
      if (st != AnimationStatus.completed) return;
      // 淡出结束：停掉 Ticker 并重建一次，让 build 返回零尺寸（彻底不做绘制）。
      _tick.stop();
      if (mounted) setState(() {});
    });
    if (widget.active) _start();
  }

  void _start() {
    _field.reset();
    _fade.value = 0;
    if (!_tick.isAnimating) _tick.repeat();
  }

  @override
  void didUpdateWidget(covariant _StarLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _start();
    } else if (!widget.active && oldWidget.active) {
      _fade.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _tick.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_tick.isAnimating && !_fade.isAnimating) {
      // 静止：不建任何绘制层（拖动以外的时间零开销）。
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kTrackInsetX),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          height: widget.trackHeight,
          width: double.infinity,
          // 裁到胶囊内：星点不会溢出圆角两端。
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.trackHeight / 2),
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: _StarPainter(
                  field: _field,
                  controller: _tick,
                  fade: _fade,
                  fillStart: widget.fillStart,
                  fillEnd: widget.fillEnd,
                  color: widget.color,
                  textDirection: Directionality.of(context),
                  repaint: Listenable.merge(<Listenable>[_tick, _fade]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════
// AppProgressBar：进度条（确定 / 不确定）
// ═══════════════════════════════════════════

/// 统一进度条：胶囊轨道（高 [kAppTrackHeight]、两端半圆）、进度用主题色，
/// 未完成部分是与滑块完全一致的玻璃底（[AppTrackGlass]）。
///
/// - value 非 null：确定进度。值变化时用 [TweenAnimationBuilder] 平滑过渡，
///   避免「进度一卡一卡地跳」。
/// - value 为 null：不确定进度（不知道还要多久），自己画两条来回滑动的进度线，
///   节奏与 framework 的 LinearProgressIndicator 完全一致
///   （四条缓动曲线照搬，周期 [_kIndeterminateDurationMs]）。
///
/// 替代直接用 LinearProgressIndicator：它的圆角/高度/是否画末尾停止点由 SDK 版本
/// 与主题决定，无法保证与滑块视觉统一。
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
              _IndeterminateBar(color: barColor)
            else
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: v.clamp(0.0, 1.0)),
                duration: animationDuration,
                curve: Curves.easeOutCubic,
                builder: (BuildContext context, double animated, Widget? child) =>
                    CustomPaint(
                  painter: _AppProgressBarPainter(valueColor: barColor, value: animated),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 确定进度条的画笔：只画已填充的胶囊（留空段由玻璃底负责）。
class _AppProgressBarPainter extends CustomPainter {
  const _AppProgressBarPainter({required this.valueColor, required this.value});

  final Color valueColor;
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 半径 = 高度一半 → 两端半圆；进度很小时 Skia 会自动收窄半径，
    // 画出来仍是一个小圆头而不是方块。
    final double w = size.width * value.clamp(0.0, 1.0);
    if (w <= 0.01) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, w, size.height),
        Radius.circular(size.height / 2),
      ),
      Paint()..color = valueColor,
    );
  }

  @override
  bool shouldRepaint(_AppProgressBarPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.valueColor != valueColor;
}

/// 不确定进度条：两条来回滑动的进度线叠在玻璃轨道上。
///
/// 缓动曲线（line1Head / line1Tail / line2Head / line2Tail）与周期 1800ms
/// 直接取自 framework 的 _LinearProgressIndicatorPainter；这里只画滑动线段，
/// 轨道由调用方垫在下面的 [AppTrackGlass] 负责。
class _IndeterminateBar extends StatefulWidget {
  const _IndeterminateBar({required this.color});

  final Color color;

  @override
  State<_IndeterminateBar> createState() => _IndeterminateBarState();
}

class _IndeterminateBarState extends State<_IndeterminateBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 同样的理由：在 initState 里创建，避免 late 字段在 dispose 时才被求值。
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _kIndeterminateDurationMs),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _IndeterminateBarPainter(
        valueColor: widget.color,
        animation: _controller,
        textDirection: Directionality.of(context),
      ),
    );
  }
}

/// 不确定进度条的画笔（曲线参数与 framework 一致）。
class _IndeterminateBarPainter extends CustomPainter {
  _IndeterminateBarPainter({
    required this.valueColor,
    required this.animation,
    required this.textDirection,
  }) : super(repaint: animation);

  final Color valueColor;
  final Animation<double> animation;
  final TextDirection textDirection;

  // 与 framework 完全相同的四条曲线（周期 1800ms）。
  static const Curve _line1Head =
      Interval(0.0, 750.0 / _kIndeterminateDurationMs, curve: Cubic(0.2, 0.0, 0.8, 1.0));
  static const Curve _line1Tail = Interval(
      333.0 / _kIndeterminateDurationMs, (333.0 + 750.0) / _kIndeterminateDurationMs,
      curve: Cubic(0.4, 0.0, 1.0, 1.0));
  static const Curve _line2Head = Interval(
      1000.0 / _kIndeterminateDurationMs, (1000.0 + 567.0) / _kIndeterminateDurationMs,
      curve: Cubic(0.0, 0.0, 0.65, 1.0));
  static const Curve _line2Tail = Interval(
      1267.0 / _kIndeterminateDurationMs, (1267.0 + 533.0) / _kIndeterminateDurationMs,
      curve: Cubic(0.10, 0.0, 0.45, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 半径 = 半高：滑动线段本身也是胶囊（两端圆头），与轨道同语言。
    final Radius radius = Radius.circular(size.height / 2);

    final bool isLtr = textDirection == TextDirection.ltr;
    void drawLine(double startFraction, double endFraction) {
      if (endFraction - startFraction <= 0) return;
      final double left = (isLtr ? startFraction : 1 - endFraction) * size.width;
      final double right = (isLtr ? endFraction : 1 - startFraction) * size.width;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(left, 0, right, size.height), radius),
        Paint()..color = valueColor,
      );
    }

    final double t = animation.value;
    drawLine(_line1Tail.transform(t), _line1Head.transform(t));
    drawLine(_line2Tail.transform(t), _line2Head.transform(t));
  }

  @override
  bool shouldRepaint(_IndeterminateBarPainter oldDelegate) =>
      oldDelegate.valueColor != valueColor || oldDelegate.textDirection != textDirection;
}
