import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../platform/app_platform.dart';
import 'app_card.dart' show SurfaceStyle;
import 'liquid_glass_fallback.dart';
import 'mobile_top_bar.dart';
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
    final effect = style ?? globalEffect;
    // 透明度：0.0~1.0，映射到背景 alpha；0 时完全透明（仅保留边缘扭曲/折射）
    final op = cardOpacity.clamp(0.0, 1.0);
    final br = BorderRadius.circular(radius);
    // 遵循主题色：底色/渐变用主题色替代 surface 灰，所有元素统一主题色观感
    // 「透明」(none) 与纯色 theme 效果同样退回主题色显示
    final solidTheme = effect == 'none' || effect == SurfaceStyle.theme;
    final baseColor = (follow || solidTheme) ? scheme.primary : scheme.surface;
    final baseAlt = (follow || solidTheme) ? scheme.tertiary : scheme.surface;
    final borderColor = (follow || solidTheme) ? scheme.primary.withAlpha(isDark ? 110 : 150) : scheme.outlineVariant;
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
        // 压低 alpha：快速滚动时 BackdropFilter 偶尔失效，alpha 过高会露出
        // 大面积纯色主题底色（「诡异的玻璃 + 主题色块」）。与 mobile_glass_pill
        // 一致的 120/105 上限，让纯色层在失效时仅表现为轻微 tint，不会被察觉。
        final frostedAlpha = ((isDark ? 105 : 120) * op).round().clamp(0, 255);
        return RepaintBoundary(
          child: ClipRRect(
            borderRadius: br,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
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
          ? scheme.surfaceContainerHigh
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

    // 内存优化：Windows（D3D12）上高斯模糊的中间纹理按「面板尺寸 +
    // 约 3σ 各边 padding」分配，σ 从 16/18 降到 12 时视觉几乎无差别，
    // 但每块玻璃面板的离屏内存明显下降（配合页面常驻上限一起生效）。
    final double sigma = isWindowsPlatform ? blur.clamp(0.0, 12.0) : blur;

    if (effect == 'blur') {
      // 仅高斯模糊背景：半透明 + 模糊，无渐变、无阴影、无折射 —— 最简洁
      return RepaintBoundary(
        child: ClipRRect(
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
        ),
      );
    }

    // 液态玻璃（默认）：简洁通透样式
    //  - 高通透：玻璃底色 alpha 低，背景清晰透出
    //  - 背景模糊（不再做 1.06 放大折射，避免文字/图案畸变）
    //  - 光影简化：仅保留边缘高光描边 + 上亮下暗体感渐变（去除镜面光斑、
    //    果冻壁内阴影等冗余光效）
    final liqTop = ((tintAlpha ?? (isDark ? 96 : 118)) * op).round();
    final liqBot = ((tintAlpha != null
        ? (tintAlpha! - 60).clamp(8, 255)
        : (isDark ? 46 : 62)) * op).round();
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
                  ? scheme.primary.withValues(alpha: isDark ? 0.30 : 0.45)
                  : Colors.white.withValues(alpha: isDark ? 0.14 : 0.28)),
          width: 1,
        ),
      ),
      child: child,
    );

    // 真液态玻璃（Impeller）：GPU shader 折射 + 镜面高光，与移动端药丸一致。
    // Windows 桌面端默认 Skia（tools 对 desktop 传 enable-impeller=false），
    // ImageFilter.shader 不可用 → 自动落入下方 LiquidGlassBackdrop 回退。
    // shader 路径里 tint 由 OCLiquidGlass.color 提供（GPU 内部叠加），
    // 内层只保留描边，避免「主题色 + 主题色」双重染色。
    if (shaderGlassSupported) {
      return RepaintBoundary(
        child: OCLiquidGlassGroup(
          settings: kLiquidGlassSettings,
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
                          ? scheme.primary.withValues(alpha: isDark ? 0.30 : 0.45)
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
    return RepaintBoundary(
      child: LiquidGlassBackdrop(
        borderRadius: br,
        sigma: sigma,
        opacity: op,
        shadow: BoxShadow(
          color: Colors.black.withAlpha(isDark ? 60 : 26),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
        child: glassBody,
      ),
    );
  }
}

/// 浮动液态玻璃顶栏 —— 每个页面顶部的标题+操作按钮容器
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
    if (isMobilePlatform) {
      // 移动端：通用模糊顶栏，无独立圆角矩形框
      // 居中内容（如搜索框）在移动端用 MobileTopBar 的 center 参数暂不支持，
      // 但 settings_page 在移动端会走独立 UI，不再需要 center。
      return MobileTopBar(
        title: title,
        actions: actions,
        height: height,
      );
    }
    // 桌面端：原有的浮动玻璃圆角框（样式跟随「菜单样式」menuStyle）
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
