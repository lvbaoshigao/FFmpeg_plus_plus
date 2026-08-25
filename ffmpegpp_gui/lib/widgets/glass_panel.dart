import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../platform/app_platform.dart';
import 'mobile_top_bar.dart';
import 'mobile_glass_pill.dart';

/// 玻璃面板 —— 支持三种效果（由设置→外观→玻璃效果控制）：
/// - liquid：液态玻璃（高通透 + 背景模糊 + 顶部高光细边 + 体感渐变，简洁）
/// - blur：仅高斯模糊背景（半透明，简洁）
/// - none：无效果（纯色半透明卡片）
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  /// 顶部渐变的不透明度 (0-255)。为空时使用主题默认值。
  final int? tintAlpha;

  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 18,
    this.blur = 16,
    this.padding,
    this.tintAlpha,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 读取玻璃效果配置 + 透明度（cardOpacity 控制玻璃不透明度）
    final cfg = context.watch<AppState>().config;
    final effect = cfg.glassEffect;
    // 透明度：0.0~1.0，映射到背景 alpha；0 时完全透明（仅保留边缘扭曲/折射）
    final op = cfg.cardOpacity.clamp(0.0, 1.0);
    final br = BorderRadius.circular(radius);
    // 遵循主题色：底色/渐变用主题色替代 surface 灰，所有元素统一主题色观感
    // 「透明」(none) 效果同样退回主题色显示
    final follow = cfg.glassFollowTheme;
    final baseColor = (follow || effect == 'none') ? scheme.primary : scheme.surface;
    final baseAlt = (follow || effect == 'none') ? scheme.tertiary : scheme.surface;
    final borderColor = (follow || effect == 'none') ? scheme.primary.withAlpha(isDark ? 110 : 150) : scheme.outlineVariant;
    // 主题渐变色：设置了 themeColor2（>=0）时，主题色在 themeColor→themeColor2 之间渐变
    final grad = (cfg.themeColor2 >= 0)
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(cfg.themeColor), Color(cfg.themeColor2)],
          )
        : null;

    // ── 移动端：真实液态玻璃改用 oc_liquid_glass shader（与底部导航/药丸一致），
    //    下方桌面端分支保持不变。「设置项以毛玻璃展示」开启时，改用更易读的扁平
    //    高斯模糊；blur/none 也统一复用 MobileGlassPill 的对应效果。──
    if (isMobilePlatform) {
      // 「不使用卡片玻璃效果」：跳过液态玻璃/毛玻璃渲染，退回主题色实心卡片
      if (cfg.noCardGlass) {
        final solidAlpha = ((isDark ? 235 : 245) * op).round().clamp(0, 255);
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
      if (cfg.settingsFrostedGlass && effect == 'liquid') {
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

    // 桌面端「不使用卡片玻璃效果」：实心主题色卡片
    if (cfg.noCardGlass) {
      final solidAlpha = ((isDark ? 235 : 245) * op).round().clamp(0, 255);
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

    if (effect == 'none') {
      // 无效果：纯色卡片 + 圆角 + 细边框（透明度跟随）；主题渐变时用渐变底色
      return RepaintBoundary(
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: grad == null ? baseColor.withAlpha(((isDark ? 235 : 245) * op).round()) : null,
            gradient: grad != null
                ? LinearGradient(
                    begin: grad.begin,
                    end: grad.end,
                    colors: grad.colors.map((c) => c.withAlpha(((isDark ? 235 : 245) * op).round())).toList(),
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

    if (effect == 'blur') {
      // 仅高斯模糊背景：半透明 + 模糊，无渐变、无阴影、无折射 —— 最简洁
      return RepaintBoundary(
        child: ClipRRect(
          borderRadius: br,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
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
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: br,
          boxShadow: [
            // 单层悬浮投影（去除双层小阴影与左上柔光，减少光效噪点）
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 60 : 26),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: br,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: _LiquidGlassBody(
              borderRadius: br,
              opacity: op, // 光影强度随透明度缩放：全透明时仅剩背景模糊
              child: glassBody,
            ),
          ),
        ),
      ),
    );
  }
}

/// 液态玻璃层：模糊由外层 BackdropFilter 提供；此处只叠加**静态**简易光影：
///  - 顶部受光的细高光边（无 SweepGradient 环绕，避免光线断层）
///  - 上亮下暗的体感渐变（厚度感）
/// 没有任何动画/漂浮物，一次 paint 完成，性能开销只在尺寸变化时发生。
///
/// 注意：不要在这里用 Stack + Positioned.fill —— 顶栏在 Column 中布局时
/// 会收到无界高度约束（h<=Infinity），Stack 会断言失败导致整页不渲染。
class _LiquidGlassBody extends StatelessWidget {
  final BorderRadius borderRadius;
  final double opacity;
  final Widget child;
  const _LiquidGlassBody({required this.borderRadius, this.opacity = 1.0, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LiquidGlassPainter(borderRadius: borderRadius, opacity: opacity),
      child: child,
    );
  }
}

/// 简洁玻璃光影画笔。
class _LiquidGlassPainter extends CustomPainter {
  final BorderRadius borderRadius;
  final double opacity;
  _LiquidGlassPainter({required this.borderRadius, this.opacity = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (size.shortestSide < 12) return;
    if (opacity <= 0.001) return;
    final o = opacity.clamp(0.0, 1.0);
    final rrect = RRect.fromRectAndCorners(
      Offset.zero & size,
      topLeft: borderRadius.topLeft,
      topRight: borderRadius.topRight,
      bottomLeft: borderRadius.bottomLeft,
      bottomRight: borderRadius.bottomRight,
    );
    canvas.save();
    canvas.clipRRect(rrect);

    // 1) 顶部细高光边（仅顶部一条，简洁不抢眼）
    final edge = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.34 * o),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5],
      ).createShader(rrect.outerRect);
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = edge.shader,
    );

    // 2) 体感渐变：顶部略亮、底部略暗（厚度感）
    canvas.drawRRect(
      rrect.deflate(1.2),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.08 * o),
            Colors.white.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.06 * o),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(rrect.outerRect),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_LiquidGlassPainter old) =>
      old.borderRadius != borderRadius || old.opacity != opacity;
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
    // 桌面端：原有的浮动玻璃圆角框
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: GlassPanel(
        radius: 18,
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
