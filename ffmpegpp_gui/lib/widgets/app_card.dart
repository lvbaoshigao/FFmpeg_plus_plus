import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import 'liquid_glass_fallback.dart';
import 'wallpaper_background.dart';

/// 统一「表面样式」常量（卡片 / 移动端底部菜单栏 / 移动端顶部药丸共用）：
/// - [theme]  跟随主题色（纯色，不透明卡片；设置了主题渐变时显示渐变）
/// - [liquid] 液态玻璃
/// - [blur]   模糊（高斯模糊 + 半透明 surface）
/// - [gray]   灰色（纯色容器色）
class SurfaceStyle {
  static const String theme = 'theme';
  static const String liquid = 'liquid';
  static const String blur = 'blur';
  static const String gray = 'gray';
  static const List<String> all = [theme, liquid, blur, gray];
}

/// 卡片玻璃渲染所需的「配置指纹」：只有它变化时才允许重建
/// OCLiquidGlassGroup/OCLiquidGlass 节点或切换渲染分支，避免无关
/// notify（进度/日志/任务）引起的 shader 重置与整卡重建。
@immutable
class _CardGlassKey {
  final String style;
  final double op;
  final int primary;
  final int second;
  /// 「样式 → 设置卡片玻璃」：'solid' 退回主题色实心、'frosted' 改走扁平模糊
  /// （见 AppConfig.settingsGlassMode；历史上是两个互斥布尔，现已合并为单值）
  final String settingsGlass;
  /// 「样式 → 玻璃底色遵循主题色」（玻璃 tint 用主题色而非 surface 灰）
  final bool follow;
  /// 玻璃细节（模糊度 / 通透度 / 高光强度 / 高光位置 / 边缘光）
  final GlassTuning tuning;
  /// 主题色协调度（「跟随主题色」的底色与表面色混合比例）
  final double tone;

  const _CardGlassKey({
    required this.style,
    required this.op,
    required this.primary,
    required this.second,
    required this.settingsGlass,
    required this.follow,
    required this.tuning,
    required this.tone,
  });

  bool get noGlass => settingsGlass == 'solid';
  bool get frosted => settingsGlass == 'frosted';

  @override
  bool operator ==(Object other) =>
      other is _CardGlassKey &&
      other.style == style &&
      other.op == op &&
      other.primary == primary &&
      other.second == second &&
      other.settingsGlass == settingsGlass &&
      other.follow == follow &&
      other.tuning == tuning &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(
      style, op, primary, second, settingsGlass, follow, tuning, tone);
}

/// 应用统一卡片容器 —— 接管「设置 / 项目 / 处理队列 / 配置库」的卡片样式。
///
/// 样式由 [style]（AppConfig.cardStyle 四值）决定：
/// - 'liquid' 移动端：oc_liquid_glass GPU 液态玻璃（与底部导航/药丸同参数）；
///             桌面端：背景模糊 + 上亮下暗体感渐变玻璃
/// - 'blur'   扁平高斯模糊 + 半透明 surface
/// - 'theme'  跟随主题色纯色（主题渐变时渐变；不透明度对可读性做下限钳制）
/// - 'gray'   灰色纯色容器（surfaceContainerHigh）
///
/// 不透明度统一由全局 `cardOpacity` 控制。
class AppCard extends StatefulWidget {
  final Widget child;
  /// 表面样式（SurfaceStyle 四值之一）
  final String style;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  /// 可选点击回调（卡片整体可点，如配置库条目）
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    required this.style,
    this.radius = 16,
    this.padding,
    this.margin,
    this.onTap,
  });

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _pressed = false;

  /// 无壁纸作用域时的占位 notifier（恒 null → 玻璃走原 BackdropFilter 路径）。
  static final ValueNotifier<WallpaperWindow?> _noWindow = ValueNotifier(null);

  // 液态玻璃 settings 不在本文件硬编码：统一使用 liquid_glass_fallback 的
  // kLiquidGlassSettings（全应用唯一一份 const 基准实例，与底部导航/药丸同源）
  // —— 每次 build 新建实例会触发 shader uniform 重置（移动端表现为液态玻璃
  //「来回跳跃」闪烁），因此这里绝不能另写一份 settings。
  static _CardGlassKey _keyOf(AppState s, String style) {
    final c = s.config;
    return _CardGlassKey(
      style: style,
      op: c.cardOpacity,
      primary: c.themeColor,
      second: c.themeColor2,
      settingsGlass: c.settingsGlassMode,
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
  }

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = widget.style;
    // 仅订阅玻璃渲染相关字段，进度/日志等高频 notify 不会重建卡片。
    final key = context.select<AppState, _CardGlassKey>((s) => _keyOf(s, style));
    // 模糊 σ 与「是否走 shader」统一来自 liquid_glass_fallback（各调用点固定 σ +
    // Windows ≤12 钳制；PC 端默认不走 shader，见 gpuGlassEnabledOf）。
    final op = key.op.clamp(0.0, 1.0);
    final radius = widget.radius;
    final br = BorderRadius.circular(radius);
    // 主题渐变（起色→止色）只属于「跟随主题色」卡片：
    // - theme 卡：纯色变渐变；
    // - 桌面端 liquid 玻璃：用 themeGrad 给体感渐变染色（下方分支）。
    // 关键修复：此前渐变与样式无关——渐变主题（themeColor2 >= 0）下选
    // 「灰色」，卡片被渲染成 alpha 255 的主题渐变色，亮度极高、非常刺眼，
    // 且与「灰色 = 纯灰容器色」的语义冲突。灰色卡现在永远纯灰。
    final themeGrad = key.second >= 0
        ? <Color>[Color(key.primary), Color(key.second)]
        : null;
    // ── 「设置 → 样式」里各开关在本组件内的落地（见下方分支）──
    // * settingsGlass='solid'   「不使用卡片玻璃效果」→ 玻璃样式退回主题色实心；
    // * settingsGlass='frosted' 「设置卡片以毛玻璃展示」→ 液态玻璃改用扁平高斯模糊；
    // * follow                  「玻璃底色遵循主题色」→ 玻璃 tint 用主题色而非 surface 灰；
    // * tuning                  模糊度 / 通透度 / 高光强度与位置 / 边缘光（见 GlassTuning）。
    // solid / frosted 默认关闭、follow 默认关闭、tuning 默认值为「不改观感」。
    final bool glassStyle =
        style == SurfaceStyle.liquid || style == SurfaceStyle.blur;
    final bool solidStyle = !glassStyle || key.noGlass;
    // GPU shader 判定无条件调用（内部是 context.select，不能写进 || 短路里，
    // 见 gpuGlassEnabledOf 注释）。
    final bool gpuGlass = style == SurfaceStyle.liquid && gpuGlassEnabledOf(context);
    // 「跟随主题色」的底色：直接铺 scheme.primary 在暗色主题下是 tone 80 的
    // 高亮色，非常刺眼（用户反馈「选择主题色又很亮」）。改为按 themeTone 与
    // 表面色混合后的协调色（默认 0.45）。
    final Color accent = harmonizedAccent(scheme, key.tone);
    // 纯色分支的底色：gray 恒为中性灰（去饱和，避免 fromSeed 的种子色偏造成
    // 「灰色夹杂主题色」）；theme 与「关了玻璃的玻璃卡」用协调后的主题色。
    final Color solidBase = style == SurfaceStyle.gray
        ? neutralGray(scheme.surfaceContainerHigh)
        : accent;
    // 纯色分支的渐变：仅主题色纯色卡（含关玻璃后的卡）才带主题渐变，灰色恒纯灰。
    final grad = solidStyle && style != SurfaceStyle.gray && themeGrad != null
        ? harmonizedAccentGradient(scheme, themeGrad, key.tone)
        : null;
    // 玻璃 tint 的基色（follow 时用协调主题色）。
    final Color glassBase = key.follow ? accent : scheme.surface;
    // 通透度 → 各处基准 alpha 的等比缩放（默认 1.0，即观感不变）。
    final double tScale = key.tuning.tintScale;
    final GlassTuning tuning = key.tuning;
    final double sigma = effectiveGlassSigma(tuning.blur);
    // 边缘光 → 描边的透明度/线宽（基准 1.0 时与改动前一致）。
    final edgeWhite = edgeBorder(isDark ? 0.12 : 0.18, 0.7, tuning.edge);
    final edgeOutline = edgeBorder(isDark ? 60 / 255 : 80 / 255, 0.6, tuning.edge);
    // 液态玻璃回退分支的描边基准（alpha 0.14/0.28、宽 1）与之不同，单独算。
    final edgeLiquid = edgeBorder(isDark ? 0.14 : 0.28, 1.0, tuning.edge);
    // 卡片内放一层透明 Material 作为 ink 宿主：纯色/模糊表面有背景色，
    // 内部 ListTile/SwitchListTile 的水波纹与选中底色必须画在「卡片之上」
    // 才会可见（否则画在页面 Material 上被卡片背景遮住，并触发
    // Flutter「ListTile background may be invisible」错误）。
    final inner = Material(type: MaterialType.transparency, child: widget.child);

    Widget core;
    if (solidStyle) {
      // 纯色卡片：强制完全不透明（255）。此前 alpha 跟随 cardOpacity（保底 ~88%），
      // 用户反馈「纯色模式下卡片仍然有透明度」——纯色语义就是实心，不再透底。
      final base = solidBase;
      const int alpha = 255;
      core = RepaintBoundary(
        child: Container(
          padding: widget.padding,
          decoration: BoxDecoration(
            color: grad == null ? base.withAlpha(alpha) : null,
            gradient: grad != null
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: grad.map((c) => c.withAlpha(alpha)).toList(),
                  )
                : null,
            borderRadius: br,
            border: Border.all(
              color: (style == SurfaceStyle.gray
                      ? neutralGray(scheme.outlineVariant)
                      : scheme.outlineVariant)
                  .withAlpha(isDark ? 45 : 70),
              width: 0.6,
            ),
            boxShadow: [
              BoxShadow(color: Colors.black.withAlpha(isDark ? 30 : 12), blurRadius: 12, offset: const Offset(0, 3)),
            ],
          ),
          child: inner,
        ),
      );
    } else {
      // ── 玻璃分支：优先「壁纸开窗」绑定渲染 ──
      // 卡片不再实时采样合成场景（滚动中引擎 backdrop 采样滞后一帧 →
      // 玻璃与背景「图层分离」），而是 paint 时按当前帧的变换把静态
      // 壁纸直接画进卡片 —— 卡片与背景同帧、同变换光栅化，几何上锁死，
      // 滚动零滞后。壁纸源不可用（无壁纸 / 未加载完 / 非平移变换）时
      // 回退到下方原 BackdropFilter / shader 路径。
      final win = WallpaperWindowScope.maybeOf(context);
      core = ValueListenableBuilder<WallpaperWindow?>(
        valueListenable: win ?? _noWindow,
        builder: (ctx, w, _) {
          if (w != null) {
            final bool blurLike = style == SurfaceStyle.blur || key.frosted;
            final Color? tint;
            final Gradient? tintGrad;
            final Border border;
            // 阴影必须与下方各回退分支逐项对齐：此前开窗分支直接
            // 从 ClipRRect 开始、没有阴影，导致「设了壁纸的用户」
            // 液态玻璃卡比无壁纸时扁平一块（两条路径观感不一致）。
            final BoxShadow? shadow;
            if (blurLike) {
              tint = glassBase.withAlpha(
                  (((isDark ? 110.0 : 130.0) * op * tScale).round()).clamp(0, 255));
              tintGrad = null;
              // 扁平模糊路径本身无阴影（与回退分支一致）。
              shadow = null;
              border = Border.all(
                  color: scheme.outlineVariant
                      .withAlpha((edgeOutline.alpha * 255).round().clamp(0, 255)),
                  width: edgeOutline.width);
            } else if (gpuGlass) {
              tint = glassBase.withAlpha(((op * 255) * tScale).round().clamp(0, 255));
              tintGrad = null;
              // 与 OCLiquidGlass(shadow:) 同参数。
              shadow = BoxShadow(
                color: Colors.black.withAlpha(isDark ? 60 : 22),
                blurRadius: 16,
                offset: const Offset(0, 5),
              );
              border = Border.all(
                  color: Colors.white.withValues(alpha: edgeWhite.alpha),
                  width: edgeWhite.width);
            } else {
              tint = null;
              final alphaTop = ((isDark ? 96.0 : 118.0) * op * tScale).round();
              final alphaBot = ((isDark ? 46.0 : 62.0) * op * tScale).round();
              tintGrad = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: grad != null
                    ? [grad.first.withAlpha(alphaTop), grad.last.withAlpha(alphaBot)]
                    : [
                        glassBase.withAlpha(alphaTop),
                        glassBase.withAlpha((alphaTop + alphaBot) ~/ 2),
                        glassBase.withAlpha(alphaBot),
                      ],
                stops: grad == null ? const [0.0, 0.55, 1.0] : null,
              );
              // 与 LiquidGlassBackdrop(shadow:) 同参数。
              shadow = BoxShadow(
                color: Colors.black.withAlpha(isDark ? 60 : 26),
                blurRadius: 18,
                offset: const Offset(0, 6),
              );
              border = Border.all(
                  color: Colors.white.withValues(alpha: edgeLiquid.alpha),
                  width: edgeLiquid.width);
            }
            final Widget glassSurface = ClipRRect(
              borderRadius: br,
              child: CustomPaint(
                painter: _WallpaperWindowPainter(
                    image: w.image,
                    // 预模糊整屏壁纸（所有玻璃卡共享一张）：非 null 时 painter
                    // 只做普通贴图，不再每帧每卡跑高斯模糊。为 null 时回退实时
                    // 模糊（见 painter 注释）。
                    blurred: w.blurred,
                    screen: w.screen,
                    overlay: w.overlayColor,
                    sigma: sigma),
                child: CustomPaint(
                  painter: LiquidGlassPainter(
                      borderRadius: br,
                      opacity: op,
                      highlight: tuning.highlight,
                      lightPos: tuning.lightPos,
                      edge: tuning.edge),
                  child: Container(
                    padding: widget.padding,
                    decoration: BoxDecoration(
                      borderRadius: br,
                      color: tint,
                      gradient: tintGrad,
                      border: border,
                    ),
                    child: inner,
                  ),
                ),
              ),
            );
            // 阴影必须在 ClipRRect 之外绘制（裁剪层会把 boxShadow 一并裁掉），
            // 且不能包 RepaintBoundary（会把开窗 painter 光栅缓存掉，
            // 滚动时表现为卡内壁纸跟着卡平移）。
            if (shadow == null) return glassSurface;
            return DecoratedBox(
              decoration: BoxDecoration(borderRadius: br, boxShadow: [shadow]),
              child: glassSurface,
            );
          }
          // ── 回退：无壁纸源时沿用原玻璃路径 ──
          if (style == SurfaceStyle.blur || key.frosted) {
      // 扁平高斯模糊：卡片样式为「模糊」，或「设置卡片以毛玻璃展示」
      // （后者把「液态玻璃」也改成扁平模糊，长列表更易读）。
      // σ 与 tint 分别由「玻璃细节」的模糊度 / 通透度控制（默认观感不变）。
      final alpha = (((isDark ? 110.0 : 130.0) * op * tScale).round()).clamp(0, 255);
      // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
      return ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          // σ 已由 effectiveGlassSigma 按平台钳制；走缓存避免每帧每卡新建
          // 一份持有 native handle 的 ImageFilter（见 cachedGlassBlur 注释）。
          filter: cachedGlassBlur(sigma),
          child: CustomPaint(
            // 高光 / 边缘光：与液态玻璃回退同一支画笔，扁平模糊同样有玻璃光泽
            painter: LiquidGlassPainter(
              borderRadius: br,
              opacity: op,
              highlight: tuning.highlight,
              lightPos: tuning.lightPos,
              edge: tuning.edge,
            ),
            child: Container(
                padding: widget.padding,
                decoration: BoxDecoration(
                  borderRadius: br,
                  color: glassBase.withAlpha(alpha),
                  border: Border.all(
                      color: scheme.outlineVariant
                          .withAlpha((edgeOutline.alpha * 255).round().clamp(0, 255)),
                      width: edgeOutline.width),
                ),
              child: inner,
            ),
          ),
        ),
      );
          } else if (gpuGlass) {
      // 液态玻璃：oc_liquid_glass GPU shader（与底部导航/药丸一致）。
      // 走 shader 的条件 = 引擎支持（Impeller）且（移动端 || 设置里显式开启 PC GPU
      // 玻璃）；桌面默认关闭：shader backdrop 的纹理取向/坐标空间在桌面后端不一致
      // （用户反馈「PC 玻璃背景倒置且不是壁纸」），关闭后落到下方统一回退。
      // Impeller 不可用时（Windows 默认 Skia，部分安卓低端机也回退 Skia）同样
      // 落入回退，避免 shader backdrop 被整体跳过、玻璃整块消失。
      // OCLiquidGlass 自身接收 color=tint；inner 只保留边框，避免双重染色。
      // tint 基色随「玻璃底色遵循主题色」切换（glassBase）；透明度随通透度缩放。
      final tint = glassBase.withAlpha(((op * 255) * tScale).round().clamp(0, 255));
      final glassKey = ValueKey<_CardGlassKey>(key);
      final innerKey = ValueKey<String>('${key.hashCode}_appcard_inner');
      return RepaintBoundary(
        child: OCLiquidGlassGroup(
          key: glassKey,
          // 参数化的 settings（带实例缓存，参数不变时复用同一对象，
          // 避免每次 build 重新下发 uniform 造成液态玻璃「来回跳跃」）。
          settings: liquidGlassSettingsFor(tuning),
          child: OCLiquidGlass(
            key: innerKey,
            borderRadius: radius,
            color: tint,
            shadow: BoxShadow(
              color: Colors.black.withAlpha(isDark ? 60 : 22),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
            child: Container(
              padding: widget.padding,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: br,
                border: Border.all(
                  color: Colors.white.withValues(alpha: edgeWhite.alpha),
                  width: edgeWhite.width,
                ),
              ),
              child: inner,
            ),
          ),
        ),
      );
          } else {
      // 液态玻璃回退（无 Impeller）：高斯模糊 + 液态玻璃倒角高光（与
      // GlassPanel liquid 回退一致，不再依赖全局 glassEffect）。
      final alphaTop = ((isDark ? 96.0 : 118.0) * op * tScale).round();
      final alphaBot = ((isDark ? 46.0 : 62.0) * op * tScale).round();
      // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
      return LiquidGlassBackdrop(
        borderRadius: br,
        // σ 由「玻璃细节 → 模糊度」控制（Windows 上被 effectiveGlassSigma 钳制）
        sigma: sigma,
        opacity: op,
        shadow: BoxShadow(
          color: Colors.black.withAlpha(isDark ? 60 : 26),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
        child: Container(
          padding: widget.padding,
          decoration: BoxDecoration(
            borderRadius: br,
            color: op <= 0.001 ? Colors.transparent : null,
            gradient: op > 0.001
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: grad != null
                        ? [
                            grad.first.withAlpha(alphaTop),
                            grad.last.withAlpha(alphaBot),
                          ]
                        : [
                            glassBase.withAlpha(alphaTop),
                            glassBase.withAlpha((alphaTop + alphaBot) ~/ 2),
                            glassBase.withAlpha(alphaBot),
                          ],
                    stops: grad == null ? const [0.0, 0.55, 1.0] : null,
                  )
                : null,
            border: Border.all(
              color: op <= 0.001
                  ? Colors.transparent
                  : Colors.white.withValues(alpha: edgeLiquid.alpha),
              width: edgeLiquid.width,
            ),
          ),
          child: inner,
        ),
      );
          }
        },
      );
    }

    // 「样式 → 添加边框」：开启时在卡片表面之上叠一层同圆角描边。
    // 位置在 margin / 点击包装之内：描边严格贴合卡片本体（而非含外边距的外框），
    // 并随按压缩放一起动画；关闭时 withConfigurableBorder 原样返回 core，
    // 零额外层级（不改变布局与像素）。
    Widget result = withConfigurableBorder(context, core, radius: br);
    if (widget.margin != null) {
      result = Padding(padding: widget.margin!, child: result);
    }
    if (widget.onTap != null) {
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) {
          _setPressed(false);
          widget.onTap!();
        },
        onTapCancel: () => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? 0.985 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: result,
        ),
      );
    }
    return result;
  }
}

/// 壁纸开窗画笔：把静态壁纸按「当前帧卡片→屏幕的变换」画进卡片本地坐标，
/// 与背景壁纸逐像素对齐（同一帧、同一变换矩阵光栅化，不存在采样滞后）。
///
/// 对齐方式：把当前画布变换**求逆**后 apply，直接在屏幕**逻辑**坐标里作画
/// （屏幕左上角 = (0,0)，右下角 = 屏宽/高；画布 CTM 不含 DPR —— 根级 DPR
/// 是 RenderView 挂的 TransformLayer，由引擎在光栅化阶段应用，见 paint 内
/// [FIX 开窗DPR] 注释）。随后：
///  1. drawImageRect 把壁纸画到屏幕对应位置（清晰度见下）；
///  2. 叠 withWallpaper 的遮罩色（背景不透明度），保证玻璃里的壁纸亮度
///     与卡片外的背景一致。
/// 逆变换对**任意可逆变换**都成立，所以祖先带旋转 / 斜切 / 非等比缩放时同样
/// 逐像素对齐（旧实现手算「设备平移 ÷ 总缩放」，只支持纯平移 + 等比缩放，
/// 其余情况静默放弃绘制 → 卡片玻璃背景整块消失）。
///
/// 清晰度来源有两条路径，观感一致、开销差一个数量级：
///  - **首选**：用 [blurred]（WallpaperWindowScope 预先离屏渲染好的整屏模糊
///    壁纸），这里只做一次普通 drawImageRect。同一张图被页内所有玻璃卡共享，
///    每帧不再产生任何模糊。
///  - **回退**：没有预模糊图时（无壁纸 / 尚未生成 / 生成失败）在本方法里实时
///    模糊。这是老路径：每次 paint 都要为「整屏 dst」跑一次高斯模糊，模糊需要
///    在目标外多分配约 3σ 的离屏纹理，是「开玻璃后进程常驻内存几百 MB」的
///    主要来源 —— 所以正常情况不应走到这里。
///
/// 已知限制：模糊在壁纸图像边界处会向透明衰减（贴屏幕边缘的卡片可能有
/// 极窄的边缘变暗，通常被遮罩色盖住）；背景上若出现壁纸之外的内容
/// （如另一张卡恰好滚到玻璃卡后面），开窗不会把它模糊进来 —— 设置列表
/// 等卡片互不重叠的页面无此问题。
class _WallpaperWindowPainter extends CustomPainter {
  final ui.Image image;

  /// 预模糊好的整屏壁纸（设备像素尺寸，见 [WallpaperWindow.blurred]）。
  /// 非 null 时不再触发任何模糊。
  final ui.Image? blurred;

  final Size screen;
  final Color overlay;
  final double sigma;

  // [FIX 开窗DPR] 原本还有 devicePixelRatio 字段：paint 误把逆变换后的画布
  // 空间当设备像素、用它放大矩形与 σ。实际画布 CTM 不含 DPR（根级 DPR 在
  // TransformLayer，引擎侧应用），绘制空间就是屏幕逻辑坐标 —— 字段随之删除。

  const _WallpaperWindowPainter({
    required this.image,
    required this.screen,
    required this.overlay,
    required this.sigma,
    this.blurred,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── 在「屏幕逻辑坐标」里作画 ──
    // 做法：把当前画布变换**求逆后 apply 上去**，此后所有绘制坐标就等于最终
    // 屏幕**逻辑**坐标（屏幕左上角 (0,0)，右下角 = 屏宽/高）。
    //
    // [FIX 开窗DPR] 关键事实：`canvas.getTransform()` 返回的 CTM 是
    // 「卡片本地 → 屏幕逻辑」，**不含 DPR**。根级 DPR 变换是 RenderView 挂的
    // TransformLayer（flutter/lib/src/rendering/view.dart 的 `_rootTransform`，
    // 引擎在光栅化阶段应用），不在画布记录的 Picture 里；框架 getTransformTo
    // 的文档也明确「映射到逻辑像素，取物理像素需再乘 RenderView 的变换」。
    // 原实现误把求逆后的空间当**设备像素**，把矩形尺寸与回退 σ 全部 ×DPR：
    // Windows DPR=1.0 时误差恰好为零（桌面端完全看不出），手机 DPR≈3 时
    // 卡内壁纸被放大 3 倍、回退 σ 放大到 3 倍 —— 卡内背景与卡外完全对不上
    // （用户看到的「玻璃卡里的壁纸背景没了」）。
    //
    // 逆变换对**任意可逆变换**都成立（旋转 / 斜切 / 非等比一并支持），旧版
    // 手算「设备平移 ÷ 总缩放」只支持纯平移 + 等比缩放、其余情况静默放弃绘制
    // 的失败路径也被这条方案覆盖。
    final inv = Matrix4.tryInvert(
        Matrix4.fromFloat64List(canvas.getTransform()));
    if (inv == null) return; // 退化变换（行列式为 0）：不存在可绘制区域
    canvas.save();
    canvas.transform(inv.storage);
    // —— 以下所有坐标都是屏幕逻辑坐标 ——
    final Rect screenRect = Rect.fromLTWH(0, 0, screen.width, screen.height);

    final b = blurred;
    if (b != null) {
      // 预模糊图已按 cover 铺满整屏（物理/半分辨率像素，见
      // WallpaperBlurCache._rebuild），这里把**整张**等比映射到屏幕逻辑矩形
      // 即可 —— drawImageRect 自动完成像素密度换算，与卡外背景逐像素对齐。
      //
      // filterQuality 用 low（双线性）而非 medium：medium 会在引擎侧为源图
      // 额外生成一条 mipmap 链（≈ +1/3 纹理内存），而 mipmap 只在**缩小**
      // 采样时才有意义 —— 这里源图 ≤ 屏幕设备像素、目标是整屏，属于放大
      // 或 1:1，mipmap 永远用不到，纯粹白占显存。
      canvas.drawImageRect(
        b,
        Rect.fromLTWH(0, 0, b.width.toDouble(), b.height.toDouble()),
        screenRect,
        Paint()..filterQuality = FilterQuality.low,
      );
    } else {
      final iw = image.width.toDouble();
      final ih = image.height.toDouble();
      // 与 BoxFit.cover 一致：等比铺满整屏、居中裁切（逻辑空间）。
      final scale = math.max(screen.width / iw, screen.height / ih);
      final cover = Rect.fromLTWH(
        (screen.width - iw * scale) / 2,
        (screen.height - ih * scale) / 2,
        iw * scale,
        ih * scale,
      );
      // 实时模糊回退路径（预模糊图尚未就绪 / 生成失败）：σ 走进程级缓存，
      // 避免滚动时每帧每卡新建一份持有 native handle 的 ImageFilter。
      //
      // [FIX 开窗DPR] σ 用**逻辑**值、不乘 DPR：ImageFilter 的 σ 作用于当前
      // 画布坐标系，而这里的坐标系就是逻辑根空间（与 BackdropFilter 拿到的
      // 采样空间一致），与设置里其它玻璃路径同一语义。
      final p = Paint()
        ..imageFilter = cachedGlassBlur(sigma)
        // 此处是放大采样，low 足够且不生成 mipmap。
        ..filterQuality = FilterQuality.low;
      canvas.drawImageRect(image, Rect.fromLTWH(0, 0, iw, ih), cover, p);
    }
    if (overlay.a > 0) {
      // 遮罩同样画在逻辑空间，与卡外背景叠的那层逐像素一致
      canvas.drawRect(screenRect, Paint()..color = overlay);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WallpaperWindowPainter old) =>
      old.image != image ||
      // 预模糊图换成新的（含 null → 非 null）必须重绘，否则会停留在老清晰度
      old.blurred != blurred ||
      old.screen != screen ||
      old.overlay != overlay ||
      old.sigma != sigma;
}