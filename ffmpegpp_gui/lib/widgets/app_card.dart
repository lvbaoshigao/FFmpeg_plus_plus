import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import 'liquid_glass_fallback.dart';

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
    } else if (style == SurfaceStyle.blur || key.frosted) {
      // 扁平高斯模糊：卡片样式为「模糊」，或「设置卡片以毛玻璃展示」
      // （后者把「液态玻璃」也改成扁平模糊，长列表更易读）。
      // σ 与 tint 分别由「玻璃细节」的模糊度 / 通透度控制（默认观感不变）。
      final alpha = (((isDark ? 110.0 : 130.0) * op * tScale).round()).clamp(0, 255);
      // BackdropFilter 外层不包 RepaintBoundary（Skia 缓存导致玻璃与背景脱节）
      core = ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
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
    } else if (style == SurfaceStyle.liquid && gpuGlassEnabledOf(context)) {
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
      core = RepaintBoundary(
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
      core = LiquidGlassBackdrop(
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