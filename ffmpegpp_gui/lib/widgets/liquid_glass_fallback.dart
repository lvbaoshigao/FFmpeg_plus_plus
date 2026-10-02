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

/// 本平台下是否走 GPU 液态玻璃 shader 路径。
///
/// 判定 = `shaderGlassSupported && isMobilePlatform`：**只有移动端走 shader**。
///
/// ⚠️ 桌面端（Windows / macOS / Linux）**一律**走 [LiquidGlassBackdrop] 回退，
/// 即使用户在设置里打开了「PC 端 GPU 液态玻璃」也不生效。该开关因此不再被本
/// 函数读取 —— 也刻意**不**再订阅它：订阅只会让拨动开关重建全部玻璃，而它已
/// 不影响任何渲染分支（`shaderGlassSupported` 与 `isMobilePlatform` 都是常量）。
///
/// 为什么桌面端无条件关闭（2026-09-18 实测复现）：
/// * `ImageFilter.shader` 要求 shader 的第一个 vec2 uniform 由引擎写入「绑定纹理
///   尺寸」，第一个 sampler2D 为滤镜输入，而 `FlutterFragCoord()` 处于该纹理的
///   像素空间（Impeller：`Size size = input_snapshot->texture->GetSize();
///   memcpy(uniforms_->data(), ...)`）。而 oc_liquid_glass 写入的形状 / 边界
///   uniform 用的是**场景物理像素**，二者只有在「绑定纹理 = 整帧 **且** 当前 pass
///   的 snapshot 变换为恒等」时才一致。
/// * 桌面端的窗口缩放 / 子 pass 变换让该条件不成立 → 采样到的不是壁纸。实测
///   （用户开启该开关后的截图）：**顶栏 / 左侧菜单栏 / 页签栏的玻璃里出现被放大
///   错位的壁纸片段** —— 顶栏显示的是壁纸底部的橙色地平线，而它背后实际是深色
///   夜空；侧栏显示的是大幅放大的树影。与历史反馈「PC 玻璃背景倒置且不是壁纸」
///   完全一致。
/// * 该路径同时是内存最贵的：每个玻璃面都要为 backdrop 压一层滤镜图层，桌面端
///   实测开关前后进程内存相差约 200MB（480MB ↔ 280MB）。
///
/// 结论：桌面端要恢复 shader 玻璃，必须先把坐标系 / y 取向问题在桌面后端上修掉
/// （需要能实机验证 Skia/ANGLE/Vulkan 各组合），在那之前不提供可用入口。
bool gpuGlassEnabledOf(BuildContext context) {
  return shaderGlassSupported && isMobilePlatform;
}

/// 按用户配置参数化的液态玻璃 settings（带实例缓存）。
///
/// 为什么不直接 `OCLiquidGlassSettings(...)`：每次 build 新建实例会重新下发
/// shader uniform，移动端表现为液态玻璃「来回跳跃」闪烁（历史踩坑）。
/// 这里按参数哈希缓存同一个实例 —— 参数没变就复用同一对象；只有用户真的拖动
/// 「玻璃细节」滑块时才产生新实例（此时本来就该重绘一次）。
OCLiquidGlassSettings _cachedGlassSettings = kLiquidGlassSettings;
int _cachedGlassSettingsHash = 0;

OCLiquidGlassSettings liquidGlassSettingsFor(GlassTuning t) {
  final int h = Object.hash(t.highlight, t.lightPos, t.blur);
  if (_cachedGlassSettingsHash == h) return _cachedGlassSettings;
  _cachedGlassSettingsHash = h;
  // 高光强度 → specStrength（基准 0.5）；高光位置 → specAngle（基准 4°）；
  // 模糊度 → blurRadiusPx，只取「超过基准」的部分（见 kGlassBlurBaseline）。
  // 边缘光在 shader 路径由上层容器的描边承担：shader 自带的 lightband 会画成
  // 一条横贯的亮带，在高卡片上像一条「分界线」，实测观感很差，故不启用。
  return _cachedGlassSettings = OCLiquidGlassSettings(
    refractStrength: kLiquidGlassSettings.refractStrength,
    blurRadiusPx: t.shaderExtraBlur,
    specStrength: (kLiquidGlassSettings.specStrength * t.highlight).clamp(0.0, 2.0),
    specPower: kLiquidGlassSettings.specPower,
    specWidth: kLiquidGlassSettings.specWidth,
    specAngle: 4 + t.lightPos * 180,
    lightbandStrength: 0.0,
    lightbandColor: Colors.white,
  );
}

/// 玻璃高斯模糊 σ：Windows 沿用既有上限。
///
/// σ16/18 的高斯模糊要在面板尺寸之外再多分配约 3σ 的离屏纹理；降到 12 视觉几乎
/// 无差别但内存明显更低（见 glass_panel 的注释）。
double effectiveGlassSigma(double value) =>
    isWindowsPlatform ? value.clamp(0.0, 12.0) : value.clamp(0.0, 24.0);

/// `ImageFilter.blur` 的进程级实例缓存（所有玻璃表面统一走这里）。
///
/// 为什么必须缓存（2026-09-25 玻璃内存审查）：
/// `ui.ImageFilter.blur(...)` 每次调用都会新建一个持有 **native handle** 的
/// Dart 对象，并向 GC 注册 finalizer。而本项目里所有玻璃件（卡片 / 面板 /
/// 药丸 / 滑块轨道 / 底栏 / CSD 标题栏）都是在 `build` 里现场构造 filter：
/// 列表滚动时「每帧 × 每张可见玻璃卡」各新建一个，`BackdropFilter` 拿到后
/// 又原样传给引擎。这些对象本身很小，但 **native 侧的资源要等 GC 跑完才回收**，
/// 高频滚动时表现为「打开玻璃后内存持续上涨、停下来也不立刻回落」。
///
/// σ 的取值集合是有限的（各表面基准 σ 固定、只随「模糊度」滑块等比缩放，
/// Windows 还统一钳到 ≤12），所以按 σ 缓存后这些分配可以降到零，且
/// `BackdropFilter` 内部用 `==` 比较 filter —— 命中同一实例还能顺带省掉
/// 一次无谓的 `markNeedsPaint`。
///
/// 容量上限：[kGlassBlurCacheMax]。拖「模糊度」滑块时 σ 是连续值，会产生
/// 大量互不相同的键；超过上限直接整体清空重建（代价只是随后几帧重新分配，
/// 可忽略），避免缓存无限增长。缓存永不 dispose —— 最多几十个实例，
/// 常驻开销可忽略，而 dispose 反而可能让仍在帧内使用的对象失效。
const int kGlassBlurCacheMax = 64;
final Map<double, ImageFilter> _glassBlurCache = <double, ImageFilter>{};

/// 取一个 σ 对应的、可复用的 [ImageFilter.blur]（见 [kGlassBlurCacheMax]）。
///
/// 语义与 `ImageFilter.blur(sigmaX: s, sigmaY: s)` 完全一致，σ ≤ 0 时返回
/// 同一个「零模糊」实例（与现状一致：`BackdropFilter` 收到 σ=0 等价于不模糊）。
ImageFilter cachedGlassBlur(double sigma) {
  if (!sigma.isFinite || sigma <= 0) return _kGlassZeroBlur;
  final cached = _glassBlurCache[sigma];
  if (cached != null) return cached;
  if (_glassBlurCache.length >= kGlassBlurCacheMax) {
    _glassBlurCache.clear();
  }
  return _glassBlurCache[sigma] =
      ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
}

final ImageFilter _kGlassZeroBlur = ImageFilter.blur(sigmaX: 0, sigmaY: 0);

/// 液态玻璃（GPU shader）路径的基准模糊度。
///
/// 用户可调的 `glassBlur` 是**绝对 σ**（模糊样式 / 走 Skia 回退的玻璃都用它）。
/// 而 GPU shader 内部本来就不做高斯模糊（`blurRadiusPx` 一直是 0，观感是
/// 「清晰 + 折射」），若把 σ 直接灌进去会平白改变既有观感。因此 shader 路径只
/// 额外模糊「超过本基准」的部分：`glassBlur == 16`（默认）→ 0，与改动前一致；
/// 往上调才会变糊，往下调不会变清晰（下限就是 0）。
const double kGlassBlurBaseline = 16.0;

/// 「调用点基准 σ → 生效 σ」的统一换算。
///
/// 为什么是**等比**而不是直接取 `tuning.blur`：各玻璃表面的历史基准 σ 本来就
/// 不同（卡片 16、GlassPanel 默认 12、命令页参考卡与编辑器面板 6、CSD 窗口
/// 标题栏 18），直接取绝对值会把默认观感统一改成 16。等比换算保证
/// **默认参数（glassBlur = 16）= 各表面 σ 与改动前逐像素一致**，只有用户真的
/// 拖动「模糊度」滑块时全部同步增减；Windows 上再由 [effectiveGlassSigma]
/// 钳到 ≤12（离屏纹理内存，见其注释）。
///
/// 凡是不想被「模糊度」滑块牵动的固定玻璃，请显式写常量并注明理由。
double tunedGlassSigma(double base, GlassTuning tuning) =>
    effectiveGlassSigma(base * (tuning.blur / kGlassBlurBaseline));

/// 「调用点基准 tint alpha → 生效 alpha」：乘以 [GlassTuning.tintScale]（通透度）。
///
/// 与 [tunedGlassSigma] 同理：默认通透度（0.45）→ 系数 1.0，各表面默认 alpha
/// 不变；拖动「通透度」滑块时全部同步增减。
int tunedGlassAlpha(int baseAlpha, GlassTuning tuning) =>
    (baseAlpha * tuning.tintScale).round().clamp(0, 255);

/// 通透度的基准值（= [AppConfig.glassClarity] 的默认值）。
/// 见 [GlassTuning.tintScale]：默认值即系数 1.0（各处默认 alpha 不变）。
const double kGlassClarityBaseline = 0.45;

/// 边缘光缩放：把「基准描边」按 edge 参数放大 / 缩小。
/// edge = 1（默认）时返回原值，保证默认观感不变。
({double alpha, double width}) edgeBorder(
    double baseAlpha, double baseWidth, double edge) {
  final e = edge.clamp(0.0, 2.0);
  return (
    alpha: (baseAlpha * e).clamp(0.0, 1.0),
    width: (baseWidth * e).clamp(0.0, 3.0),
  );
}

/// 「设置 → 样式 → 玻璃细节」的参数包（也是 `context.select` 的配置指纹）。
///
/// 为什么打包成一个值对象：玻璃的所有渲染路径（AppCard / MobileGlassPill /
/// MobileBottomNav / LiquidGlassBackdrop / GlassPanel）都要读同一份参数，
/// 逐字段 select 会让每处都写 5 个 select；打包后只订阅一次，且只有真的
/// 影响渲染的字段变化才重建（进度/日志等高频 notify 不会重建玻璃）。
@immutable
class GlassTuning {
  /// 模糊度（σ，0~30）
  final double blur;
  /// 通透度（0~1）：越大越通透（底色越淡）
  final double clarity;
  /// 高光强度（0~1.6，1 = 基准）
  final double highlight;
  /// 高光位置（0~1）：0 = 左上受光（基准），1 = 右下受光
  final double lightPos;
  /// 边缘光强度（0~2，1 = 基准）
  final double edge;

  const GlassTuning({
    this.blur = 16.0,
    this.clarity = 0.45,
    this.highlight = 1.0,
    this.lightPos = 0.0,
    this.edge = 1.0,
  });

  /// tint alpha 系数：`tintAlpha = 255 × tintFactor × cardOpacity`。
  double get tintFactor => (1.0 - clarity).clamp(0.0, 1.0);

  /// 相对于「基准通透度」的 tint 缩放系数。
  ///
  /// 各调用点的基准 alpha 表达式写法不同（卡片 `130×op`、药丸与底栏
  /// `255×op`），直接统一成 `255×(1-clarity)×op` 会让默认观感发生变化。
  /// 这里改为**等比缩放**：默认 clarity（0.45）→ 系数 1.0，各处的默认 alpha
  /// 与改动前逐像素一致；拖动通透度滑块时全部同步增减。
  double get tintScale =>
      (tintFactor / (1.0 - kGlassClarityBaseline)).clamp(0.0, 4.0);

  /// 走 GPU shader 时的额外模糊 σ（见 [kGlassBlurBaseline]）。
  double get shaderExtraBlur =>
      (blur - kGlassBlurBaseline).clamp(0.0, 30.0);

  @override
  bool operator ==(Object other) =>
      other is GlassTuning &&
      other.blur == blur &&
      other.clarity == clarity &&
      other.highlight == highlight &&
      other.lightPos == lightPos &&
      other.edge == edge;

  @override
  int get hashCode => Object.hash(blur, clarity, highlight, lightPos, edge);
}

/// 订阅玻璃细节参数。
GlassTuning glassTuningOf(BuildContext context) =>
    context.select<AppState, GlassTuning>((s) {
      final c = s.config;
      return GlassTuning(
        blur: c.glassBlur,
        clarity: c.glassClarity,
        highlight: c.glassHighlight,
        lightPos: c.glassLightPos,
        edge: c.glassEdge,
      );
    });

/// 真正的中性灰：把颜色中的彩度抹掉。
///
/// 为什么需要：「灰色」表面样式用的是 `ColorScheme.surfaceContainerHigh`，
/// 而 `ColorScheme.fromSeed` 生成的 neutral 色**带有种子色的色相偏移**
/// （Material You 的 tonalSpot 方案），于是选了「灰色」卡片仍会泛出主题色的
/// 色偏 —— 用户反馈「样式选成灰色后是灰色夹杂主题色」。这里统一去饱和。
Color neutralGray(Color c) => HSLColor.fromColor(c).withSaturation(0).toColor();

/// 「跟随主题色 / 玻璃底色遵循主题色」使用的**协调主题色**。
///
/// `scheme.primary` 在暗色主题下是 tone 80 的高亮色，大面积铺成卡片底色非常
/// 刺眼（用户反馈「选择主题色又很亮」）。按 [tone] 与表面色混合后得到一个
/// 低饱和、与界面协调的底色；[tone] 由设置页的「主题色协调度」滑块控制
/// （0 = 保留原主题色，0.8 = 几乎并入表面色）。
Color harmonizedAccent(ColorScheme scheme, double tone) {
  final t = tone.clamp(0.0, 0.9);
  if (t <= 0.001) return scheme.primary;
  return Color.lerp(scheme.primary, scheme.surface, t)!;
}

/// 协调主题色的渐变版（主题渐变 themeColor2 生效时用）。
List<Color> harmonizedAccentGradient(
        ColorScheme scheme, List<Color> grad, double tone) =>
    [
      for (final c in grad)
        Color.lerp(c, scheme.surface, tone.clamp(0.0, 0.9))!
    ];


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
///  1. 对角倒角边：受光亮边 → 背光暗边（模拟厚玻璃的折射棱），
///     替代旧版「仅顶部一条高光」的单薄观感；
///  2. 内圈细亮线：玻璃内壁的反光；
///  3. 两团柔和镜面光斑（对应 shader 的 L1/L2 对向灯）。
///
/// 所有透明度都乘 [opacity]，cardOpacity=0 时只剩纯背景模糊。
/// 高光强度 / 位置 / 边缘光三项由「设置 → 样式 → 玻璃细节」控制
/// （[highlight] / [lightPos] / [edge]），默认值 1.0 / 0.0 / 1.0 即改动前观感。
class LiquidGlassPainter extends CustomPainter {
  final BorderRadius borderRadius;
  final double opacity;

  /// 高光强度倍率（0~1.6）
  final double highlight;

  /// 高光位置（0 = 左上受光，1 = 右下受光）
  final double lightPos;

  /// 边缘光强度倍率（0~2）：同时作用于倒角棱线与内圈亮线
  final double edge;

  const LiquidGlassPainter({
    required this.borderRadius,
    this.opacity = 1.0,
    this.highlight = 1.0,
    this.lightPos = 0.0,
    this.edge = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (size.shortestSide < 12) return;
    final o = opacity.clamp(0.0, 1.0);
    if (o <= 0.001) return;
    final h = highlight.clamp(0.0, 1.6);
    final e = edge.clamp(0.0, 2.0);
    final p = lightPos.clamp(0.0, 1.0);
    // 高光与边缘光都被关掉时不必建绘制层。
    if (h <= 0.001 && e <= 0.001) return;

    final rrect = RRect.fromRectAndCorners(
      Offset.zero & size,
      topLeft: borderRadius.topLeft,
      topRight: borderRadius.topRight,
      bottomLeft: borderRadius.bottomLeft,
      bottomRight: borderRadius.bottomRight,
    );
    canvas.save();
    canvas.clipRRect(rrect);

    // 受光方向：p=0 → 左上（基准），p=1 → 右下。渐变轴随之翻转。
    final begin = Alignment(-1 + 2 * p, -1 + 2 * p);
    final end = Alignment(1 - 2 * p, 1 - 2 * p);

    // 1) 对角倒角边：亮→暗过渡的棱边
    if (e > 0.001) {
      final rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (1.8 * e).clamp(0.4, 4.0)
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: [
            Colors.white.withValues(alpha: (0.50 * e).clamp(0.0, 1.0) * o),
            Colors.white.withValues(alpha: (0.06 * e).clamp(0.0, 1.0) * o),
            Colors.black.withValues(alpha: (0.18 * e).clamp(0.0, 1.0) * o),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(rrect.outerRect);
      canvas.drawRRect(rrect.deflate(0.7), rim);

      // 2) 内圈细亮线（玻璃内壁反光）
      canvas.drawRRect(
        rrect.deflate(2.2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (0.8 * e).clamp(0.3, 2.0)
          ..color = Colors.white.withValues(alpha: (0.10 * e).clamp(0.0, 1.0) * o),
      );
    }

    // 3) 对向镜面光斑：主光 + 副光（柔和径向渐变）。位置随 lightPos 沿对角线移动。
    if (h > 0.001) {
      final shortest = size.shortestSide;
      final spotR = shortest * 0.55;
      void spot(Offset c, double alpha) {
        canvas.drawCircle(
          c,
          spotR,
          Paint()
            ..shader = RadialGradient(
              colors: [
                Colors.white.withValues(alpha: (alpha * h).clamp(0.0, 1.0)),
                Colors.white.withValues(alpha: 0.0),
              ],
            ).createShader(Rect.fromCircle(center: c, radius: spotR)),
        );
      }

      Offset along(double fromX, double fromY, double toX, double toY) =>
          Offset(size.width * (fromX + (toX - fromX) * p),
              size.height * (fromY + (toY - fromY) * p));

      spot(along(0.14, 0.10, 0.86, 0.90), 0.10 * o);
      spot(along(0.88, 0.92, 0.12, 0.08), 0.06 * o);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(LiquidGlassPainter old) =>
      old.borderRadius != borderRadius ||
      old.opacity != opacity ||
      old.highlight != highlight ||
      old.lightPos != lightPos ||
      old.edge != edge;
}

/// 无 Impeller 平台的液态玻璃回退容器：
/// 阴影 → 圆角裁剪 → 高斯模糊 backdrop → [LiquidGlassPainter] 倒角高光 → child。
/// 视觉上保留「通透 + 模糊 + 玻璃棱边光泽」的液态玻璃体感，仅没有 GPU 折射。
class LiquidGlassBackdrop extends StatelessWidget {
  final BorderRadius borderRadius;
  /// 背景模糊 σ。调用方自行处理平台 clamp（如 Windows 限 12）。
  /// 传 null 时取自「设置 → 样式 → 玻璃细节」的模糊度。
  final double? sigma;
  final double opacity;
  final BoxShadow? shadow;
  final Widget child;

  const LiquidGlassBackdrop({
    super.key,
    required this.borderRadius,
    this.sigma,
    this.opacity = 1.0,
    this.shadow,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // 高光 / 位置 / 边缘光统一从配置读，调用方无需逐个透传。
    final tuning = glassTuningOf(context);
    final resolvedSigma = sigma ?? tuning.blur;
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
        filter: cachedGlassBlur(resolvedSigma),
        child: CustomPaint(
          painter: LiquidGlassPainter(
            borderRadius: borderRadius,
            opacity: opacity,
            highlight: tuning.highlight,
            lightPos: tuning.lightPos,
            edge: tuning.edge,
          ),
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