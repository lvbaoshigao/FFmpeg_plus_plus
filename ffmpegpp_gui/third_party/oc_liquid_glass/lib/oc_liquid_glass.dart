import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

// LiquidGlass Shader Example - Creates realistic glass droplet effects
//
// This file demonstrates a complex shader-based implementation that creates
// liquid glass droplets with realistic refraction, blur, and lighting effects.
// The system uses Flutter's FragmentShader API to apply GPU-accelerated effects.
//
// Key Components:
// - LiquidGlassSettings: Configuration for visual parameters
// - LiquidGlassGroup: Container that manages multiple glass shapes
// - LiquidGlass: Individual glass droplet widget
// - Custom RenderObjects: Handle the low-level rendering and shader application

/// Configuration class that holds all visual parameters for the liquid glass shader effect.
/// These parameters control various aspects like refraction, blur, lighting, and color.
class OCLiquidGlassSettings {
  // Shader uniform parameters - these control the visual appearance of the glass effect
  final double
      blendPx; // Edge blending distance in pixels for smooth transitions
  final double
      refractStrength; // Strength of light refraction (-1.0 to 1.0, negative = concave lens)
  final double
      distortFalloffPx; // Distance over which distortion effect fades out
  final double
      distortExponent; // Controls how sharply distortion falls off (higher = sharper)
  final double blurRadiusPx; // Base blur radius applied to the glass area

  // Specular highlight parameters - creates the shiny reflection on glass surface
  final double specAngle; // Light source angle for specular highlights
  final double specStrength; // Intensity of specular highlights
  final double specPower; // Sharpness of specular highlights (higher = sharper)
  final double specWidth; // Specular width in px

  // Light band effect - creates a bright band across the glass for realism
  final double lightbandOffsetPx; // Distance from edge where light band appears
  final double lightbandWidthPx; // Width of the light band effect
  final double lightbandStrength; // Intensity of the light band
  final Color lightbandColor; // Color of the light band

  const OCLiquidGlassSettings({
    this.blendPx = 5,
    this.refractStrength = -0.06,
    this.distortFalloffPx = 45,
    this.distortExponent = 4,
    this.blurRadiusPx = 0,
    this.specAngle = 4,
    this.specStrength = 20.0,
    this.specPower = 100,
    this.specWidth = 10,
    this.lightbandOffsetPx = 10,
    this.lightbandWidthPx = 30,
    this.lightbandStrength = 0.9,
    this.lightbandColor = Colors.white,
  });

  /// Creates a copy of this settings object with the given fields replaced with new values.
  OCLiquidGlassSettings copyWith({
    double? blendPx,
    double? refractStrength,
    double? distortFalloffPx,
    double? distortExponent,
    double? blurRadiusPx,
    double? specAngle,
    double? specStrength,
    double? specPower,
    double? specWidth,
    double? lightbandOffsetPx,
    double? lightbandWidthPx,
    double? lightbandStrength,
    Color? lightbandColor,
  }) {
    return OCLiquidGlassSettings(
      blendPx: blendPx ?? this.blendPx,
      refractStrength: refractStrength ?? this.refractStrength,
      distortFalloffPx: distortFalloffPx ?? this.distortFalloffPx,
      distortExponent: distortExponent ?? this.distortExponent,
      blurRadiusPx: blurRadiusPx ?? this.blurRadiusPx,
      specAngle: specAngle ?? this.specAngle,
      specStrength: specStrength ?? this.specStrength,
      specPower: specPower ?? this.specPower,
      specWidth: specWidth ?? this.specWidth,
      lightbandOffsetPx: lightbandOffsetPx ?? this.lightbandOffsetPx,
      lightbandWidthPx: lightbandWidthPx ?? this.lightbandWidthPx,
      lightbandStrength: lightbandStrength ?? this.lightbandStrength,
      lightbandColor: lightbandColor ?? this.lightbandColor,
    );
  }

  /// 值相等语义（本类字段全部不可变）。
  /// 用途：liquid_glass_fallback.glassSettingsFor 按值缓存实例；以及
  /// _RenderLiquidGlassGroup 在 settings 未变时跳过 markNeedsPaint —— 否则父级
  /// 每次 rebuild 都会让每张玻璃卡片白白重绘一次 backdrop 滤镜。
  @override
  bool operator ==(Object other) =>
      other is OCLiquidGlassSettings &&
      other.blendPx == blendPx &&
      other.refractStrength == refractStrength &&
      other.distortFalloffPx == distortFalloffPx &&
      other.distortExponent == distortExponent &&
      other.blurRadiusPx == blurRadiusPx &&
      other.specAngle == specAngle &&
      other.specStrength == specStrength &&
      other.specPower == specPower &&
      other.specWidth == specWidth &&
      other.lightbandOffsetPx == lightbandOffsetPx &&
      other.lightbandWidthPx == lightbandWidthPx &&
      other.lightbandStrength == lightbandStrength &&
      other.lightbandColor == lightbandColor;

  @override
  int get hashCode => Object.hash(
        blendPx,
        refractStrength,
        distortFalloffPx,
        distortExponent,
        blurRadiusPx,
        specAngle,
        specStrength,
        specPower,
        specWidth,
        lightbandOffsetPx,
        lightbandWidthPx,
        lightbandStrength,
        lightbandColor,
      );
}

/// Simplified shape data structure used to pass geometry information to the shader.
/// Each LiquidGlass widget gets converted into this format for GPU processing.
/// The border radius is automatically clamped to max(width/2, height/2) to ensure valid geometry.
class ShapeData {
  final Offset center; // Center position of the glass shape
  final Size size; // Width and height of the glass shape
  final double
      borderRadius; // Border radius (clamped to half of smaller dimension)
  final Color color; // Optional tint color for the glass shape
  ShapeData(this.center, this.size, this.borderRadius, this.color);

  Rect get rect => Rect.fromCenter(
        center: center,
        width: size.width,
        height: size.height,
      );
}

class _OCLiquidGlassShaderCache {
  static const String _shaderAsset =
      'packages/oc_liquid_glass/shaders/liquid_glass.frag';

  static FragmentProgram? _program;
  static Future<FragmentProgram>? _programFuture;

  static FragmentProgram? get cachedProgram => _program;

  static Future<FragmentProgram> load() {
    final cached = _program;
    if (cached != null) {
      return Future.value(cached);
    }

    return _programFuture ??= _load();
  }

  static Future<FragmentProgram> _load() async {
    try {
      final program = await FragmentProgram.fromAsset(_shaderAsset);
      _program = program;
      return program;
    } catch (_) {
      _programFuture = null;
      rethrow;
    }
  }
}

/// Container widget that manages multiple liquid glass shapes and applies the shader effect.
/// This widget loads the fragment shader and creates a render layer that collects
/// all LiquidGlass children and applies the unified glass effect to them.
///
/// Usage: Wrap your content with LiquidGlassGroup, then add LiquidGlass widgets
/// anywhere in the child tree to create glass droplets.
class OCLiquidGlassGroup extends StatefulWidget {
  /// Visual settings for the liquid glass shader effect.
  final OCLiquidGlassSettings settings;

  /// Optional external trigger to force the group to repaint (e.g., merged animations).
  final Listenable? repaint;

  /// The child widget tree that may contain LiquidGlass widgets.
  final Widget child;

  const OCLiquidGlassGroup({
    super.key,
    required this.settings,
    required this.child,
    this.repaint,
  });

  /// Loads and caches the liquid glass shader before the first glass widget is
  /// shown. This avoids a visible delay for transient widgets such as toasts.
  static Future<void> precacheShader() async {
    await _OCLiquidGlassShaderCache.load();
  }

  @override
  State<OCLiquidGlassGroup> createState() => _OCLiquidGlassGroupState();
}

class _OCLiquidGlassGroupState extends State<OCLiquidGlassGroup> {
  FragmentProgram? _program = _OCLiquidGlassShaderCache.cachedProgram;

  /// 本 State 独占的 FragmentShader（首次 build 创建后复用）。
  /// 为什么缓存：fragmentShader() 每次调用都会分配一份 uniform 缓冲
  /// （Float32List），而 render object 只在 createRenderObject 里取用一次，
  /// 之后每次 build 新建的实例都会被直接丢弃 —— 父级 rebuild 越频繁越浪费。
  /// 安全前提：每个 group 各持一份实例（uniform 是该实例内的可变状态）；
  /// 且 uniform 取值会在 ImageFilter.shader(shader) 构造时被引擎拷贝快照
  /// （engine/lib/ui/painting/fragment_shader.cc 的 as_image_filter() 里 memcpy）。
  FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (_program != null) {
      return;
    }

    _OCLiquidGlassShaderCache.load().then(
      (program) {
        if (!mounted) {
          return;
        }
        setState(() {
          _program = program;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'oc_liquid_glass',
            context: ErrorDescription('loading the liquid glass shader'),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show child without effect while shader is loading
    if (_program == null) {
      return widget.child;
    }
    // Once shader is loaded, create the render object that applies the effect
    return _LiquidGlassGroupRenderObject(
      shader: _shader ??= _program!.fragmentShader(),
      settings: widget.settings,
      repaint: widget.repaint,
      child: widget.child,
    );
  }
}

/// Internal widget that bridges between Flutter widgets and the custom render object.
/// This creates and manages the RenderLiquidGlassLayer that does the actual rendering.
class _LiquidGlassGroupRenderObject extends SingleChildRenderObjectWidget {
  final FragmentShader shader;

  /// Visual settings for the liquid glass shader effect.
  final OCLiquidGlassSettings settings;

  /// External repaint trigger coming from the widget.
  final Listenable? repaint;

  const _LiquidGlassGroupRenderObject({
    required this.shader,
    required this.settings,
    this.repaint,
    super.child,
  });

  @override
  _RenderLiquidGlassGroup createRenderObject(BuildContext context) {
    // Create the custom render object with device pixel ratio for proper scaling
    final position = Scrollable.maybeOf(context)?.position;
    final media = MediaQuery.of(context);
    final renderObject = _RenderLiquidGlassGroup(
      devicePixelRatio: media.devicePixelRatio,
      screenSize: media.size,
      shader: shader,
      settings: settings,
      position: position,
      externalRepaint: repaint,
    );

    _attachRouteAnimation(context, renderObject);
    return renderObject;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLiquidGlassGroup renderObject,
  ) {
    // Update render object when settings change or device characteristics change
    final position = Scrollable.maybeOf(context)?.position;
    final media = MediaQuery.of(context);
    renderObject
      ..devicePixelRatio = media.devicePixelRatio
      ..screenSize = media.size
      ..settings = settings
      ..scrollPosition = position
      ..externalRepaint = repaint;

    _attachRouteAnimation(context, renderObject);
  }

  void _attachRouteAnimation(BuildContext ctx, _RenderLiquidGlassGroup rb) {
    final List<Listenable> listenables = [];

    // Nearest navigator's route (could be an inner PageRoute inside the sheet)
    final rLocal = ModalRoute.of(ctx);
    if (rLocal?.animation != null) {
      listenables.add(rLocal!.animation!);
    }
    if (rLocal?.secondaryAnimation != null) {
      listenables.add(rLocal!.secondaryAnimation!);
    }

    // Root navigator's current route (e.g., the ModalBottomSheetRoute)
    final rootNav = Navigator.maybeOf(ctx);
    if (rootNav != null) {
      final rRoot = ModalRoute.of(rootNav.context);
      if (rRoot?.animation != null) {
        listenables.add(rRoot!.animation!);
      }
      if (rRoot?.secondaryAnimation != null) {
        listenables.add(rRoot!.secondaryAnimation!);
      }
    }

    // Create merged listenable directly or pass null if empty
    final mergedRouteAnimations =
        listenables.isNotEmpty ? Listenable.merge(listenables) : null;

    rb.setRouteAnimations(mergedRouteAnimations);
  }

  @override
  void didUnmountRenderObject(_RenderLiquidGlassGroup rb) {
    rb.detachRepaintSources();
  }
}

/// The core render object that handles the liquid glass effect.
///
/// This is where the magic happens:
/// 1. Collects geometry data from all LiquidGlass children in the widget tree
/// 2. Converts the geometry to shader uniforms (GPU-readable parameters)
/// 3. Applies the fragment shader as a backdrop filter to create the glass effect
///
/// The shader receives information about up to 4 glass shapes and renders them
/// with realistic refraction, blur, and lighting effects.
class _RenderLiquidGlassGroup extends RenderProxyBox {
  static const int maxRects = 4; // Maximum number of glass shapes supported

  Listenable? _routeAnimations;
  ScrollPosition? _scrollPosition;

  /// Optional external repaint trigger (e.g., merged animations)
  Listenable? _externalRepaint;

  _RenderLiquidGlassGroup({
    required double devicePixelRatio,
    required Size screenSize,
    required FragmentShader shader,
    required OCLiquidGlassSettings settings,
    ScrollPosition? position,
    Listenable? externalRepaint,
  })  : _devicePixelRatio = devicePixelRatio,
        _screenSize = screenSize,
        _shader = shader,
        _settings = settings,
        _scrollPosition = position,
        _externalRepaint = externalRepaint {
    _scrollPosition?.addListener(_onScroll);
    _externalRepaint?.addListener(markNeedsPaint);
  }

  // Allow updates from the element
  set externalRepaint(Listenable? v) {
    if (identical(v, _externalRepaint)) return;
    _externalRepaint?.removeListener(markNeedsPaint);
    _externalRepaint = v;
    _externalRepaint?.addListener(markNeedsPaint);
  }

  // ── scroll binding ──
  set scrollPosition(ScrollPosition? value) {
    if (value == _scrollPosition) return;
    _scrollPosition?.removeListener(_onScroll);
    _scrollPosition = value;
    _scrollPosition?.addListener(_onScroll);
    markNeedsPaint();
  }

  void _onScroll() => markNeedsPaint();

  // Device pixel ratio for proper scaling on high-DPI displays
  double _devicePixelRatio;
  set devicePixelRatio(double v) {
    if (_devicePixelRatio == v) return;
    _devicePixelRatio = v;
    markNeedsPaint(); // Trigger repaint when DPI changes
  }

  // Framebuffer size in logical px; written to the shader's u_size uniform (in px).
  Size _screenSize;
  set screenSize(Size v) {
    if (_screenSize == v) return;
    _screenSize = v;
    markNeedsPaint();
  }

  // Visual settings for the shader effect
  OCLiquidGlassSettings _settings;
  set settings(OCLiquidGlassSettings v) {
    // 值相同直接返回：settings 由 glassSettingsFor 按「值」缓存，配置没变时
    // 传进来的就是同一个实例；但父级任何 rebuild 都会走到这里，无条件
    // markNeedsPaint 会让每张玻璃卡片在无关 notify（转码进度/日志/任务状态）
    // 时重绘一次 backdrop 滤镜。
    if (_settings == v) return;
    _settings = v;
    markNeedsPaint(); // Trigger repaint when settings change
  }

  final FragmentShader _shader; // The compiled shader program
  final Set<RenderLiquidGlass> registeredShapes =
      {}; // All glass shapes in the widget tree

  // Called by the widget whenever the route hierarchy may have changed
  void setRouteAnimations(Listenable? routeAnimations) {
    // Remove listener from old merged animations
    _routeAnimations?.removeListener(markNeedsPaint);

    // Set new merged listenable
    _routeAnimations = routeAnimations;

    // Add listener to new merged animations
    _routeAnimations?.addListener(markNeedsPaint);
  }

  // Clean-up when the render object leaves the tree
  void detachRepaintSources() {
    _routeAnimations?.removeListener(markNeedsPaint);
    _routeAnimations = null;
    _scrollPosition?.removeListener(_onScroll);
    _externalRepaint?.removeListener(markNeedsPaint);
  }

  // ── 全局变换监视（回调始终挂着，只在可能有变换源时比较） ──
  //
  // 背景：本渲染对象在 paint() 时把玻璃形状的场景坐标（getTransformTo(null)）
  // 烘焙进 shader uniform。但「祖先 TransformLayer 变化」（PageView 横向翻页、
  // 过场动画、预测式返回手势等）只会改合成层的变换，不会触发本对象 repaint，
  // 于是 shader 仍按旧坐标计算 SDF 遮罩 → 玻璃光影层与内容层错位（分层），
  // 偏移稍大时当前像素全部落在旧遮罩外 → 玻璃整块「消失」。
  // 现有缓解（路由动画监听 + 最近 Scrollable 监听）覆盖不了所有路径：
  // PageView 翻页对「最近 Scrollable 是页面内 ListView」的玻璃卡片不可见，
  // 各种非滚动的变换动画也都没有通知。
  //
  // 性能与「不漏检」的取舍（重要）：
  // * 帧后回调必须**始终存在一个待执行实例**：addPostFrameCallback 自身不会调度
  //   新帧（空闲时零开销，见 scheduler/binding.dart），但只要回调在，任何一帧
  //   结束时都会执行检查 —— 于是「动画第一帧」也能被看到。反之，若静止时把回调
  //   摘掉、等发现 Ticker 再挂，PageView 翻页的第一帧就会漏检：那一帧变换已经变了
  //   而本对象没有重绘，之后整段翻页动画玻璃都按旧坐标画遮罩（错位/整块消失），
  //   正是这个监视器要防的故障。
  // * 真正的省力点在比较之前（每帧最多两次字段读取）：
  //     ① 本帧已在 paint() 里用最新变换重绘过（_paintedSinceWatch）→ uniform 已同步，
  //        直接跳过比较。滚动玻璃卡片时每帧都会 repaint，这条命中率最高；
  //     ② 既没有 Ticker（transientCallbackCount == 0）也没有排队的下一帧
  //        （!hasScheduledFrame）→ 变换不可能变化，跳过 getTransformTo(null) 这条
  //        要沿祖先链构造 Matrix4 的贵路径。
  Matrix4? _lastGlobalTransform;
  bool _transformWatchScheduled = false;

  /// 本帧是否已在 paint() 里用最新变换重绘（用于跳过冗余的变换比较）。
  bool _paintedSinceWatch = false;

  /// 挂上「帧后比较全局变换」的一次性回调（已挂或已 detach 则忽略）。
  /// addPostFrameCallback 自身不会调度新帧，因此这里不会造成空转。
  void _scheduleTransformWatch() {
    if (_transformWatchScheduled || !attached) return;
    _transformWatchScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback(_onTransformWatch);
  }

  void _onTransformWatch(Duration _) {
    _transformWatchScheduled = false;
    if (!attached) return; // detach 后自然停止（pending 回调只空跑这一帧）
    final paintedWithFreshTransform = _paintedSinceWatch;
    _paintedSinceWatch = false;
    if (!paintedWithFreshTransform) {
      final binding = SchedulerBinding.instance;
      if (binding.transientCallbackCount > 0 || binding.hasScheduledFrame) {
        try {
          final t = getTransformTo(null);
          final last = _lastGlobalTransform;
          if (last == null || !MatrixUtils.matrixEquals(last, t)) {
            _lastGlobalTransform = t;
            // 变换变了却没人重绘：立刻用新坐标重绘（下一帧生效，一拍延迟不可感知）
            markNeedsPaint();
          }
        } catch (_) {
          // 树处于瞬态（如刚被移出）时忽略本帧
        }
      }
    }
    _scheduleTransformWatch();
  }

  @override
  void markNeedsPaint() {
    super.markNeedsPaint();
    // 任何重绘请求都可能是「变换源苏醒」的信号（滚动、路由动画、窗口尺寸变化、
    // externalRepaint…），顺手确保监视回调在挂；静止时它只是躺在队列里不做事。
    // 注意必须调 super：否则本对象不会真的进入重绘队列。
    _scheduleTransformWatch();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _lastGlobalTransform = null;
    _paintedSinceWatch = false;
    _scheduleTransformWatch();
    markNeedsPaint();
  }

  @override
  void detach() {
    _lastGlobalTransform = null;
    detachRepaintSources();
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    // STEP 1: Collect geometry data from all registered glass shapes
    final shapes = <ShapeData>[];
    for (var shape in registeredShapes) {
      // Skip shapes that aren't properly attached or have no size
      if (!shape.attached || shape.size.isEmpty) continue;

      // Transform shape coordinates to scene space.
      final transform = shape.getTransformTo(null);
      final rect = MatrixUtils.transformRect(
        transform,
        Offset.zero & shape.size,
      );

      // Clamp border radius to maximum of half the smaller dimension
      final maxRadius = (rect.size.width < rect.size.height
              ? rect.size.width
              : rect.size.height) /
          2;
      final clampedRadius =
          shape.borderRadius > maxRadius ? maxRadius : shape.borderRadius;

      shapes.add(
        ShapeData(
          rect.center,
          rect.size,
          clampedRadius,
          shape.color,
        ),
      );
    }

    // If no shapes are registered, skip rendering
    if (!ImageFilter.isShaderFilterSupported || shapes.isEmpty) {
      super.paint(context, offset);
      return;
    }

    // Calculate boundary of current render object in scene space.
    // 坐标空间耦合（重要）：shader 的 fragPx 是「绑定纹理像素空间」的坐标，
    // 而这里写入的 boundary / 形状中心是**场景物理像素**（logical * dpr）；
    // 二者一致的充分条件是「绑定纹理 = 整帧 且 pass 的 snapshot 变换恒等」。
    // 移动端满足（故可用）；桌面端（窗口缩放 / 子 pass 变换 / 后端 y 取向差异）
    // 不保证，这正是 PC 默认关闭 shader 路径、改走 LiquidGlassBackdrop 的原因。
    final boundaryTransform = getTransformTo(null);
    // 记录本帧使用的变换：帧后监视器据此跳过冗余比较（本帧 uniform 已是最新）。
    _lastGlobalTransform = boundaryTransform;
    _paintedSinceWatch = true;
    final boundary = MatrixUtils.transformRect(
      boundaryTransform,
      Offset.zero & size,
    );

    // STEP 2: Configure shader uniforms (parameters passed to GPU)
    // final biggestSize = constraints.biggest;
    // final w = biggestSize.width * _devicePixelRatio;   // Screen width in physical pixels
    // final h = biggestSize.height * _devicePixelRatio;  // Screen height in physical pixels
    final sh = _shader;

    var idx = 2;

    // Global shader parameters
    //
    // u_size（uniform 0/1）的真实语义：dart:ui 规定 ImageFilter.shader 的
    // **第一个 vec2 uniform 由引擎写入「绑定纹理的像素尺寸」**，第一个
    // sampler2D 为滤镜输入（见 ImageFilter.shader 官方文档）。Impeller 实现：
    //   // impeller/entity/contents/filters/runtime_effect_filter_contents.cc
    //   Size size = Size(input_snapshot->texture->GetSize());
    //   memcpy(uniforms_->data(), &size, sizeof(Size));   // ← 覆盖 uniform 0/1
    // 也就是说下面两行写入的值会被引擎覆盖，真正生效的是绑定纹理尺寸
    // （正常情况下 = 整帧 framebuffer 的物理尺寸，与本处取值一致）。
    // 仍然保留显式写入：① 语义自解释；② 万一后端不覆盖，也不会退化成
    // R=(0,0) 让 uv0/hsz/posN 全除 0 → NaN（历史上正是这个 bug 让折射整体失效）。
    //
    // 由此得出的空间约定：shader 里的 FlutterFragCoord() 处于该纹理的像素
    // 空间，本文件写入的形状/边界 uniform 用的是**场景物理像素**，二者只有在
    // 「绑定纹理 = 整帧 且 当前 pass 的 snapshot 变换为恒等」时才一致 ——
    // 移动端成立（所以移动端可用）；桌面端不保证，故 PC 默认走模糊回退
    // （见 liquid_glass_fallback.gpuGlassEnabled）。
    sh
      ..setFloat(0, _screenSize.width * _devicePixelRatio) // u_size.x（引擎会覆盖为纹理宽 px）
      ..setFloat(1, _screenSize.height * _devicePixelRatio) // u_size.y（引擎会覆盖为纹理高 px）

      // boundary
      ..setFloat(
          idx++, boundary.left * _devicePixelRatio) // Min X in physical pixels
      ..setFloat(
          idx++, boundary.top * _devicePixelRatio) // Min Y in physical pixels
      ..setFloat(
          idx++, boundary.right * _devicePixelRatio) // Max X in physical pixels
      ..setFloat(idx++,
          boundary.bottom * _devicePixelRatio) // Max Y in physical pixels

      // Blend & refraction parameters
      ..setFloat(idx++, _settings.blendPx * _devicePixelRatio) // Edge blending
      ..setFloat(idx++, _settings.refractStrength) // Refraction strength
      ..setFloat(idx++,
          _settings.distortFalloffPx * _devicePixelRatio) // Distortion falloff
      ..setFloat(idx++, _settings.distortExponent) // Distortion curve

      // Frosted glass blur parameters
      ..setFloat(idx++, _settings.blurRadiusPx * _devicePixelRatio) // Base blur

      // Specular highlight parameters (shiny reflections)
      ..setFloat(idx++, _settings.specAngle) // specular light angle
      ..setFloat(idx++, _settings.specStrength) // specular strength
      ..setFloat(idx++, _settings.specPower) // specular power
      ..setFloat(
          idx++, _settings.specWidth * _devicePixelRatio) // specular width

      // Light band parameters (bright streak across glass surface)
      ..setFloat(idx++,
          _settings.lightbandOffsetPx * _devicePixelRatio) // Distance from edge
      ..setFloat(
          idx++, _settings.lightbandWidthPx * _devicePixelRatio) // Band width
      ..setFloat(idx++, _settings.lightbandStrength) // Band intensity
      ..setFloat(idx++, _settings.lightbandColor.r) // Band red
      ..setFloat(idx++, _settings.lightbandColor.g) // Band green
      ..setFloat(idx++, _settings.lightbandColor.b) // Band blue

      // Anti-aliasing and shape count
      ..setFloat(idx++, 1.0 * _devicePixelRatio) // 1px anti-aliasing
      ..setFloat(
        idx++,
        shapes.length > maxRects
            ? maxRects.toDouble()
            : shapes.length.toDouble(),
      ); // Number of shapes

    // STEP 3: Pass individual shape data to shader (max 4 shapes supported)
    for (var i = 0; i < shapes.length && i < maxRects; i++) {
      final s = shapes[i];
      sh
            ..setFloat(idx++, s.center.dx * _devicePixelRatio) // Center X
            ..setFloat(idx++, s.center.dy * _devicePixelRatio) // Center Y
            ..setFloat(idx++, s.size.width * _devicePixelRatio) // Width
            ..setFloat(idx++, s.size.height * _devicePixelRatio) // Height
            ..setFloat(
                idx++, s.borderRadius * _devicePixelRatio) // Borner radius
            ..setFloat(idx++, s.color.r) // Color red
            ..setFloat(idx++, s.color.g) // Color green
            ..setFloat(idx++, s.color.b) // Color blue
            ..setFloat(idx++, s.color.a) // Color alpha
          ;
    }

    // STEP 4：把 shader 作为 backdrop 滤镜压入图层，子内容仍由 super.paint 绘制。
    // 这样透明度/淡入淡出动画与背景滤镜保持同步。
    //
    // 说明（原注释称「若日后为性能裁剪，需要按折射采样半径外扩 clip，否则强折射
    // 时边缘像素会被 clamp」）：当前配置下 uRefractStrength 恒为负值（凹透镜，
    // 采样点指向形状内侧），不会采到形状之外，因此**不需要**外扩 clip；
    // 这里保留的是唯一正确的画法（曾经尝试过的 ClipRRect 方案会先把 backdrop
    // 裁到形状范围，反而破坏 shader 对场景坐标的假设，已删除以免误用）。
    context.pushLayer(
      BackdropFilterLayer(filter: ImageFilter.shader(sh)),
      super.paint,
      offset,
    );
  }
}

/// Widget that wraps any child to make it appear as a liquid glass droplet.
///
/// This is the user-facing widget - simply wrap any widget with LiquidGlass
/// and it will get the glass effect applied to it. The widget must be inside
/// a LiquidGlassGroup to work properly.
///
/// The borderRadius parameter controls how rounded the glass shape appears.
/// Note: The radius is automatically clamped to half of the smaller dimension
/// (min(width/2, height/2)) to ensure valid geometry.
/// The enabled parameter allows you to turn the glass effect on/off.
class OCLiquidGlass extends SingleChildRenderObjectWidget {
  final bool enabled;

  final double? width;
  final double? height;

  final Color color;
  final double borderRadius;
  final BoxShadow? shadow;

  const OCLiquidGlass(
      {super.key,
      this.enabled = true,
      this.width,
      this.height,
      this.color = Colors.transparent,
      this.borderRadius = 0.0,
      this.shadow,
      super.child});

  @override
  createRenderObject(BuildContext context) =>
      RenderLiquidGlass(enabled, borderRadius, color);

  @override
  void updateRenderObject(
      BuildContext context, RenderLiquidGlass renderObject) {
    renderObject
      ..enabled = enabled
      ..color = color
      ..borderRadius = borderRadius;
  }

  @override
  Widget? get child {
    // Adjust the shadow offset if the background is translucent.
    final shadow = this.shadow != null
        ? this.shadow?.copyWith(
              blurStyle: BlurStyle.outer,
              offset: const Offset(0, 0),
            )
        : this.shadow;

    return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: shadow != null ? [shadow] : null,
        ),
        child: super.child);
  }
}

/// The render object for individual glass shapes.
///
/// This render object:
/// 1. Automatically registers itself with the parent LiquidGlassLayer when attached
/// 2. Provides its geometry (size, position, border radius) to the shader system
/// 3. Unregisters itself when removed from the widget tree
/// 4. Can be enabled/disabled to control whether the glass effect is applied
///
/// It acts as a proxy box, meaning it doesn't change the layout of its child.
class RenderLiquidGlass extends RenderProxyBox {
  bool _enabled;
  double _borderRadius;
  Color _color;

  RenderLiquidGlass(this._enabled, this._borderRadius, this._color);

  /// Whether the glass effect is enabled for this shape
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;

    // Update registration based on enabled state
    final layer = _findLayer();
    if (layer != null) {
      if (_enabled) {
        layer.registeredShapes.add(this);
      } else {
        layer.registeredShapes.remove(this);
      }
      layer.markNeedsPaint(); // Trigger repaint when state changes
    }
  }

  double get borderRadius => _borderRadius;
  set borderRadius(double value) {
    if (_borderRadius == value) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  Color get color => _color;
  set color(Color value) {
    if (_color == value) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    // Register this shape with the parent glass layer only if enabled
    if (_enabled) {
      _findLayer()?.registeredShapes.add(this);
    }
  }

  @override
  void detach() {
    // Unregister this shape when removed from tree
    _findLayer()?.registeredShapes.remove(this);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => _enabled;

  /// Searches up the render tree to find the LiquidGlassLayer that manages the shader.
  /// This allows individual glass shapes to register themselves with the system.
  _RenderLiquidGlassGroup? _findLayer() {
    var pr = parent;
    while (pr != null && pr is! _RenderLiquidGlassGroup) {
      pr = pr.parent; // Walk up the render tree
    }
    return pr as _RenderLiquidGlassGroup?;
  }
}