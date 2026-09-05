import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';

/// 液态玻璃能力判定与 Skia 回退渲染。
///
/// 背景：oc_liquid_glass 的「真液态玻璃」（折射/镜面高光/光斑）依赖
/// `ImageFilter.shader` 作为 backdrop 滤镜，而 dart:ui 明确
/// `ImageFilter.isShaderFilterSupported == _impellerEnabled` —— 只有
/// Impeller 渲染引擎支持。flutter tools 对桌面端（platformDefault）总是传
/// `enable-impeller=false`，因此 **Windows 默认 Skia 下 shader 玻璃整体跳过
/// （_RenderLiquidGlassGroup.paint 直接退回 super.paint），玻璃完全不可见**。
///
/// 所有液态玻璃分支必须先用 [shaderGlassSupported] gate：
/// - true（移动端 / macOS / 手动 --enable-impeller 的 Windows）：走 GPU shader；
/// - false：用 [LiquidGlassBackdrop]（高斯模糊 + 液态玻璃倒角高光画笔）回退，
///   保证玻璃可见而不是整块消失。

/// 当前平台是否支持 shader 级液态玻璃 backdrop。
bool get shaderGlassSupported => ImageFilter.isShaderFilterSupported;

/// 液态玻璃 shader 统一参数（与移动端药丸/卡片/底部导航同取值的保守配置）。
/// 必须保持 const：每次 build 新建 settings 会触发 shader uniform 重置
/// （表现为液态玻璃「来回跳跃」）。
const OCLiquidGlassSettings kLiquidGlassSettings = OCLiquidGlassSettings(
  // refractStrength（负 = 凹透镜）给水滴折射；spec 给柔和的角部镜面光泽；
  // blurRadiusPx/lightbandStrength 关闭（光带在较高内容上是横向分界线）。
  refractStrength: -0.10,
  blurRadiusPx: 0.0,
  specStrength: 0.5,
  specPower: 48,
  specWidth: 10,
  lightbandStrength: 0.0,
  lightbandColor: Colors.white,
);

/// Skia 回退的液态玻璃光影画笔 —— 画在内容**之上**的前景层：
///  1. 对角倒角边：左上受光亮边 → 右下背光暗边（模拟厚玻璃的折射棱），
///     替代旧版「仅顶部一条高光」的单薄观感；
///  2. 内圈细亮线：玻璃内壁的反光；
///  3. 左上/右下两团柔和镜面光斑（对应 shader 的 L1/L2 对向灯）。
///
/// 所有透明度都乘 [opacity]，cardOpacity=0 时只剩纯背景模糊。
class LiquidGlassPainter extends CustomPainter {
  final BorderRadius borderRadius;
  final double opacity;

  const LiquidGlassPainter({required this.borderRadius, this.opacity = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (size.shortestSide < 12) return;
    final o = opacity.clamp(0.0, 1.0);
    if (o <= 0.001) return;
    final rrect = RRect.fromRectAndCorners(
      Offset.zero & size,
      topLeft: borderRadius.topLeft,
      topRight: borderRadius.topRight,
      bottomLeft: borderRadius.bottomLeft,
      bottomRight: borderRadius.bottomRight,
    );
    canvas.save();
    canvas.clipRRect(rrect);

    // 1) 对角倒角边：亮→暗过渡的棱边（受光面在左上）
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.50 * o),
          Colors.white.withValues(alpha: 0.06 * o),
          Colors.black.withValues(alpha: 0.18 * o),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(rrect.outerRect);
    canvas.drawRRect(rrect.deflate(0.7), rim);

    // 2) 内圈细亮线（玻璃内壁反光）
    canvas.drawRRect(
      rrect.deflate(2.2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Colors.white.withValues(alpha: 0.10 * o),
    );

    // 3) 对向镜面光斑：左上主光 + 右下副光（柔和径向渐变）
    final shortest = size.shortestSide;
    final spotR = shortest * 0.55;
    void spot(Offset c, double alpha) {
      canvas.drawCircle(
        c,
        spotR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: alpha),
              Colors.white.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: spotR)),
      );
    }

    spot(Offset(size.width * 0.14, size.height * 0.10), 0.10 * o);
    spot(Offset(size.width * 0.88, size.height * 0.92), 0.06 * o);

    canvas.restore();
  }

  @override
  bool shouldRepaint(LiquidGlassPainter old) =>
      old.borderRadius != borderRadius || old.opacity != opacity;
}

/// 无 Impeller 平台的液态玻璃回退容器：
/// 阴影 → 圆角裁剪 → 高斯模糊 backdrop → [LiquidGlassPainter] 倒角高光 → child。
/// 视觉上保留「通透 + 模糊 + 玻璃棱边光泽」的液态玻璃体感，仅没有 GPU 折射。
class LiquidGlassBackdrop extends StatelessWidget {
  final BorderRadius borderRadius;
  /// 背景模糊 σ。调用方自行处理平台 clamp（如 Windows 限 12）。
  final double sigma;
  final double opacity;
  final BoxShadow? shadow;
  final Widget child;

  const LiquidGlassBackdrop({
    super.key,
    required this.borderRadius,
    this.sigma = 12,
    this.opacity = 1.0,
    this.shadow,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    Widget glass = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: CustomPaint(
          foregroundPainter:
              LiquidGlassPainter(borderRadius: borderRadius, opacity: opacity),
          child: child,
        ),
      ),
    );
    final shadow = this.shadow;
    if (shadow != null) {
      glass = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: [shadow],
        ),
        child: glass,
      );
    }
    return glass;
  }
}
