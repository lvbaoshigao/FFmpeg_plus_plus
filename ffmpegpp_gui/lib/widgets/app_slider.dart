import 'dart:math' as math;

import 'package:flutter/material.dart';

// ═══════════════════════════════════════════
// 统一滑块 / 进度条（全应用唯一来源）
// ═══════════════════════════════════════════
//
// 为什么要有这个文件：
// 之前各页面直接 new `Slider` / `RangeSlider` / `LinearProgressIndicator`，于是同一个
// 应用里出现了三种轨道高度（LinearProgressIndicator 默认 4、部分页面 3、frame_step_editor
// 里 4）、两套配色（有的页面自己拼 `SliderThemeData`，有的用 framework 默认），
// 甚至同一个屏幕里上下两个滑动条高度都不一样。这里把「轨道 + thumb + overlay + 数值动画」
// 固化成唯一实现，各页面只传数据（value/min/max/onChanged），不再各自拼主题。
//
// 统一规格（改动前请先读这里，不要在页面里再手写 SliderThemeData）：
// - 轨道：高 6 的圆角矩形，圆角半径 = 高度 / 2 → 视觉上两端是半圆；
//   未激活部分 scheme.surfaceContainerHighest，激活部分主题色；
// - thumb：半径 9 的实心圆点（主题色）+ 1.5px 细描边 + 轻阴影，
//   按下/拖动时用 framework 自带的 activationAnimation 平滑放大（不需要额外动画控制器）；
// - overlay（按住时 thumb 周围的圆形底色）：主题色 alpha≈0.12（31/255，Material 默认值）；
// - 数值变化：除拖动外按 180ms easeOutCubic 平滑过渡（重置按钮、预设、载入配置等场景
//   下 thumb 是滑过去而不是瞬移）。
//
// 为什么用 SliderTheme 包住 framework 的 Slider，而不是从头自绘：
// framework 的 Slider/RangeSlider 已经处理好了命中区域、拖拽与键盘交互、divisions 吸附、
// 数值气泡（label）、RTL 镜像、Semantics 无障碍、拖动去抖等细节；自绘必须重新实现这些
// 且极易引入行为回归。这里只替换「轨道形状 / thumb 形状 / 配色」这几处纯外观插槽，
// 其余行为完全沿用 framework（参数与 Slider 一一对应）。
//
// 唯一自绘的是 [AppProgressBar]：LinearProgressIndicator 的几何（高度、圆角）以及
// 「是否画末尾停止指示点」由 SDK 版本 / 主题决定，无法保证与滑块视觉一致，
// 所以这里自己画圆角轨道 + 进度，并用 TweenAnimationBuilder 做平滑过渡。

/// 统一轨道高度（未激活与激活部分同高）。
const double _kTrackHeight = 6;

/// [AppSlider.compact] 模式的轨道高度。
const double _kCompactTrackHeight = 4;

/// 统一 thumb 半径。
const double _kThumbRadius = 9;

/// [AppSlider.compact] 模式的 thumb 半径。
const double _kCompactThumbRadius = 7;

/// 按下/拖动时 thumb 的放大倍数（与 framework 里 pressedElevation 的用意相同：
/// 给「正在操作这个滑块」一个可见的反馈）。
const double _kThumbPressedScale = 1.18;

/// 数值变化动画时长。取 180ms：比 framework 自己的 75ms 离散吸附动画略长，
/// 肉眼能看出「滑过去」但不会显得拖沓。
const Duration _kValueAnimationDuration = Duration(milliseconds: 180);

/// overlay 透明度：Material 默认 0.12 → 31/255。
const int _kOverlayAlpha = 31;

/// thumb 细描边宽度。
const double _kThumbBorderWidth = 1.5;

/// 进度条不确定态（来回滑动）一个周期的时长。
/// 与 framework 的 `_kIndeterminateLinearDuration` 保持一致：它的四条缓动曲线
/// 直接搬过来（见 [_IndeterminateBarPainter]），这样不确定进度的节奏与系统一致。
const int _kIndeterminateDurationMs = 1800;

// ═══════════════════════════════════════════
// 自绘形状：轨道同高、thumb 带描边
// ═══════════════════════════════════════════

/// 画一个「主题色圆点 + 细描边 + 轻阴影」的 thumb。
///
/// 抽成函数是因为单值滑块与区间滑块的两个 thumb 必须完全一致。
void _paintAppThumb(
  Canvas canvas,
  Offset center, {
  required double radius,
  required Color fill,
  required Color borderColor,
  required double scale,
  required double shadowElevation,
}) {
  final double r = radius * scale;
  final Path path = Path()..addArc(Rect.fromCircle(center: center, radius: r), 0, math.pi * 2);
  // 轻阴影：让 thumb 浮在轨道之上（与 framework RoundSliderThumbShape 的做法一致，
  // 用 Path + drawShadow 而不是 BoxShadow，因为这里是在画布上直接绘制）。
  canvas.drawShadow(path, Colors.black, shadowElevation, true);
  canvas.drawCircle(center, r, Paint()..color = fill);
  if (_kThumbBorderWidth > 0) {
    canvas.drawCircle(
      center,
      r - _kThumbBorderWidth / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _kThumbBorderWidth
        ..color = borderColor,
    );
  }
}

/// 单值滑块的 thumb：半径固定 + 按下放大 + 细描边。
///
/// 为什么不用 framework 的 [RoundSliderThumbShape]：它只画一个纯色圆 + 阴影，
/// 没法加描边；而「同为主题色的 thumb 压在激活轨道上」如果没有描边就会糊成一团，
/// 看不出滑块在哪。
class _AppThumbShape extends SliderComponentShape {
  const _AppThumbShape({required this.radius, required this.borderColor});

  final double radius;
  final Color borderColor;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.fromRadius(radius);

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
  }) {
    // activationAnimation 是 framework 在按下/拖动时 0→1 的动画（已带缓动），
    // 直接拿它插值半径，等价于 AnimatedScale，但不需要额外 widget 与控制器，
    // 也不会因为重建而打断拖动。
    final double scale = 1 + (_kThumbPressedScale - 1) * activationAnimation.value;
    final Color fill = ColorTween(
          begin: sliderTheme.disabledThumbColor,
          end: sliderTheme.thumbColor,
        ).evaluate(enableAnimation) ??
        borderColor;
    _paintAppThumb(
      context.canvas,
      center,
      radius: radius,
      fill: fill,
      borderColor: borderColor,
      scale: scale,
      shadowElevation: 1 + 2 * activationAnimation.value,
    );
  }
}

/// 区间滑块（RangeSlider）的 thumb：外观与 [_AppThumbShape] 完全一致。
///
/// 必须单独写一个类，因为 RangeSlider 用的是 [RangeSliderThumbShape] 接口
/// （多出 thumb / isOnTop / isPressed 参数），与 SliderComponentShape 不通用。
class _AppRangeThumbShape extends RangeSliderThumbShape {
  const _AppRangeThumbShape({required this.radius, required this.borderColor});

  final double radius;
  final Color borderColor;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.fromRadius(radius);

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
  }) {
    final double scale = 1 + (_kThumbPressedScale - 1) * activationAnimation.value;
    final Color fill = ColorTween(
          begin: sliderTheme.disabledThumbColor,
          end: sliderTheme.thumbColor,
        ).evaluate(enableAnimation) ??
        borderColor;
    _paintAppThumb(
      context.canvas,
      center,
      radius: radius,
      fill: fill,
      borderColor: borderColor,
      scale: scale,
      shadowElevation: 1 + 2 * activationAnimation.value,
    );
  }
}

/// 单值滑块轨道：与 framework 的 [RoundedRectSliderTrackShape] 相同，但
/// 激活段与未激活段等高。
///
/// 为什么必须覆写：framework 的 M3 轨道默认 `additionalActiveTrackHeight = 2`，
/// 也就是「激活段比未激活段高 2px」（trackHeight 6 时激活段是 8px）。这与本文件
/// 声明「轨道高 6、两端半圆」的统一规格冲突，视觉上会像没对齐。
class _AppTrackShape extends RoundedRectSliderTrackShape {
  const _AppTrackShape();

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
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: 0,
    );
  }
}

/// 区间滑块轨道：同上，激活段（两端 thumb 之间）与两侧未激活段等高。
class _AppRangeTrackShape extends RoundedRectRangeSliderTrackShape {
  const _AppRangeTrackShape();

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
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      startThumbCenter: startThumbCenter,
      endThumbCenter: endThumbCenter,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
      additionalActiveTrackHeight: 0,
    );
  }
}

/// 主题层统一入口：`AppTheme` 的 sliderTheme 直接使用它，保证「显式用 AppSlider 的
/// 地方」与「仍用原生 Slider/SliderTheme 的地方」（设置页、视频滤镜面板等）外观完全一致 ——
/// 全应用只有这一处滑块规格定义（见文件头注释）。
SliderThemeData appSliderThemeFor(ColorScheme scheme, {bool compact = false}) =>
    _appSliderTheme(
      scheme: scheme,
      accent: scheme.primary,
      trackHeight: compact ? _kCompactTrackHeight : _kTrackHeight,
      thumbRadius: compact ? _kCompactThumbRadius : _kThumbRadius,
      compact: compact,
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
  required double thumbRadius,
  required bool compact,
}) {
  // 细描边用白色系：thumb 与激活轨道都是主题色，只有一道浅色描边能把两者分开，
  // 深色主题下半透明（避免纯白过于抢眼），浅色主题下接近纯白。
  final Color borderColor =
      Colors.white.withAlpha(scheme.brightness == Brightness.dark ? 200 : 235);
  return SliderThemeData(
    trackHeight: trackHeight,
    activeTrackColor: accent,
    inactiveTrackColor: scheme.surfaceContainerHighest,
    thumbColor: accent,
    overlayColor: accent.withAlpha(_kOverlayAlpha),
    thumbShape: _AppThumbShape(radius: thumbRadius, borderColor: borderColor),
    trackShape: const _AppTrackShape(),
    rangeThumbShape: _AppRangeThumbShape(radius: thumbRadius, borderColor: borderColor),
    rangeTrackShape: const _AppRangeTrackShape(),
    // 默认半径是 24，相对半径 9 的 thumb 偏大；这里收紧一点，
    // 保证在密集表单里按住滑块时不会盖住相邻控件。
    overlayShape: RoundSliderOverlayShape(overlayRadius: compact ? 16 : 22),
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

  /// 紧凑尺寸（轨道 4 / thumb 半径 7），用于密集表单。
  /// 默认 false：统一规格就是 6 / 9，除确有必要不要打开。
  final bool compact;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> with SingleTickerProviderStateMixin {
  /// 拖动中的本地值。非 null 表示用户正在拖动 —— 此时直接跟手、不做数值动画，
  /// 既避免 thumb 落后手指，也避免和上层回传的 value 互相打架
  /// （上层可能只在 onChangeEnd 才写全局配置，拖动期间 value 根本不变）。
  double? _dragValue;

  /// 实际绘制出来的值：拖动时 = 手指值，其余时候 = 数值动画的当前帧。
  late double _shown = _clamp(widget.value);

  // 在 initState 里创建（而不是用 late 字段初始化器）：late 只在首次访问时才求值，
  // 若组件在首次 build 前就被移除，dispose() 反而会创建一个已失效的 Ticker。
  late final AnimationController _valueController;

  Animation<double>? _valueTween;

  double _clamp(double v) => v < widget.min ? widget.min : (v > widget.max ? widget.max : v);

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
    // 从配置里载入数值等场景，thumb 滑过去而不是瞬移。
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
    final double trackHeight = widget.compact ? _kCompactTrackHeight : _kTrackHeight;
    final double thumbRadius = widget.compact ? _kCompactThumbRadius : _kThumbRadius;

    return SliderTheme(
      data: _appSliderTheme(
        scheme: scheme,
        accent: accent,
        trackHeight: trackHeight,
        thumbRadius: thumbRadius,
        compact: widget.compact,
      ),
      child: Slider(
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
    );
  }
}

// ═══════════════════════════════════════════
// AppRangeSlider：双滑块
// ═══════════════════════════════════════════

/// 统一的双滑块（区间）组件，外观与 [AppSlider] 一致。
///
/// 除外观外完全等同于 framework 的 [RangeSlider]（含 minThumbSeparation、
/// divisions 吸附、labels 气泡），因此调用方只需把 `RangeSlider(` 换成
/// `AppRangeSlider(` 并补上 import。
class AppRangeSlider extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = color ?? scheme.primary;
    return SliderTheme(
      data: _appSliderTheme(
        scheme: scheme,
        accent: accent,
        trackHeight: compact ? _kCompactTrackHeight : _kTrackHeight,
        thumbRadius: compact ? _kCompactThumbRadius : _kThumbRadius,
        compact: compact,
      ),
      child: RangeSlider(
        values: values,
        min: min,
        max: max,
        divisions: divisions,
        labels: labels,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
}

// ═══════════════════════════════════════════
// AppProgressBar：进度条（确定 / 不确定）
// ═══════════════════════════════════════════

/// 统一进度条：轨道高 6、两端半圆（半径 = 高度 / 2）、进度用主题色。
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
    this.height = _kTrackHeight,
    this.animationDuration = const Duration(milliseconds: 220),
    this.semanticsLabel,
  });

  /// 进度 0..1；null 表示不确定进度。
  final double? value;

  /// 进度色，默认主题色。
  final Color? color;

  /// 轨道色，默认 scheme.surfaceContainerHighest（与滑块未激活轨道一致）。
  final Color? backgroundColor;

  /// 轨道高度，默认 6（与滑块一致，不要轻易改）。
  final double height;

  /// 确定进度的过渡时长。
  final Duration animationDuration;

  /// 无障碍标签（例如「下载进度」）。
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color barColor = color ?? scheme.primary;
    final Color trackColor = backgroundColor ?? scheme.surfaceContainerHighest;
    final double? v = value;

    return Semantics(
      label: semanticsLabel,
      value: v == null ? null : '${(v.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: v == null
            ? _IndeterminateBar(color: barColor, trackColor: trackColor)
            : TweenAnimationBuilder<double>(
                tween: Tween<double>(end: v.clamp(0.0, 1.0)),
                duration: animationDuration,
                curve: Curves.easeOutCubic,
                builder: (BuildContext context, double animated, Widget? child) => CustomPaint(
                  painter: _AppProgressBarPainter(
                    trackColor: trackColor,
                    valueColor: barColor,
                    value: animated,
                  ),
                ),
              ),
      ),
    );
  }
}

/// 确定进度条的画笔：圆角轨道 + 圆角进度。
class _AppProgressBarPainter extends CustomPainter {
  const _AppProgressBarPainter({
    required this.trackColor,
    required this.valueColor,
    required this.value,
  });

  final Color trackColor;
  final Color valueColor;
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 半径 = 高度一半 → 两端半圆；进度很小时 Skia 会自动收窄半径，
    // 画出来仍是一个小圆头而不是方块。
    final Radius radius = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      Paint()..color = trackColor,
    );
    final double w = size.width * value.clamp(0.0, 1.0);
    if (w > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, size.height), radius),
        Paint()..color = valueColor,
      );
    }
  }

  @override
  bool shouldRepaint(_AppProgressBarPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.valueColor != valueColor ||
      oldDelegate.trackColor != trackColor;
}

/// 不确定进度条：两条来回滑动的进度线叠在轨道上。
///
/// 缓动曲线（line1Head / line1Tail / line2Head / line2Tail）与周期 1800ms
/// 直接取自 framework 的 _LinearProgressIndicatorPainter，只是把轨道的绘制
/// 改成「整条圆角轨道」，以保证与确定态、与滑块外观一致。
class _IndeterminateBar extends StatefulWidget {
  const _IndeterminateBar({required this.color, required this.trackColor});

  final Color color;
  final Color trackColor;

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
      painter: _IndeterminateBarPainter(
        trackColor: widget.trackColor,
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
    required this.trackColor,
    required this.valueColor,
    required this.animation,
    required this.textDirection,
  }) : super(repaint: animation);

  final Color trackColor;
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
    final Radius radius = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      Paint()..color = trackColor,
    );

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
      oldDelegate.trackColor != trackColor ||
      oldDelegate.valueColor != valueColor ||
      oldDelegate.textDirection != textDirection;
}
