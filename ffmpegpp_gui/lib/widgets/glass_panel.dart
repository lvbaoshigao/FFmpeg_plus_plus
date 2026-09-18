import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../platform/app_platform.dart';
import 'app_card.dart' show SurfaceStyle;
import 'liquid_glass_fallback.dart';
import 'mobile_glass_pill.dart';

/// 玻璃面板 —— 支持的效果（由设置→外观控制）：
/// - liquid：液态玻璃（Impeller 平台走 oc_liquid_glass GPU shader 真折射；
///   Windows 默认 Skia 退回「高斯模糊 + 液态玻璃倒角高光」回退，见
///   liquid_glass_fallback.dart 的 shaderGlassSupported 说明）
/// - blur：仅高斯模糊背景（半透明，简洁）
/// - theme / gray：纯色（跟随主题色 / 灰色），桌面端菜单样式新增
/// - none：无效果（纯色卡片，遗留值）
///
/// [style] 允许调用方覆盖全局玻璃效果（如桌面端「菜单样式」menuStyle
/// 只作用于侧边栏与页面顶栏，不影响弹窗/页面面板）。
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  /// 模糊半径（σ）。默认 12：Windows 上 σ16/18 的模糊会额外占用大半径
  /// 的离屏纹理，12 在视觉上几乎无差别但内存明显更低（见 build 内 clamp）。
  final double blur;
  final EdgeInsetsGeometry? padding;
  /// 顶部渐变的不透明度 (0-255)。为空时使用主题默认值。
  final int? tintAlpha;
  /// 表面样式覆盖（SurfaceStyle 四值或遗留 'none'）。null = 跟随全局 glassEffect。
  final String? style;

  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 18,
    this.blur = 12,
    this.padding,
    this.tintAlpha,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    // 「样式 → 添加边框」：开启时给整块面板叠一条同圆角描边。
    // 包在最外层而不是逐分支改 border：本面板的渲染分支很多（移动端 3 个 /
    // 桌面端 4 个），逐个改容易漏；且 withConfigurableBorder 在关闭时原样返回
    // child，因此不开启边框时与改动前完全一致。
    // 注：移动端走到 MobileGlassPill 分支时，药丸自身也会按**同一 radius**
    // 画一层边框，两层完全重合；设置里的边框颜色恒为不透明（颜色选择器固定
    // alpha=255），重合后的像素与单层一致，观感无差异。
    return withConfigurableBorder(
      context,
      _buildPanel(context),
      radius: BorderRadius.circular(radius),
    );
  }

  /// [build] 的实际渲染分支（边框包装见上方 [build]）。
  Widget _buildPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 读取玻璃效果配置 + 透明度（cardOpacity 控制玻璃不透明度）。
    // 细粒度 select 而非 watch 整个 AppState：转码进度/日志的 notifyListeners
    // 不再触发全应用玻璃面板重建。
    final globalEffect = context.select<AppState, String>((s) => s.config.glassEffect);
    final cardOpacity = context.select<AppState, double>((s) => s.config.cardOpacity);
    final follow = context.select<AppState, bool>((s) => s.config.glassFollowTheme);
    final themeColor = context.select<AppState, int>((s) => s.config.themeColor);
    final themeColor2 = context.select<AppState, int>((s) => s.config.themeColor2);
    final noCardGlass = context.select<AppState, bool>((s) => s.config.noCardGlass);
    final settingsFrostedGlass = context.select<AppState, bool>((s) => s.config.settingsFrostedGlass);
    // 玻璃细节（模糊度 / 通透度 / 高光强度与位置 / 边缘光）+ 主题色协调度。
    // 高光/边缘光由 [LiquidGlassBackdrop] 内部读同一份配置，这里只取模糊与通透。
    final tuning = glassTuningOf(context);
    final tone = context.select<AppState, double>((s) => s.config.themeTone);
    // 本 widget 的 blur 参数是**基准 σ**（默认 12），缩放与平台钳制统一在
    // tunedGlassSigma 里（默认模糊度 → 系数 1.0，观感不变；Windows 钳到 ≤12）。
    final double sigma = tunedGlassSigma(blur, tuning);
    // 模糊 σ 取本 widget 的 blur 参数（见下方 sigma）；是否走 shader 由
    // liquid_glass_fallback.gpuGlassEnabledOf 统一判定（PC 端默认关闭）。
    final effect = style ?? globalEffect;
    // 透明度：0.0~1.0，映射到背景 alpha；0 时完全透明（仅保留边缘扭曲/折射）
    final op = cardOpacity.clamp(0.0, 1.0);
    final br = BorderRadius.circular(radius);
    // 遵循主题色：底色/渐变用主题色替代 surface 灰，所有元素统一主题色观感
    // 「透明」(none) 与纯色 theme 效果同样退回主题色显示。
    // 用 harmonizedAccent：直接铺 scheme.primary 在暗色下是 tone 80，大面积
    // 铺开非常刺眼（用户反馈「选择主题色又很亮」）。
    final solidTheme = effect == 'none' || effect == SurfaceStyle.theme;
    final accent = harmonizedAccent(scheme, tone);
    final accentAlt =
        Color.lerp(scheme.tertiary, scheme.surface, tone.clamp(0.0, 0.9))!;
    final baseColor = (follow || solidTheme) ? accent : scheme.surface;
    final baseAlt = (follow || solidTheme) ? accentAlt : scheme.surface;
    final borderColor = (follow || solidTheme) ? accent.withAlpha(isDark ? 110 : 150) : scheme.outlineVariant;
    // 主题渐变色：设置了 themeColor2（>=0）时，主题色在 themeColor→themeColor2 之间渐变
    final grad = (themeColor2 >= 0)
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(themeColor), Color(themeColor2)],
          )
        : null;

    // ── 移动端：真实液态玻璃改用 oc_liquid_glass shader（与底部导航/药丸一致），
    //    下方桌面端分支保持不变。「设置项以毛玻璃展示」开启时，改用更易读的扁平
    //    高斯模糊；blur/none 也统一复用 MobileGlassPill 的对应效果。──
    if (isMobilePlatform) {
      // 「不使用卡片玻璃效果」：跳过液态玻璃/毛玻璃渲染，退回主题色实心卡片
      // （纯色语义即实心：完全不透明，不跟随 cardOpacity）
      if (noCardGlass) {
        const solidAlpha = 255;
        return RepaintBoundary(
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: grad == null
                  ? baseColor.withAlpha(solidAlpha)
                  : null,
              gradient: grad != null
                  ? LinearGradient(
                      begin: grad.begin,
                      end: grad.end,
                      colors: grad.colors.map((c) => c.withAlpha(solidAlpha)).toList(),
                    )
                  : null,
              borderRadius: br,
              border: Border.all(color: borderColor.withAlpha(80), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 40 : 16),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: child,
          ),
        );
      }
      if (settingsFrostedGlass && effect == 'liquid') {
        // 压低 alpha：alpha 过高时玻璃层的 tint 会盖住背景模糊（观感偏实心）。
        // 与 mobile_glass_pill 一致的 120/105 上限。
        final frostedAlpha =
            (((isDark ? 105 : 120) * op) * tuning.tintScale).round().clamp(0, 255);
        // [FIX UI-玻璃脱节] 此处**不能**包 RepaintBoundary。
        // 历史代码在这里包了一层 RepaintBoundary，直接违反了本文件 241 / 368 行
        // 已明确写下的规则：「含 BackdropFilter 的图层一旦成为光栅缓存候选，
        // Skia/Impeller 会在玻璃自身内容不变时复用上一次的滤波快照 —— 背后内容
        // 滚动后玻璃里仍是旧画面，与当前位置的背景错位（玻璃与背景脱节）」。
        // 当时的处理是「把 alpha 压低到 105/120 让脱节不易被察觉」，属于掩盖症状；
        // 根因就是这层 RepaintBoundary。移除后与 blur / 液态回退分支写法一致。
        return ClipRRect(
          borderRadius: br,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: br,
                color: baseColor.withAlpha(frostedAlpha),
                border: Border.all(
                  color: borderColor.withAlpha(isDark ? 60 : 80),
                  width: 0.6,
                ),
              ),
              child: child,
            ),
          ),
        );
      }
      return MobileGlassPill(
        radius: radius,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: child,
      );
    }

    // 桌面端「不使用卡片玻璃效果」：实心主题色卡片（纯色语义即实心：
    // 完全不透明，不跟随 cardOpacity）
    if (noCardGlass) {
      const solidAlpha = 255;
      return RepaintBoundary(
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: grad == null ? baseColor.withAlpha(solidAlpha) : null,
            gradient: grad != null
                ? LinearGradient(
                    begin: grad.begin,
                    end: grad.end,
                    colors: grad.colors.map((c) => c.withAlpha(solidAlpha)).toList(),
                  )
                : null,
            borderRadius: br,
            border: Border.all(color: borderColor.withAlpha(80), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(isDark ? 40 : 16),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: child,
        ),
      );
    }

    // 纯色分支：theme（跟随主题色）/ gray（灰色）/ none（遗留「无效果」）。
    // 纯色语义即实心：完全不透明，不跟随 cardOpacity；主题渐变（themeColor2）
    // 时 theme/none 用渐变底色，gray 恒为纯灰。
    if (effect == 'none' || effect == SurfaceStyle.theme || effect == SurfaceStyle.gray) {
      const noneAlpha = 255;
      final Color base = effect == SurfaceStyle.gray
          // 灰色恒为**中性**灰：fromSeed 生成的容器灰带种子色偏，会让人误以为
          // 「选了灰色却夹杂主题色」（用户反馈），这里统一去饱和。
          ? neutralGray(scheme.surfaceContainerHigh)
          : baseColor;
      final useGrad = effect != SurfaceStyle.gray && grad != null;
      return RepaintBoundary(
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: useGrad ? null : base.withAlpha(noneAlpha),
            gradient: useGrad
                ? LinearGradient(
                    begin: grad.begin,
                    end: grad.end,
                    colors: grad.colors.map((c) => c.withAlpha(noneAlpha)).toList(),
                  )
                : null,
            borderRadius: br,
            border: Border.all(color: borderColor.withAlpha(80), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(isDark ? 40 : 16),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: child,
        ),
      );
    }

    // σ 已在 build 开头按「玻璃细节 → 模糊度」算好（见上方 sigma 定义），
    // 这里不再重复计算。

    if (effect == 'blur') {
      // 仅高斯模糊背景：半透明 + 模糊，无渐变、无阴影、无折射 —— 最简洁
      // （同 liquid 回退：BackdropFilter 外层不包 RepaintBoundary，避免
      //   Skia 光栅缓存导致玻璃内容与背后背景脱节）
      return ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: br,
              color: grad == null ? baseColor.withAlpha(((isDark ? 165 : 185) * op).round()) : null,
              gradient: grad != null
                  ? LinearGradient(
                      begin: grad.begin,
                      end: grad.end,
                      colors: grad.colors.map((c) => c.withAlpha(((isDark ? 165 : 185) * op).round())).toList(),
                    )
                  : null,
              border: Border.all(
                color: borderColor.withAlpha(isDark ? 90 : 120),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      );
    }

    // 液态玻璃（默认）：简洁通透样式
    //  - 高通透：玻璃底色 alpha 低，背景清晰透出
    //  - 背景模糊（不再做 1.06 放大折射，避免文字/图案畸变）
    //  - 光影简化：仅保留边缘高光描边 + 上亮下暗体感渐变（去除镜面光斑、
    //    果冻壁内阴影等冗余光效）
    final liqTop =
        (((tintAlpha ?? (isDark ? 96 : 118)) * op) * tuning.tintScale).round();
    final liqBot = ((tintAlpha != null
                ? (tintAlpha! - 60).clamp(8, 255)
                : (isDark ? 46 : 62)) *
            op *
            tuning.tintScale)
        .round();
    // 背景完全透明（op==0）时仍保留果冻边缘描边与折射扭曲，
    // 仅去掉玻璃体感的底色渐变 —— 达到"仅边缘扭曲"的全透明液态玻璃
    final fullyTransparent = op <= 0.001;
    // 主题渐变时：体感渐变整体换成 起色→止色 的双色渐变（顶部受光后柔和过渡）
    final bodyGradient = fullyTransparent
        ? null
        : (grad != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(grad.colors.first, Colors.black, 0)!.withAlpha(liqTop),
                  Color.lerp(grad.colors.last, Colors.black, 0.15)!.withAlpha(liqBot),
                ],
                stops: const [0.0, 1.0],
              )
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  baseColor.withAlpha(liqTop),
                  baseColor.withAlpha((liqTop + liqBot) ~/ 2),
                  baseAlt.withAlpha(liqBot),
                ],
                stops: const [0.0, 0.55, 1.0],
              ));
    final glassBody = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: br,
        color: fullyTransparent ? Colors.transparent : null,
        // 体感渐变：上部略亮、下部略暗（保留通透厚度感）或主题渐变
        gradient: bodyGradient,
        // 外沿细描边（遵循主题色时用主题色）；全透明时描边也跟随透明
        border: Border.all(
          color: fullyTransparent
              ? Colors.transparent
              : (follow
                  ? accent.withValues(alpha: isDark ? 0.30 : 0.45)
                  : Colors.white.withValues(alpha: isDark ? 0.14 : 0.28)),
          width: 1,
        ),
      ),
      child: child,
    );

    // 真液态玻璃（GPU shader）：折射 + 镜面高光，与移动端药丸一致。
    // 桌面端默认关闭（gpuGlassEnabled = 引擎支持 && (移动端 || 设置里显式开启 PC 端 GPU 玻璃)）：
    // ImageFilter.shader 的 backdrop 纹理取向与坐标空间在桌面各后端不一致
    // （用户反馈过「PC 玻璃背景倒置且不是壁纸」），关闭后落到下方
    // LiquidGlassBackdrop（高斯模糊 + 倒角高光）→ 背景就是真实壁纸；
    // 另外 Windows 默认 Skia（tools 对 desktop 传 enable-impeller=false）时
    // shaderGlassSupported 本身即为 false。
    // shader 路径里 tint 由 OCLiquidGlass.color 提供（GPU 内部叠加），
    // 内层只保留描边，避免「主题色 + 主题色」双重染色。
    if (gpuGlassEnabledOf(context)) {
      return RepaintBoundary(
        child: OCLiquidGlassGroup(
          // 参数化 settings（含高光强度/位置与额外模糊；实例带缓存）
          settings: liquidGlassSettingsFor(tuning),
          child: OCLiquidGlass(
            borderRadius: radius,
            color: baseColor.withAlpha(liqTop),
            shadow: BoxShadow(
              color: Colors.black.withAlpha(isDark ? 60 : 26),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: br,
                border: Border.all(
                  color: fullyTransparent
                      ? Colors.transparent
                      : (follow
                          ? accent.withValues(alpha: isDark ? 0.30 : 0.45)
                          : Colors.white.withValues(alpha: isDark ? 0.14 : 0.28)),
                  width: 1,
                ),
              ),
              child: child,
            ),
          ),
        ),
      );
    }

    // Skia 回退（Windows 默认）：高斯模糊 + 液态玻璃倒角高光画笔。
    // 光影强度随透明度缩放：全透明时仅剩背景模糊。
    // 注意：不要在外面包 RepaintBoundary——它让含 BackdropFilter 的图层
    // 成为光栅缓存候选，Skia 下玻璃背后内容变化时滤波结果不更新，
    // 玻璃里出现旧文字残影且与当前背景错位（见 LiquidGlassBackdrop 注释）。
    return LiquidGlassBackdrop(
      borderRadius: br,
      sigma: sigma,
      opacity: op,
      shadow: BoxShadow(
        color: Colors.black.withAlpha(isDark ? 60 : 26),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
      child: glassBody,
    );
  }
}

/// 浮动液态玻璃顶栏（**仅桌面端**）—— 每个页面顶部的标题+操作按钮容器。
///
/// 移动端请用 mobile_ui.dart 的 `MobilePillTopBar`（主 Tab）或
/// mobile_top_bar.dart 的 `MobileSubPageTopBar`（二级页）：各调用点都已先按
/// `isMobilePlatform` 分流，因此本组件不再包含移动端分支（原分支依赖的
/// `MobileTopBar` 是不可达的死代码，已删除）。
class GlassTopBar extends StatelessWidget {
  final Widget title;
  final List<Widget> actions;
  /// 绝对居中的内容（如设置页搜索框）
  final Widget? center;
  final double height;

  const GlassTopBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.center,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    // 桌面端：浮动玻璃圆角框（样式跟随「菜单样式」menuStyle）
    final scheme = Theme.of(context).colorScheme;
    final menuStyle = context.select<AppState, String>((s) => s.config.menuStyle);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: GlassPanel(
        radius: 18,
        style: menuStyle,
        child: SizedBox(
          height: height,
          child: Stack(children: [
            // 标题（左）与操作按钮（右）保持原布局
            Positioned.fill(
              child: Row(children: [
                const SizedBox(width: 12),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                    child: title,
                  ),
                ),
                ...actions,
                const SizedBox(width: 4),
              ]),
            ),
            // 居中内容（如搜索框）：水平垂直都绝对居中；
            // Align 不拦截子项外区域的点击（两侧可点到 title/actions）
            if (center != null)
              Positioned(
                left: 0, right: 0, top: 0, bottom: 0,
                child: Align(
                  alignment: Alignment.center,
                  child: center,
                ),
              ),
          ]),
        ),
      ),
    );
  }
}