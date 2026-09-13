import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';

import '../platform/app_platform.dart';
import '../providers/app_state.dart';

/// 液态玻璃能力判定与 Skia 回退渲染。
///
/// 背景：oc_liquid_glass 的「真液态玻璃」（折射/镜面高光/光斑）依赖
/// `ImageFilter.shader` 作为 backdrop 滤镜，而 dart:ui 明确
/// `ImageFilter.isShaderFilterSupported == _impellerEnabled` —— 只有
/// Impeller 渲染引擎支持。flutter tools 对桌面端（platformDefault）总是传
/// `enable-impeller=false`（flutter_tools/src/desktop_device.dart），因此
/// **Windows 默认 Skia 下 shader 玻璃整体跳过（_RenderLiquidGlassGroup.paint
/// 直接退回 super.paint），玻璃完全不可见**。
///
/// 所有液态玻璃分支必须先用 [gpuGlassEnabledOf] gate：
/// - true（移动端，或桌面端用户在设置里显式开启 PC GPU 玻璃）：走 GPU shader；
/// - false：用 [LiquidGlassBackdrop]（高斯模糊 + 液态玻璃倒角高光画笔）回退，
///   保证玻璃可见、且背景就是真实壁纸而不是整块消失/倒置。

/// 当前平台是否支持 shader 级液态玻璃 backdrop。
bool get shaderGlassSupported => ImageFilter.isShaderFilterSupported;

/// 液态玻璃 shader 的统一参数（全应用唯一一份 const 实例）。
///
/// 必须保持 const：所有玻璃共用同一实例，避免每次 build 新建 settings
/// 触发 shader uniform 重置（表现为液态玻璃「来回跳跃」）。
/// （历史上这里还有「折射强度 / 镜面高光」两个可调项，用户实测无感且多余，已移除；
///  模糊强度同理：真正影响到的是回退/模糊分支的 σ，由各调用点常量 + [effectiveGlassSigma] 决定。）
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

/// 本平台 + 本配置下是否走 GPU 液态玻璃 shader 路径。
///
/// 判定 = `shaderGlassSupported && (isMobilePlatform || cfg.glassGpuOnDesktop)`：
/// **移动端始终走 shader；桌面端默认不走 shader**，只有用户在设置里显式开启
/// 「PC 端 GPU 液态玻璃」才走。依据（dart:ui 官方文档 + 引擎实现）：
/// * `ImageFilter.shader` 要求 shader 的第一个 vec2 uniform 由引擎写入
///   「绑定纹理尺寸」，第一个 sampler2D 为滤镜输入，而 `FlutterFragCoord()`
///   处于该纹理的像素空间（Impeller runtime_effect_filter_contents.cc：
///   `Size size = input_snapshot->texture->GetSize(); memcpy(uniforms_->data(), ...)`）。
///   本仓库的 Dart 侧把**场景物理像素**写进 uniform，只有在「绑定纹理 = 整帧、
///   且当前 pass 的 snapshot 变换为恒等」时才成立——桌面端的窗口缩放 / 子 pass
///   变换会让它不成立，采样到的就不是壁纸。
/// * y 取向只在 Impeller 的 OpenGL(ES) 后端需要翻转（官方文档：`#ifdef
///   IMPELLER_TARGET_OPENGLES` 时 `uv.y = 1.0 - uv.y`），Metal/Vulkan 不翻；
///   桌面后端组合无法在本机逐一验证，用户反馈过 PC 上「玻璃背景倒置且不是壁纸」。
/// 结论：PC 默认退回 [LiquidGlassBackdrop]（高斯模糊 + 倒角高光），背景即真实
/// 壁纸；想要 shader 玻璃的用户可在设置→外观→样式里手动开启。
///
/// 注意：`context.select` 必须无条件调用（不能写进 `||` 的短路里），否则订阅不一致。
bool gpuGlassEnabledOf(BuildContext context) {
  final bool onDesktop =
      context.select<AppState, bool>((s) => s.config.glassGpuOnDesktop);
  return shaderGlassSupported && (isMobilePlatform || onDesktop);
}

/// 玻璃高斯模糊 σ：Windows 沿用既有上限。
///
/// σ16/18 的高斯模糊要在面板尺寸之外再多分配约 3σ 的离屏纹理；降到 12 视觉几乎
/// 无差别但内存明显更低（见 glass_panel 的注释）。
double effectiveGlassSigma(double value) =>
    isWindowsPlatform ? value.clamp(0.0, 12.0) : value.clamp(0.0, 24.0);

/// 「设置 → 样式 → 添加边框」的配置指纹（供 `context.select` 细粒度订阅）。
///
/// 用值对象而不是分别 select 三个字段：Selector 只会在「开启状态/颜色/宽度」
/// 任一变化时重建调用方，进度/日志等高频 notify 不会重建玻璃面板。
@immutable
class BorderStyleCfg {
  final bool enabled;
  final int color;
  final double width;
  const BorderStyleCfg({required this.enabled, required this.color, required this.width});

  @override
  bool operator ==(Object other) =>
      other is BorderStyleCfg &&
      other.enabled == enabled &&
      other.color == color &&
      other.width == width;

  @override
  int get hashCode => Object.hash(enabled, color, width);
}

/// 订阅「添加边框」配置。
BorderStyleCfg borderStyleOf(BuildContext context) =>
    context.select<AppState, BorderStyleCfg>((s) {
      final c = s.config;
      return BorderStyleCfg(
        enabled: c.borderEnabled,
        color: c.borderColor,
        width: c.borderWidth,
      );
    });

/// 给任意卡片/药丸叠加一条「用户可配置的边框」（设置 → 样式 → 添加边框）。
///
/// 为什么用「叠一层」而不是改各分支的 BoxDecoration：
/// * 卡片/药丸在主题/液态/模糊/灰色各分支里的 border 表达式都不一样，逐个改容易漏；
/// * 关闭边框时**必须与原状完全一致** —— 这里直接原样返回 child（连 DecoratedBox
///   都不建），不会有任何像素或布局差异。
///
/// 开启时用 [DecorationPosition.foreground] 把同圆角描边画在 child **之上**：
/// * 纯绘制层、不参与布局（RenderDecoratedBox 原样透传约束），因此不会像 Stack
///   那样把原本靠父级紧约束撑满的卡片/药丸放开成 loose 约束而缩水；
/// * 画在最上层，所以无论对应分支是纯色、BackdropFilter 还是 oc_liquid_glass
///   shader，边框都可见，且完全不依赖 shader 的输出；
/// * 不需要 IgnorePointer：DecoratedBox 本身不拦截命中测试。
Widget withConfigurableBorder(
  BuildContext context,
  Widget child, {
  required BorderRadius radius,
}) {
  final BorderStyleCfg cfg = borderStyleOf(context);
  // 未开启 / 宽度非正 → 原样返回调用方原有的渲染结果。
  // 绝不画 width:0 的描边：那会多出一个绘制层（且 strokeWidth 0 在部分后端
  // 仍按发丝线渲染），破坏「关闭时与改动前像素一致」的约定。
  if (!cfg.enabled || cfg.width <= 0) return child;
  return DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      borderRadius: radius,
      border: Border.all(color: Color(cfg.color), width: cfg.width),
    ),
    child: child,
  );
}

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
    // 图层算法注意（Skia/Windows 实测相关）：
    // 1. 这里绝不能再包 RepaintBoundary。BackdropFilter 的输入（背后场景）
    //    在 Skia 下会被光栅缓存——若外层有 RepaintBoundary，玻璃自身内容
    //    不变时引擎直接复用上一次的滤波快照，背后的文字滚动后玻璃里仍是
    //    旧文字残影、且与当前位置的背景对不上。Flutter 官方 BackdropFilter
    //    用法（CupertinoNavBar 等）外层都不加 RepaintBoundary。
    // 2. 光影画笔用 painter（内容之下）而非 foregroundPainter（内容之上）：
    //    大半径镜面光斑叠在文字上会形成「玻璃里有东西」的脏观感。
    Widget glass = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: CustomPaint(
          painter: LiquidGlassPainter(
              borderRadius: borderRadius, opacity: opacity),
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