import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

/// 玻璃面板 —— 支持三种效果（由设置→外观→玻璃效果控制）：
/// - liquid：液态玻璃（3D 凸起果冻：高通透 + 背景模糊折射放大 + 果冻立体光影）
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
    final follow = cfg.glassFollowTheme;
    final baseColor = follow ? scheme.primary : scheme.surface;
    final baseAlt = follow ? scheme.tertiary : scheme.surface;
    final borderColor = follow ? scheme.primary.withAlpha(isDark ? 110 : 150) : scheme.outlineVariant;
    // 主题渐变色：设置了 themeColor2（>=0）时，主题色在 themeColor→themeColor2 之间渐变
    final grad = (cfg.themeColor2 >= 0)
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(cfg.themeColor), Color(cfg.themeColor2)],
          )
        : null;

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

    // 液态玻璃（默认）：3D 凸起果冻样式
    //  - 高通透：玻璃底色 alpha 低，背景清晰透出
    //  - 背景模糊 + 1.06 倍折射放大（透镜感）
    //  - 果冻光影：顶部/左上受光高亮、底部/右下背光暗影、左上镜面光斑、
    //    果冻壁内阴影、悬浮投影 —— 全部静态，一次 paint 完成
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
        // 凸起果冻的体感渐变：上部亮、下部暗（模拟球面受光）或主题渐变
        gradient: bodyGradient,
        // 果冻外沿：细的亮描边（遵循主题色时用主题色）；
        // 全透明时描边也跟随透明，仅保留折射效果导致的边缘视觉
        border: Border.all(
          color: fullyTransparent
              ? Colors.transparent
              : (follow
                  ? scheme.primary.withValues(alpha: isDark ? 0.35 : 0.55)
                  : Colors.white.withValues(alpha: isDark ? 0.16 : 0.34)),
          width: 1,
        ),
      ),
      child: child,
    );
    // 折射放大倍数（1.06：玻璃内图案比玻璃外胀大，边缘被圆角裁切出透镜感）
    const zoom = 1.06;
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: br,
          boxShadow: [
            // 悬浮投影：果冻"突出"于背景之上
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 88 : 42),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 36 : 16),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
            // 左上柔光：果冻受光面的环境光
            BoxShadow(
              color: Colors.white.withAlpha(isDark ? 14 : 34),
              blurRadius: 14,
              offset: const Offset(-3, -3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: br,
          child: BackdropFilter(
            filter: ImageFilter.compose(
              outer: ImageFilter.matrix(
                Float64List.fromList([
                  zoom, 0, 0, 0, //
                  0, zoom, 0, 0, //
                  0, 0, 1, 0, //
                  0, 0, 0, 1,
                ]),
              ),
              inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            ),
            child: _LiquidGlassBody(
              borderRadius: br,
              opacity: op, // 光影强度随透明度缩放：全透明时仅剩边缘折射
              child: glassBody,
            ),
          ),
        ),
      ),
    );
  }
}

/// 液态玻璃层：模糊由外层 BackdropFilter 提供；此处只叠加**静态**光影来模拟
/// 3D 凸起果冻：
///  - 顶部/左上受光高亮边 + 底部/右下背光暗边（立体边缘）
///  - 左上镜面光斑（果冻表面反光）
///  - 上亮下暗的体感渐变 + 果冻壁内阴影（厚度）
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

/// 3D 凸起果冻光影画笔。
class _LiquidGlassPainter extends CustomPainter {
  final BorderRadius borderRadius;
  final double opacity;
  _LiquidGlassPainter({required this.borderRadius, this.opacity = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (size.shortestSide < 12) return;
    // 透明度为 0：完全透明，仅保留背景折射（由外层 BackdropFilter 的矩阵放大
    // 提供边缘扭曲），不再叠加任何光影
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

    // 1) 果冻立体边缘：SweepGradient 从顶部开始 —— 顶部/左上受光高亮，
    //    底部/右下背光暗影，形成"凸起"的立体描边
    final edge = Paint()
      ..shader = SweepGradient(
        startAngle: -1.5708, // 从顶部 (-π/2) 开始
        endAngle: 3.14159 * 2 - 1.5708,
        colors: [
          Colors.white.withValues(alpha: 0.52 * o), // 顶部高光
          Colors.white.withValues(alpha: 0.30 * o), // 右上
          Colors.black.withValues(alpha: 0.12 * o), // 底部阴影
          Colors.black.withValues(alpha: 0.05 * o), // 左下
          Colors.white.withValues(alpha: 0.52 * o), // 回到顶部
        ],
        stops: const [0.0, 0.22, 0.5, 0.78, 1.0],
      ).createShader(rrect.outerRect);
    final rimW = size.shortestSide > 120 ? 2.4 : 1.8;
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rimW
        ..shader = edge.shader,
    );

    // 2) 左上镜面光斑（果冻表面反光，椭圆形高光）
    canvas.drawRRect(
      rrect.deflate(3),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.55, -0.65),
          radius: 1.0,
          colors: [
            Colors.white.withValues(alpha: 0.22 * o),
            Colors.white.withValues(alpha: 0.06 * o),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    // 3) 体感渐变：顶部受光偏亮、底部背光偏暗（果冻球面感）
    canvas.drawRRect(
      rrect.deflate(1.2),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.10 * o),
            Colors.white.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.09 * o),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(rrect.outerRect),
    );

    // 4) 果冻壁内阴影：底部 + 右侧一圈内暗边（果冻厚度/凝胶感）
    canvas.drawRRect(
      rrect.deflate(0.8),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.10 * o),
          ],
          stops: const [0.0, 0.72, 1.0],
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
