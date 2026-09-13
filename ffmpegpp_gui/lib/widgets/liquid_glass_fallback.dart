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
/// 所有液态玻璃分支必须先用 [gpuGlassEnabled] gate：
/// - true（移动端，或桌面端用户在设置里显式开启 PC GPU 玻璃）：走 GPU shader；
/// - false：用 [LiquidGlassBackdrop]（高斯模糊 + 液态玻璃倒角高光画笔）回退，
///   保证玻璃可见、且背景就是真实壁纸而不是整块消失/倒置。

/// 当前平台是否支持 shader 级液态玻璃 backdrop。
bool get shaderGlassSupported => ImageFilter.isShaderFilterSupported;

/// 液态玻璃 shader 的统一参数「基准值」。
///
/// 移动端与桌面回退共用这一份取值；设置里的「折射强度 / 镜面高光」会在
/// [glassSettingsFor] 里用它 copyWith 覆盖（见那里的缓存说明）。
/// 必须保持 const：所有玻璃共用同一实例，避免每次 build 新建 settings
/// 触发 shader uniform 重置（表现为液态玻璃「来回跳跃」）。
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

/// GPU 液态玻璃的可配置参数「指纹」（细粒度订阅的返回值）。
///
/// 用 `context.select` 只订阅这四个字段，而不是 watch 整个 AppState：
/// 转码进度 / 日志 / 任务状态等高频 notify 不应该重建玻璃面板
/// （重建会重新下发 shader uniform，移动端表现为玻璃闪烁）。
@immutable
class GlassGpuConfig {
  /// 桌面（PC）是否显式开启 GPU 液态玻璃 shader（AppConfig.glassGpuOnDesktop）
  final bool gpuOnDesktop;
  /// 折射强度（负 = 凹透镜，AppConfig.glassRefractStrength，范围 -0.30~0.0）
  final double refractStrength;
  /// 镜面高光强度（AppConfig.glassSpecStrength，范围 0~2.0）
  final double specStrength;
  /// 高斯模糊 σ（AppConfig.glassBlurSigma，范围 4~24）
  final double blurSigma;

  const GlassGpuConfig({
    required this.gpuOnDesktop,
    required this.refractStrength,
    required this.specStrength,
    required this.blurSigma,
  });

  @override
  bool operator ==(Object other) =>
      other is GlassGpuConfig &&
      other.gpuOnDesktop == gpuOnDesktop &&
      other.refractStrength == refractStrength &&
      other.specStrength == specStrength &&
      other.blurSigma == blurSigma;

  @override
  int get hashCode =>
      Object.hash(gpuOnDesktop, refractStrength, specStrength, blurSigma);
}

/// 订阅玻璃 GPU 参数（细粒度 select，值不变时 Selector 不会重建调用方）。
GlassGpuConfig glassGpuConfigOf(BuildContext context) =>
    context.select<AppState, GlassGpuConfig>((s) {
      final c = s.config;
      return GlassGpuConfig(
        gpuOnDesktop: c.glassGpuOnDesktop,
        refractStrength: c.glassRefractStrength,
        specStrength: c.glassSpecStrength,
        blurSigma: c.glassBlurSigma,
      );
    });

/// 本平台 + 本配置下是否走 GPU 液态玻璃 shader 路径。
///
/// 判定 = `shaderGlassSupported && (isMobilePlatform || cfg.gpuOnDesktop)`：
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
///   桌面后端组合（含用户手动 --enable-impeller 的 Windows/ANGLE）无法在本机
///   逐一验证，用户反馈过 PC 上「玻璃背景倒置且不是壁纸」。
/// 结论：PC 默认退回 [LiquidGlassBackdrop]（高斯模糊 + 倒角高光），背景即真实
/// 壁纸；想要 shader 玻璃的用户可在设置→外观→液态玻璃效果里手动开启。
bool gpuGlassEnabled(GlassGpuConfig cfg) =>
    shaderGlassSupported && (isMobilePlatform || cfg.gpuOnDesktop);

/// 玻璃高斯模糊 σ：由设置驱动。
/// Windows 沿用既有上限（见 glass_panel 注释：σ16/18 的高斯模糊要在面板尺寸
/// 之外再多分配约 3σ 的离屏纹理，降到 12 视觉几乎无差别但内存明显更低）。
double effectiveGlassSigma(GlassGpuConfig cfg) => isWindowsPlatform
    ? cfg.blurSigma.clamp(0.0, 12.0)
    : cfg.blurSigma.clamp(0.0, 24.0);

/// 按配置生成 [OCLiquidGlassSettings]，并按「值」缓存复用。
///
/// 为什么必须缓存：settings 是 OCLiquidGlassGroup 的 widget 参数，每次 build
/// 新建实例会让 _RenderLiquidGlassGroup 认为配置变了 → `markNeedsPaint`，
/// 拖动「折射 / 高光」滑杆时每秒几十次 notify 会退化成持续重绘。
/// * 配置值不变 → 返回同一个实例（配合 OCLiquidGlassSettings 的值相等语义）；
/// * 两个强度都等于基准值 → 直接返回 const 基准实例，保持「所有玻璃共用一份
///   const settings」的既有策略（默认配置下行为与修复前完全一致）。
OCLiquidGlassSettings glassSettingsFor(GlassGpuConfig cfg) {
  final cached = _GlassSettingsCache.instance;
  if (cached != null && _GlassSettingsCache.key == cfg) return cached;
  final OCLiquidGlassSettings result =
      (cfg.refractStrength == kLiquidGlassSettings.refractStrength &&
              cfg.specStrength == kLiquidGlassSettings.specStrength)
          ? kLiquidGlassSettings
          : kLiquidGlassSettings.copyWith(
              refractStrength: cfg.refractStrength,
              specStrength: cfg.specStrength,
            );
  _GlassSettingsCache.key = cfg;
  _GlassSettingsCache.instance = result;
  return result;
}

/// [glassSettingsFor] 的单槽缓存（同一时刻全局只有一份配置，够用且零分配）。
class _GlassSettingsCache {
  static GlassGpuConfig? key;
  static OCLiquidGlassSettings? instance;
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