import 'dart:math' as math;
// Float32List：彗星拖尾的轨迹环形缓冲（预分配、零每帧分配，见 [_Particle]）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
// cachedGlassBlur：轨道玻璃的 σ 走进程级实例缓存（避免设置页里几十个滑块
// 各自在每帧 build 时新建一份持有 native handle 的 ImageFilter）；
// effectiveGlassSigma：Windows 的 σ 上限钳制。
import 'liquid_glass_fallback.dart'
    show cachedGlassBlur, effectiveGlassSigma;

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

// ── 拖动彗星拖尾 ──
//
// 用户要求（2026-09 二次改版）：「把滑动粒子特效改为彗星拖尾特效」—— 保留原有
// 全部约束，只把「离散小圆点」换成「连续衰减拖尾」：
// * 发射点 = 填充段**最右端**（= 把手，也就是用户说的「滑块最右端」），拖尾向
//   **左**甩出并逐渐耗散：`===(彗星头)>·····`；
// * 亮度语义相对旧版**反转**：头部（发射端）最亮、越往左越暗、尾尖干净收尾
//   （旧版是「出生很暗、越走越亮」）—— 这才是彗星 / 尾焰的观感；
// * 线宽同时呈锥形：头部 [_kParticleHeadW] → 尾部 [_kParticleTailW]；
// * 密度适中、有颗粒感但不过于密集 —— 池子上限 [_kParticlePool] 条，实际同时
//   存活的条数按「拖尾带」宽度折算（[_kParticleSpacing]）：窄轨道少发、宽轨道
//   多发，任何宽度都不会连成一坨实色；
// * 「占据滑块的空间不超过总长」—— 每条彗星的消亡距离取 [_kParticleSpanMin] ~
//   [_kParticleSpanMax] 个轨道总长（上限由旧版的 15% 放宽到 22%，因为拖尾比圆点
//   长得多）；整条带宽恒等于消亡距离，因此**不会越界**；
// * 「每个彗星消失位置不统一」—— 消亡距离逐条独立随机（8%~22%），于是消失点
//   参差不齐，不会切出一条整齐的直线。
//
// 轨迹记录（改这里前先读）：
// * 每条彗星持有一段**预分配**的轨迹环形缓冲（[_Particle._tx] 等，Float32List），
//   按**固定时间间隔** [_kParticleTrailSampleDt] 采样 —— 按时间而不是按帧，才能
//   保证 60 / 120 / 144Hz 下拖尾长度一致；
// * 缓冲点同时存了写入时的寿命进度 u，绘制时用 u 反查亮度 / 线宽，于是
//   「发射端亮 → 远端渐隐」自动成立，无需额外参数；
// * [_ParticleField._respawn] 与 [_ParticleField.reset] 都必须调 `_resetTrail()`：
//   否则复用池子时旧轨迹会残留成一条横跨整条带的直线（最重要的一条正确性约束）。
//
// 性能约定（改这里前先读）：
// * 只在拖动期间 `repeat()`，松手后 [_kParticleFadeOut] 内淡出并 `stop()` ——
//   静止时**不建绘制层、不起 Ticker**，零帧开销；
// * 固定池子 + 构造期一次性分配的环形缓冲：没有逐条 new、没有逐帧 setState、
//   不用 Path / PathMetrics（它们每帧都要重建并产生分配）；
// * 每帧绘制 = 逐段 `drawLine`（复用单份 Paint，段数 ≤ [_kParticleSegs] × 池容量
//   = 256 次，且仅拖动期间），无 saveLayer；
// * 彗星层单独包 RepaintBoundary：每帧只脏自己这一层，不牵连 Slider 与卡片；
// * 只在已填充段内绘制，彗星永远落在主题色块上，对比度足够；
// * 设置里可关闭（`AppConfig.sliderParticles`），系统开启「减弱动态效果」时也自动关闭。

/// 池容量（上限）。实际同时存活的条数由拖尾带宽度折算，见 [_particleActiveCount]。
const int _kParticlePool = 32;

/// 拖尾带里两条彗星平均占用的横向像素。
///
/// 旧版（小圆点）取 2.3px 就够；改成拖尾后每条彗星本身就很长，密度必须放疏，
/// 否则 32 条最长 22% 轨道长的拖尾会叠成一坨实色、完全看不出「一条一条」。
/// 想整体调密 / 调疏只改这一个值（越小越密）。
const double _kParticleSpacing = 4.2;

/// 池子里至少同时存活的条数（很窄的轨道也别只剩两三条）。
const int _kParticleMinActive = 9;

/// 彗星横向寿命（秒）：一条彗星从发射到消失要走多久。
/// 速度由「消亡距离 ÷ 寿命」反推（见 [_ParticleField._respawn]），所以改这里只影响
/// 快慢，不会破坏「最远 22%」的约束。
const double _kParticleLifeMin = 0.50;
const double _kParticleLifeMax = 0.95;

/// 消亡距离下限 / 上限（相对**轨道总长**）。
///
/// 旧版上限 0.15 是「圆点带」的约束；拖尾更长，这里放宽到 0.22（留 3% 余量，
/// 避免 ClipRRect 的圆角端把边界彗星裁出硬边）。每条彗星在这两个值之间随机取值，
/// 所以消失点不统一（8%~22%）。
const double _kParticleSpanMin = 0.08;
const double _kParticleSpanMax = 0.22;

/// 发射点抖动（px）：让彗星不从同一条竖线上出发。
/// 它从消亡距离里**扣掉**（见 [_ParticleField._respawn]），因此不会把 22% 撑大。
const double _kParticleJitter = 3;

// ── 拖尾几何 ──

/// 轨迹环形缓冲的点数上限（每条彗星预分配这么长）。
///
/// 配合 [_kParticleTrailSampleDt] 决定单条拖尾覆盖的时间跨度
/// （12 × 22ms ≈ 0.27s），进而决定拖尾的像素长度：长度 = 该条彗星的速度 × 0.27s。
const int _kParticleTrailCap = 12;

/// 轨迹采样间隔（秒）。**按时间采样而不是按帧**：否则 144Hz 屏上的拖尾只有
/// 60Hz 的 41% 长（同样的点数被更短的时间填满）。
const double _kParticleTrailSampleDt = 1 / 45;

/// 单条拖尾最多绘制成几段。段数与池容量相乘就是每帧的 `drawLine` 上限
/// （32 × 8 = 256，且仅拖动期间）。
const int _kParticleSegs = 8;

/// 头部（发射端）线宽 / 尾部线宽（px）—— 共同定义拖尾的锥形收窄。
const double _kParticleHeadW = 1.8;
const double _kParticleTailW = 0.5;

/// 头部（发射端）最高亮度 / 将断处最低亮度（0~1）。
/// 与旧版的「出生 0.10 → 越走越亮」相反：彗星是**头最亮、尾渐隐**。
const double _kParticleHeadAlpha = 0.92;
const double _kParticleTailAlpha = 0.07;

/// 亮度 / 线宽衰减到最小值时的寿命进度（0.82 = 走完 82% 寿命时已衰减到尾部值）。
const double _kParticleHoldU = 0.82;

/// 最后一小段生命用来的收尾比例（0.14 = 最后 14% 快速淡出，避免尾尖硬切）。
const double _kParticleTail = 0.14;

/// 拖尾短于这个像素长度时退化为单点绘制（避免 0 长线段与首帧抖动）。
const double _kParticleMinTailPx = 2.0;

/// 松手后整条拖尾带的淡出时长。
const Duration _kParticleFadeOut = Duration(milliseconds: 240);

/// 单帧最大积分步长：页面卡顿 / 后台回来时不要让彗星「瞬移」。
const double _kParticleMaxStep = 0.05;

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

  const _TrackCfg({required this.noGlass, required this.follow, required this.particles});

  @override
  bool operator ==(Object other) =>
      other is _TrackCfg &&
      other.noGlass == noGlass &&
      other.follow == follow &&
      other.particles == particles;

  @override
  int get hashCode => Object.hash(noGlass, follow, particles);
}

_TrackCfg _trackCfgOf(BuildContext context) => context.select<AppState, _TrackCfg>(
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
    // 彗星颜色跟填充段的明暗走：浅色填充配深色彗星，否则白彗星在浅色块上不可见。
    // 系统开启「减弱动态效果」时完全不做特效（无障碍 + 省电）。
    final bool particlesOn = widget.particles &&
        cfg.particles &&
        !MediaQuery.disableAnimationsOf(context);

    return SliderTheme(
      data: appSliderThemeFor(scheme, compact: widget.compact, accent: accent, glassTrack: true),
      child: Stack(
        // 只让 Slider 决定尺寸；玻璃层与粒子层都是 Positioned.fill 的纯装饰层。
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
          // ③ 拖动时从把手（填充段最右端）向左喷出的粒子（纯前景装饰，
          //     IgnorePointer 保证不抢手势）。发射点 = fillEnd，见 [_ParticleLayer]。
          if (particlesOn)
            Positioned.fill(
              child: IgnorePointer(
                child: _ParticleLayer(
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

class _AppRangeSliderState extends State<AppRangeSlider> {
  /// 是否有手指按在任一端（决定彗星拖尾是否甩出）。
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
    final bool particlesOn = widget.particles &&
        cfg.particles &&
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
          // 拖动时从**区间的右端**（= 用户说的「滑块最右端」）向左喷出的粒子。
          if (particlesOn)
            Positioned.fill(
              child: IgnorePointer(
                child: _ParticleLayer(
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
// 拖动彗星拖尾
// ═══════════════════════════════════════════

/// 一条彗星的全部状态（固定池子里的元素，反复复用，不新建对象）。
///
/// 除了「头部」自己的运动状态，它还持有一段**预分配**的轨迹环形缓冲：三条等长
/// Float32List 交织存 (x, y, u)，u = 写入该点时的寿命进度（0 = 刚发射）。
/// 绘制时用 u 反查亮度 / 线宽，于是「发射端最亮 → 远端渐隐」自动成立。
class _Particle {
  /// 轨道局部坐标（px）：[x] 相对轨道左端，[y] 相对轨道竖直中心（= 头部位置）。
  double x = 0;
  double y = 0;

  /// 向左速度（px/s，正值 = 向左）。由「消亡距离 ÷ 寿命」反推，见 [_respawn]。
  double vx = 60;

  /// 竖直漂移（px/s）：让拖尾带看起来是「甩」出来的，而不是整齐平移的一条线。
  double vy = 0;

  /// 已存活 / 总寿命（秒）。`寿命 × 速度` 就是这条彗星的消亡距离。
  double life = 0;
  double lifeMax = 0.7;

  /// 亮度抖动系数：让同一时刻的彗星不是一个亮度，避免整条带一起「呼吸」。
  double tone = 1;

  /// 是否已被首次点亮（未点亮的彗星不参与绘制，避免开局挤在发射点上）。
  bool alive = false;

  // ── 轨迹环形缓冲（构造期一次性分配，之后零分配）──
  final Float32List _tx = Float32List(_kParticleTrailCap);
  final Float32List _ty = Float32List(_kParticleTrailCap);
  final Float32List _tu = Float32List(_kParticleTrailCap);
  /// 下一个写入槽位。
  int _head = 0;
  /// 有效点数（≤ [_kParticleTrailCap]）。
  int _count = 0;
  /// 采样时间累加器（把帧间隔攒够 [_kParticleTrailSampleDt] 才推一个点）。
  double _acc = 0;

  void _push(double px, double py, double u) {
    _tx[_head] = px;
    _ty[_head] = py;
    _tu[_head] = u;
    _head = (_head + 1) % _kParticleTrailCap;
    if (_count < _kParticleTrailCap) _count++;
  }

  /// 清空轨迹并以发射点起头。
  ///
  /// **必须在 [_ParticleField._respawn] 与 [_ParticleField.reset] 里调用**：
  /// 池子复用时不重置的话，上一条彗星的旧轨迹会残留下来，画成一条横跨整条带的
  /// 直线（首帧 / 把手被拖过发射点之后尤其明显）。
  void _resetTrail(double px, double py) {
    _count = 0;
    _head = 0;
    _acc = 0;
    _push(px, py, 0);
  }

  /// 环形缓冲的物理下标：i = 0 最旧（发射端），i = [_count] - 1 最新（尾尖）。
  int _slot(int i) => (_head - _count + i + _kParticleTrailCap) % _kParticleTrailCap;
  double txAt(int i) => _tx[_slot(i)];
  double tyAt(int i) => _ty[_slot(i)];
  double tuAt(int i) => _tu[_slot(i)];
}

/// 当前「拖尾带」宽度下应当同时存活的彗星条数。
///
/// 带越宽能放越多，但**不能线性放大**：条数一旦超过带内像素数，拖尾就会连成一片
/// 实色，也就没有颗粒感了（用户要求「有颗粒感但不过于密集」）。因此按
/// [_kParticleSpacing] 折算密度，再夹在 [_kParticleMinActive] 与池容量之间。
int _particleActiveCount(double bandWidth) =>
    (bandWidth / _kParticleSpacing).round().clamp(_kParticleMinActive, _kParticlePool);

/// 彗星亮度曲线（0~1），入参是寿命进度 u。
///
/// **u = 0（发射端）最亮**，随 u 增大单调衰减到 [_kParticleTailAlpha]，
/// 最后 [_kParticleTail] 一小段再快速收尾（否则尾尖会在最暗处硬切）。
/// 与旧版「出生很暗、越走越亮」正好相反 —— 这就是「彗星」该有的方向。
///
/// 注意它**不决定**消失位置：位置由每条彗星自己的消亡距离决定
/// （[_Particle.vx] × [_Particle.lifeMax]），见 [_ParticleField._respawn]。
double _particleAlphaOf(double u) {
  final double k = (u.clamp(0.0, 1.0) / _kParticleHoldU).clamp(0.0, 1.0);
  final double fall = Curves.easeOutCubic.transform(k);
  final double a = _kParticleHeadAlpha + (_kParticleTailAlpha - _kParticleHeadAlpha) * fall;
  if (u <= 1 - _kParticleTail) return a;
  return a * ((1 - u) / _kParticleTail).clamp(0.0, 1.0);
}

/// 彗星线宽曲线（px），入参同上：头部 [_kParticleHeadW] → 尾部 [_kParticleTailW]，
/// 与亮度同步衰减，于是拖尾整体呈锥形。
double _particleWidthOf(double u) {
  final double k = (u.clamp(0.0, 1.0) / _kParticleHoldU).clamp(0.0, 1.0);
  return _kParticleHeadW +
      (_kParticleTailW - _kParticleHeadW) * Curves.easeOutCubic.transform(k);
}

/// 彗星池：按时间步长积分推进所有彗星，走完自己的消亡距离就回到发射点重新发射，
/// 同时按固定时间间隔把位置写进各自的轨迹环形缓冲。
///
/// 放在 State 里持有、由 painter 复用（painter 每帧会被重建，池子不能跟着重建，
/// 否则每帧都会重新随机、拖尾看起来是闪烁的噪声）。
class _ParticleField {
  _ParticleField(this._rnd);

  final math.Random _rnd;

  /// 池子按上限分配；实际同时存活的只有前 [activeCount] 条。
  final List<_Particle> all = List<_Particle>.generate(_kParticlePool, (_) => _Particle());

  /// 上一次积分的时间戳（秒）。
  double lastT = 0;

  /// 当前宽度下同时存活的条数（由 [advance] 按轨道宽度刷新）。
  int activeCount = _kParticleMinActive;

  /// 是否已按「首次绘制」铺开过整池彗星。
  bool _seeded = false;

  void reset() {
    lastT = 0;
    _seeded = false;
    for (final _Particle p in all) {
      p.alive = false;
      p.life = 0;
      // 清空轨迹：池子是复用的，残留的旧轨迹会画成一条横跨整条带的直线。
      p._resetTrail(0, 0);
    }
  }

  /// 在发射点上重新发射一条彗星。
  ///
  /// [emitterX] = 填充段最右端（= 把手），[trackWidth] = 轨道总长（px）。
  /// 消亡距离取 `trackWidth × 8%~22%` 且**逐条独立随机** —— 这正是用户要的
  /// 「每个彗星消失位置不统一」。
  void _respawn(_Particle p, double emitterX, double halfHeight, double trackWidth) {
    final double span = trackWidth *
        (_kParticleSpanMin + _rnd.nextDouble() * (_kParticleSpanMax - _kParticleSpanMin));
    // 发射点抖动要从消亡距离里扣掉，否则「最远不超过 22%」会被撑大一点点。
    final double jitter = _rnd.nextDouble() * _kParticleJitter;
    final double travel = math.max(0.6, span - jitter);
    p.lifeMax = _kParticleLifeMin + _rnd.nextDouble() * (_kParticleLifeMax - _kParticleLifeMin);
    // 速度由「距离 ÷ 寿命」反推：走得远的彗星更快，于是整条带是同步向前流的，
    // 不会出现「近处慢慢爬、远处已经飞出去」的割裂感。
    p.vx = travel / p.lifeMax;
    p.x = emitterX - jitter;
    // 竖直方向限制在胶囊内部（±0.5 半高），避免彗星被圆角裁掉一半。
    p.y = (_rnd.nextDouble() * 2 - 1) * halfHeight * 0.5;
    p.vy = (_rnd.nextDouble() * 2 - 1) * 8;
    p.tone = 0.72 + _rnd.nextDouble() * 0.28;
    p.life = 0;
    p.alive = true;
    // 旧轨迹立即作废：新彗星从新发射点重新开始攒尾。
    p._resetTrail(p.x, p.y);
  }

  /// 拖动开始时把整池彗星铺开：让每条「已经飞了一会儿」且**尾巴已经长好**，
  /// 于是第一帧就是一条流动中的拖尾带，而不是整池从发射点齐射。
  void _seed(double emitterX, double halfHeight, double trackWidth) {
    for (int i = 0; i < all.length; i++) {
      final _Particle p = all[i];
      _respawn(p, emitterX, halfHeight, trackWidth);
      if (i >= activeCount) {
        // 这一宽度下用不到的彗星先不点亮，等轨道变宽再自动加入。
        p.alive = false;
        continue;
      }
      p.life = _rnd.nextDouble() * p.lifeMax * 0.85;
      p.x = emitterX - p.vx * p.life;
      // 把尾补成「已经飞过的一段直线」：沿 -vx 反推发射锚点，再等分插值。
      final double u1 = (p.life / p.lifeMax).clamp(0.0, 1.0);
      final double ax = p.x + p.vx * p.life;
      final double ay = p.y - p.vy * p.life;
      final int n = math.min(_kParticleTrailCap,
          (p.life / _kParticleTrailSampleDt).ceil() + 1);
      p._count = 0;
      p._head = 0;
      p._acc = 0;
      for (int k = 0; k < n; k++) {
        final double f = n <= 1 ? 1.0 : k / (n - 1);
        p._push(ax + (p.x - ax) * f, ay + (p.y - ay) * f, u1 * f);
      }
    }
    _seeded = true;
  }

  /// 推进 [dt] 秒。[emitterX] 是当前发射点（轨道局部坐标）。
  void advance(double dt, double emitterX, double halfHeight, double trackWidth) {
    // 拖尾带宽度 = 最远消亡距离（轨道总长 × 22%），密度按它折算。
    activeCount = _particleActiveCount(trackWidth * _kParticleSpanMax);
    if (!_seeded) {
      _seed(emitterX, halfHeight, trackWidth);
      return;
    }
    final double yLimit = halfHeight * 0.62;
    for (int i = 0; i < all.length; i++) {
      final _Particle p = all[i];
      if (i >= activeCount) {
        p.alive = false;
        continue;
      }
      if (!p.alive) {
        _respawn(p, emitterX, halfHeight, trackWidth);
        continue;
      }
      p.life += dt;
      p.x -= p.vx * dt;
      p.y += p.vy * dt;
      // 轻推回带内：竖直漂移不设边界的话，长寿命彗星会被胶囊的圆角裁掉一半。
      if (p.y > yLimit || p.y < -yLimit) p.vy = -p.vy;
      // 按固定**时间**间隔采样（不是每帧），帧率越高尾越长的问题由此消除。
      // 单次 advance 最多推一个点：[dt] 已被 [_kParticleMaxStep] 钳制，
      // 卡顿 / 后台回来不会一下子灌进多个点把尾拉成直线。
      p._acc += dt;
      if (p._acc >= _kParticleTrailSampleDt) {
        p._acc = 0;
        p._push(p.x, p.y, (p.life / p.lifeMax).clamp(0.0, 1.0));
      }
      // 回收条件有两个：
      // ① 走完自己的寿命（= 走完自己的消亡距离）—— 这就是「消失位置不统一」的来源；
      // ② 把手被向左拖过头、发射点跑到了这条彗星右边：它此刻落在「还没被填充」的
      //    区域里，直接回收重发（_respawn 会作废旧尾），否则整条带会一起瞬移消失。
      if (p.life >= p.lifeMax || p.x > emitterX) {
        _respawn(p, emitterX, halfHeight, trackWidth);
      }
    }
  }
}

/// 彗星画笔：每帧只做「积分推进 + 逐段 drawLine」，无分配、无 saveLayer。
///
/// 为什么不用 `Path` + `PathMetrics`（或带渐变的 `drawPath`）：那需要每帧重建 Path、
/// 取一次 metrics 再 extractPath，全是分配；而「沿路径衰减」还得配一个依赖几何的
/// 渐变 shader —— 每帧新建着色器，直接违反「painter 内不做每帧分配」的红线。
/// 逐段 `drawLine` + 逐段写 color/strokeWidth 复用同一份 Paint，既便宜又能同时表达
/// 「亮度渐隐」和「线宽锥形」。
class _ParticlePainter extends CustomPainter {
  _ParticlePainter({
    required this.field,
    required this.controller,
    required this.fade,
    required this.fillStart,
    required this.fillEnd,
    required this.color,
    required this.textDirection,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _ParticleField field;
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
    final double dt = (t - field.lastT).clamp(0.0, _kParticleMaxStep);
    field.lastT = t;

    // RTL：值 0 在右侧，填充段从右往左长；发射点统一取填充段「值更大」的那一端，
    // 也就是用户说的「滑块最右端」。
    final bool ltr = textDirection == TextDirection.ltr;
    double px(double frac) => (ltr ? frac : 1 - frac) * size.width;
    final double emitterX = px(fillEnd.clamp(0.0, 1.0));
    final double otherEnd = px(fillStart.clamp(0.0, 1.0));
    // 已填充段（= 主题色实心胶囊）的左右边界；拖尾只画在这一段里。
    final double fillLeft = math.min(otherEnd, emitterX);
    final double fillRight = math.max(otherEnd, emitterX);

    // 轨道总长（= 用户说的「滑块总长」）：消亡距离按它折算，于是拖尾带最多
    // 22%（[_kParticleSpanMax]），单条彗星落在 8%~22% 之间。
    final double trackWidth = size.width;

    if (dt > 0) field.advance(dt, emitterX, size.height / 2, trackWidth);

    final double baseAlpha = (1 - fade.value).clamp(0.0, 1.0);
    if (baseAlpha <= 0.001) return;
    final double cy = size.height / 2;
    // 单份 Paint 复用（无 per-frame new）。strokeCap round 让相邻段首尾相接，
    // 于是「一条尾 = 若干段直线」看起来仍是一条连续的带，而不是虚线。
    final Paint paint = Paint()
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round;

    for (final _Particle p in field.all) {
      if (!p.alive) continue;
      final int count = p._count;
      if (count == 0) continue;

      final double headX = p.txAt(count - 1);
      final double tailX = p.txAt(0);
      // 整条轨迹都落在填充段之外（另一端 / 未填充区）就跳过：彗星永远落在主题色块
      // 上，对比度足够；也顺带避免了飘到玻璃留空段上「看不清」。
      final double lo = math.min(tailX, headX);
      final double hi = math.max(tailX, headX);
      if (hi < fillLeft - 2 || lo > fillRight + 2) continue;

      // 很短 / 刚发射的尾：退化为单点，避免画 0 长线段（圆头帽在极短段上会跳）。
      if (count < 2 || (headX - tailX).abs() < _kParticleMinTailPx) {
        final double a = _particleAlphaOf(p.tuAt(count - 1)) * p.tone * baseAlpha;
        if (a <= 0.012) continue;
        paint
          ..style = PaintingStyle.fill
          ..color = color.withAlpha((a * 255).round().clamp(0, 255));
        canvas.drawCircle(Offset(headX, cy + p.tyAt(count - 1)), _kParticleHeadW * 0.5, paint);
        continue;
      }

      // 逐段绘制：i = 0 最旧（发射端，最亮）→ i = count-1 最新（尾尖，最暗）。
      // 用 stride 抽样把段数压到 ≤ [_kParticleSegs]；抽样点仍首尾相连，不会断线。
      paint.style = PaintingStyle.stroke;
      final int stride = (count / _kParticleSegs).ceil().clamp(1, _kParticleTrailCap);
      double x0 = tailX;
      double y0 = p.tyAt(0);
      double u0 = p.tuAt(0);
      for (int i = stride; i < count; i += stride) {
        _drawCometSegment(canvas, paint, p, i, x0, y0, u0, cy, baseAlpha);
        x0 = p.txAt(i);
        y0 = p.tyAt(i);
        u0 = p.tuAt(i);
      }
      // 抽样可能刚好绕过最后一个点：补画到 count-1，保证尾尖到位。
      if (headX != x0 || p.tyAt(count - 1) != y0) {
        _drawCometSegment(canvas, paint, p, count - 1, x0, y0, u0, cy, baseAlpha);
      }
    }
  }

  /// 画某条彗星的一段：从 (x0, y0) 到轨迹点 [i]。
  /// 亮度 / 线宽取两端 u 的中点，于是整条尾是连续的锥形衰减。
  void _drawCometSegment(Canvas canvas, Paint paint, _Particle p, int i,
      double x0, double y0, double u0, double cy, double baseAlpha) {
    final double u = (u0 + p.tuAt(i)) * 0.5;
    final double a = _particleAlphaOf(u) * p.tone * baseAlpha;
    if (a <= 0.012) return;
    paint
      ..color = color.withAlpha((a * 255).round().clamp(0, 255))
      ..strokeWidth = _particleWidthOf(u);
    canvas.drawLine(Offset(x0, cy + y0), Offset(p.txAt(i), cy + p.tyAt(i)), paint);
  }

  @override
  bool shouldRepaint(_ParticlePainter oldDelegate) =>
      oldDelegate.field != field ||
      oldDelegate.fillStart != fillStart ||
      oldDelegate.fillEnd != fillEnd ||
      oldDelegate.color != color ||
      oldDelegate.textDirection != textDirection;
}

/// 彗星层：只在拖动期间起 Ticker，松手淡出后自毁（返回零尺寸）。
///
/// [fillStart] / [fillEnd] 是填充段在轨道上的比例（0..1，相对轨道起点）；
/// 发射点取其中**更靠右**的一端 —— 用户要求「彗星从滑块最右端触发发射」。
class _ParticleLayer extends StatefulWidget {
  const _ParticleLayer({
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
  State<_ParticleLayer> createState() => _ParticleLayerState();
}

class _ParticleLayerState extends State<_ParticleLayer> with TickerProviderStateMixin {
  // 在 initState 里显式创建（不要用 `late final X = ...` 的惰性初始化器：那样
  // 组件若在首次 build 前就被移除，dispose() 反而会去创建一个已失效的 Ticker）。
  late final AnimationController _tick;
  late final AnimationController _fade;
  final _ParticleField _field = _ParticleField(math.Random());

  @override
  void initState() {
    super.initState();
    _tick = AnimationController(vsync: this, duration: const Duration(seconds: 1));
    _fade = AnimationController(vsync: this, duration: _kParticleFadeOut);
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
  void didUpdateWidget(covariant _ParticleLayer oldWidget) {
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
          // 裁到胶囊内：彗星不会溢出圆角两端。最左端那几条的尾尖因此被自然截断，
          // 而这**不会**让拖尾带超过 22% —— 上限由消亡距离本身保证。
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.trackHeight / 2),
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: _ParticlePainter(
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
