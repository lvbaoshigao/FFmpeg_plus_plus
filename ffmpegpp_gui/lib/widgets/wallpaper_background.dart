import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app.dart';
import '../providers/app_state.dart';
// effectiveGlassSigma / glassTuningOf：开窗预模糊的 σ 必须与 AppCard 开窗
// painter 用的完全一致，否则玻璃里的清晰度会与「模糊度」设置脱节。
import 'liquid_glass_fallback.dart';

/// 二级页面统一的壁纸背景（与主界面一致）：主题底色 + 壁纸 +
/// 「背景不透明度」控制的遮罩。无壁纸时也铺一层不透明主题底色，
/// 避免移动端 push 出的新路由在返回过渡首帧露出系统窗口黑底。
///
/// 子级 Scaffold 需要透明底色才能透出壁纸，本组件已统一包一层
/// [Theme] 将 scaffoldBackgroundColor（及可选 appBarTheme）置透明。
///
/// 壁纸统一走 wallpaperImageProvider（按物理分辨率等比降采样解码）：
/// 直接 Image.file 会按原图尺寸解码（4K 壁纸 ~33MB），且与主界面
/// 解码的 provider key 不同、缓存无法复用。
///
/// 订阅为细粒度 select（仅 backgroundImage/backgroundOpacity），
/// 转码进度/日志的 notifyListeners 不会触发包壁纸的整页重建。
Widget withWallpaper(
  BuildContext context,
  Widget child, {
  /// 同时把 AppBar 背景置透明（管线编辑器等自带顶栏的页面需要）
  bool transparentAppBar = false,
}) {
  final bg = context.select<AppState, String>((s) => s.config.backgroundImage);
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final children = <Widget>[
    Positioned.fill(child: ColoredBox(color: scheme.surface)),
  ];
  if (bg.isNotEmpty && File(bg).existsSync()) {
    final op = context
        .select<AppState, double>((s) => s.config.backgroundOpacity)
        .clamp(0.0, 1.0);
    final a = ((1.0 - op) * 220).round().clamp(20, 240);
    children.addAll([
      Positioned.fill(child: Image(
        image: wallpaperImageProvider(
            bg,
            MediaQuery.sizeOf(context).width,
            MediaQuery.sizeOf(context).height,
            MediaQuery.devicePixelRatioOf(context)),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      )),
      Positioned.fill(child: ColoredBox(color: scheme.surface.withAlpha(a))),
    ]);
  }
  children.add(Theme(
    data: theme.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: transparentAppBar
          ? theme.appBarTheme.copyWith(backgroundColor: Colors.transparent)
          : null,
    ),
    child: child,
  ));
  // 壁纸窗口作用域：把当前壁纸解析为 ui.Image 下发给页内玻璃卡，
  // 供「滚动中的玻璃卡开窗」绑定渲染（见 WallpaperWindowScope 注释）。
  // 无壁纸（纯色/底色）时 provider 为 null，玻璃卡走原 BackdropFilter 路径
  // —— 纯色背景的模糊采样恒定，本就不存在图层分离。
  final provider = (bg.isNotEmpty && File(bg).existsSync())
      ? wallpaperImageProvider(bg, MediaQuery.sizeOf(context).width,
          MediaQuery.sizeOf(context).height, MediaQuery.devicePixelRatioOf(context))
      : null;
  return WallpaperWindowScope(
    provider: provider,
    screenSize: MediaQuery.sizeOf(context),
    overlayColor: scheme.surface.withAlpha(
        ((1.0 - context.select<AppState, double>((s) => s.config.backgroundOpacity))
                    .clamp(0.0, 1.0) *
                220)
            .round()
            .clamp(20, 240)),
    child: Stack(children: children),
  );
}

/// 开窗用的静态壁纸源：玻璃卡 paint 时直接把这份数据按当前帧变换
/// 画进卡片（见 app_card 的 _WallpaperWindowPainter），不再实时采样
/// 合成场景 —— 卡片与背景同帧同变换光栅化，滚动中零滞后、零分离。
class WallpaperWindow {
  /// 已解码的壁纸（与页面显示的 Image 共用 ImageCache，不额外占内存）。
  final ui.Image image;

  /// **预先模糊好的整屏壁纸**（可能为 null）。
  ///
  /// 为什么要有它：开窗 painter 原本在**每次 paint** 时对壁纸跑一次
  /// `ImageFilter.blur`（每帧 × 每张可见玻璃卡各一次，且 dst 是整屏 cover
  /// 矩形，画完才被 ClipRRect 裁到卡片大）。高斯模糊要在目标之外多分配约
  /// 3σ 的离屏纹理，σ 越大越可观；这些大纹理会被 Skia 的 GPU 资源池长期
  /// 缓存，于是「开着玻璃时进程常驻内存几百 MB」。现在改为：按「屏幕设备
  /// 像素 + 当前 σ」离屏渲染**一次**，所有玻璃卡共享同一张已模糊图，
  /// painter 退化成一次普通 drawImageRect，不再触发任何模糊。
  ///
  /// 尺寸 = 屏幕逻辑尺寸 × DPR；σ 已按 DPR 换算到设备像素空间。
  /// 为 null（尚未生成 / 生成失败 / 无壁纸）时 painter 回退实时模糊老路径。
  final ui.Image? blurred;

  /// 屏幕逻辑尺寸（壁纸 cover 铺满的目标矩形）。
  final Size screen;

  /// 壁纸之上的遮罩色（「背景不透明度」，withWallpaper 里叠在图片上的那层）。
  /// 卡片开窗必须复现它，否则玻璃里的壁纸比背景原亮度不一致。
  final Color overlayColor;

  const WallpaperWindow({
    required this.image,
    required this.screen,
    required this.overlayColor,
    this.blurred,
  });
}

/// 进程级共享的「整屏预模糊壁纸」缓存（见 [WallpaperWindow.blurred]）。
///
/// 为什么必须共享而不是每个 scope 各自生成：主壳、每个二级页路由、移动端
/// 每个 Tab 都各有一个 [WallpaperWindowScope]，参数（原图 / 屏幕 / DPR / σ）
/// 在同一时刻完全相同。若各自生成一张，移动端访问过 4 个 Tab 就是 4 张全屏
/// 设备像素图（4 × ~10MB ≈ 40MB）—— 比它省下的还多。这里做成单例：全进程
/// 任何时刻最多一张，参数变化时后台重建并替换。
///
/// 生命周期：静态持有，随进程存活（最多一张全屏图，桌面约 4MB / 移动端约
/// 10MB，与 ImageCache 里那张壁纸同量级）。换壁纸 / 改分辨率 / 改模糊度都会
/// 自动替换并释放旧图。
class WallpaperBlurCache {
  WallpaperBlurCache._();

  /// 当前可用的预模糊图；null = 尚无（玻璃卡走实时模糊回退）。
  static final ValueNotifier<ui.Image?> image = ValueNotifier<ui.Image?>(null);

  static ui.Image? _src;
  static Size _screen = Size.zero;
  static double _dpr = -1;
  static double _sigma = -1;
  /// 自增令牌：作废在途的离屏渲染结果，避免旧任务覆盖新图。
  static int _token = 0;
  static Timer? _debounce;
  /// 已排队的参数指纹。**防抖计时器只在参数真的变化时重置**：滚动 / 动画时
  /// 玻璃卡每帧都会走 build 并调用 [request]，若无条件 `cancel + 新建`，
  /// 计时器会被无限推迟、重建永不发生，预模糊优化等于没做（painter 会一直
  /// 走每帧实时模糊的回退路径）。
  static int? _scheduledKey;
  /// 已失败的参数指纹：同一参数不再反复排队重试（如显存不足导致的持续失败），
  /// 换壁纸 / 改分辨率 / 改模糊度会得到新指纹，届时自然重试。
  static int? _failedKey;

  static int _keyOf(ui.Image src, Size screen, double dpr, double sigma) =>
      Object.hash(identityHashCode(src), screen, dpr, sigma);

  /// 当前图是否适配这张原图与屏幕（几何匹配 —— 原图或屏幕尺寸变了就不能用，
  /// 否则卡内壁纸的位置/比例会与卡外背景对不上）。σ 允许略旧（见 [request]）。
  static ui.Image? currentFor(ui.Image src, Size screen) {
    final cur = image.value;
    if (cur == null) return null;
    if (!identical(_src, src) || _screen != screen) return null;
    return cur;
  }

  /// 请求一张适配当前参数的预模糊图，并按需（防抖 120ms）调度离屏重建。
  ///
  /// 返回值语义：
  ///  - 几何匹配且 σ 一致 → 当前图；
  ///  - 几何匹配但 σ 已变（拖「模糊度」滑块）→ 仍返回**旧 σ 的图**（视觉上
  ///    模糊度晚 120ms 跟上，好过回退到每帧实时模糊的昂贵路径）；
  ///  - 几何不匹配（换壁纸 / 窗口缩放）→ null，调用方先走实时模糊回退。
  static ui.Image? request({
    required ui.Image src,
    required Size screen,
    required double dpr,
    required double sigma,
  }) {
    final geoOk = currentFor(src, screen);
    if (geoOk != null && _dpr == dpr && _sigma == sigma) return geoOk;
    final key = _keyOf(src, screen, dpr, sigma);
    if (key == _failedKey) return geoOk; // 同参数已失败过，不再重试
    if (key == _scheduledKey) return geoOk; // 已排队：不要重置计时器
    _scheduledKey = key;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      _debounce = null;
      final k = _scheduledKey!;
      _scheduledKey = null;
      unawaited(_rebuild(src, screen, dpr, sigma, k));
    });
    return geoOk;
  }

  /// 离屏渲染「按 cover 铺满整屏 + 高斯模糊」的壁纸（设备像素空间）。
  /// [failKey] 为本次请求的参数指纹，失败时记入 [_failedKey] 以免反复重试。
  static Future<void> _rebuild(
      ui.Image src, Size screen, double dpr, double sigma, int failKey) async {
    final token = ++_token;
    final int pw = (screen.width * dpr).round().clamp(1, 8192);
    final int ph = (screen.height * dpr).round().clamp(1, 8192);
    // 模糊在图像边界外取透明（kDecal）并【向内】衰减：若直接渲染一张 pw×ph
    // 的图，屏幕最边缘（贴边的玻璃卡）会明显偏透、露出主题底色。原实现没有
    // 这个问题 —— 它模糊的是整张壁纸、dst 是可能比屏幕更大的 cover，屏幕边缘
    // 落在壁纸内部。这里用「外扩 3σ 画布 → 裁出中间 pw×ph」还原该行为：衰减
    // 落在被裁掉的 padding 上，最终交付给 painter 的仍是屏幕尺寸的图，因此
    // 不额外常驻内存（padding 那两张只是重建瞬间的临时对象）。
    final double sigmaDev = sigma * dpr;
    final int pad = (3 * sigmaDev).ceil().clamp(0, 512);
    ui.Image? next;
    try {
      final iw = src.width.toDouble();
      final ih = src.height.toDouble();
      // 与 BoxFit.cover 一致：等比铺满整屏、居中裁切。与原 painter 的 cover
      // 计算等价，保证卡内壁纸与卡外背景逐像素对齐。
      final scale = math.max(pw / iw, ph / ih);
      final dw = iw * scale;
      final dh = ih * scale;
      final paint = Paint()
        // 预渲染画布已是设备像素，σ 需乘 DPR（painter 里的 σ 是逻辑单位）
        ..imageFilter =
            ui.ImageFilter.blur(sigmaX: sigmaDev, sigmaY: sigmaDev)
        ..filterQuality = FilterQuality.medium;

      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(
        src,
        Rect.fromLTWH(0, 0, iw, ih),
        Rect.fromLTWH(
            pad + (pw - dw) / 2, pad + (ph - dh) / 2, dw, dh),
        paint,
      );
      final pic = rec.endRecording();
      final padded = await pic.toImage(pw + 2 * pad, ph + 2 * pad);
      pic.dispose();

      if (pad == 0) {
        next = padded;
      } else {
        // 裁出 padding 内的屏幕区域作为最终图
        final rec2 = ui.PictureRecorder();
        Canvas(rec2).drawImageRect(
          padded,
          Rect.fromLTWH(
              pad.toDouble(), pad.toDouble(), pw.toDouble(), ph.toDouble()),
          Rect.fromLTWH(0, 0, pw.toDouble(), ph.toDouble()),
          Paint()..filterQuality = FilterQuality.high,
        );
        final pic2 = rec2.endRecording();
        next = await pic2.toImage(pw, ph);
        pic2.dispose();
        padded.dispose();
      }
    } catch (_) {
      next = null;
    }
    // 已被更新的任务取代 → 丢弃本次结果
    if (token != _token) {
      next?.dispose();
      return;
    }
    if (next == null) {
      // 生成失败（如显存不足）：保留旧图，painter 仍可回退实时模糊；
      // 记下参数指纹，避免每次 build 都重新排队重试。
      _failedKey = failKey;
      return;
    }
    final old = image.value;
    _src = src;
    _screen = screen;
    _dpr = dpr;
    _sigma = sigma;
    image.value = next; // 通知所有 scope 重新发布给页内玻璃卡
    if (old != null) {
      // 本帧的绘制可能仍在用旧图，推迟到帧末再释放，避免 use-after-dispose
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }
}

/// 壁纸窗口作用域：把当前壁纸解析为 [ui.Image]（异步，加载完成前
/// [window] 为 null，玻璃卡自动走原 BackdropFilter 回退），并通过
/// InheritedWidget 下发给页内所有玻璃卡。
///
/// 解析走 ImageProvider.resolve + ImageStreamListener，与页面显示的
/// Image 共用同一份 ImageCache 条目 —— 不会二次解码、不额外占内存。
///
/// 预模糊图不在这里各自生成，而取自进程级共享的 [WallpaperBlurCache]
/// （原因见其注释：每个 scope 一张会随 Tab / 路由数量线性增长）。
class WallpaperWindowScope extends StatefulWidget {
  final ImageProvider? provider;
  final Size screenSize;
  final Color overlayColor;
  final Widget child;

  const WallpaperWindowScope({
    super.key,
    required this.provider,
    required this.screenSize,
    required this.overlayColor,
    required this.child,
  });

  /// 页内的壁纸窗口 notifier（null = 不在壁纸作用域内）。
  static ValueNotifier<WallpaperWindow?>? maybeOf(BuildContext context) {
    final inherited = context
        .dependOnInheritedWidgetOfExactType<_WallpaperWindowInherited>();
    return inherited?.window;
  }

  @override
  State<WallpaperWindowScope> createState() => _WallpaperWindowScopeState();
}

class _WallpaperWindowScopeState extends State<WallpaperWindowScope> {
  final ValueNotifier<WallpaperWindow?> _window = ValueNotifier(null);
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageProvider? _resolvedFor;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WallpaperBlurCache.image.addListener(_onBlurredChanged);
    _resolve();
  }

  /// 共享缓存的预模糊图更新（首次生成完成 / σ 或尺寸变化重建完成）→
  /// 重新发布给页内玻璃卡。由缓存变更触发，不在 build 期间，可安全改 notifier。
  void _onBlurredChanged() {
    if (_disposed) return;
    _publish();
  }

  @override
  void didUpdateWidget(WallpaperWindowScope old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      _resolve();
      return;
    }
    // provider 未变、但 screenSize / overlayColor 变了（窗口缩放、切明暗主题、
    // 拖「背景不透明度」滑块）时，必须用新值重建当前窗口：
    // 否则卡内壁纸的铺屏矩形与遮罩 alpha 会停留在旧值，玻璃里的亮度/位置
    // 与卡外背景对不上（此前只在换壁纸时才会恢复）。
    // image / blurred 沿用已有 ui.Image，不触发重新解码。
    final cur = _window.value;
    if (cur != null &&
        (cur.screen != widget.screenSize ||
            cur.overlayColor != widget.overlayColor)) {
      _window.value = WallpaperWindow(
        image: cur.image,
        blurred: cur.blurred,
        screen: widget.screenSize,
        overlayColor: widget.overlayColor,
      );
    }
  }

  void _resolve() {
    final p = widget.provider;
    if (p == null) {
      _unsubscribe();
      _window.value = null;
      return;
    }
    if (identical(p, _resolvedFor)) return;
    _unsubscribe();
    _resolvedFor = p;
    _window.value = null; // 旧壁纸窗口立即失效，等新图解码
    final listener = ImageStreamListener(
      (info, _) {
        if (_disposed) return;
        _window.value = WallpaperWindow(
          image: info.image,
          blurred: WallpaperBlurCache.currentFor(info.image, widget.screenSize),
          screen: widget.screenSize,
          overlayColor: widget.overlayColor,
        );
        // 壁纸解码完成后必须让本 State 再 build 一次，好让 _requestBlur() 在
        // 「已有原图」的前提下向共享缓存请求预模糊图。
        // 为什么非显式触发不可：给 _window 赋值只会重建 AppCard 里的
        // ValueListenableBuilder，**不会**重建 scope 自身；而首次 build 时
        // _window.value 仍为 null（原图未就绪）、_requestBlur 直接 return ——
        // 结果就是预模糊图永远不会被请求，优化等于没做。
        // 不能在这里直接调 _requestBlur：它需要 MediaQuery 与「玻璃细节」，
        // 而 context.select 只能在 build / didChangeDependencies 阶段使用。
        if (mounted) setState(() {});
      },
      // 解码失败（文件被删/损坏）时清空窗口，玻璃卡回退到
      // BackdropFilter 路径；不传 onError 会把异常抛到全局错误处理。
      onError: (_, _) {
        if (!_disposed) _window.value = null;
      },
    );
    _listener = listener;
    _stream = p.resolve(ImageConfiguration.empty);
    _stream!.addListener(listener);
  }

  void _unsubscribe() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _stream = null;
    _listener = null;
    _resolvedFor = null;
  }

  /// 把共享缓存里当前可用的预模糊图重新发布给页内玻璃卡（其余字段沿用）。
  void _publish() {
    final cur = _window.value;
    if (cur == null) return;
    final img = WallpaperBlurCache.currentFor(cur.image, widget.screenSize);
    if (identical(img, cur.blurred)) return; // 无变化，避免无谓重建
    _window.value = WallpaperWindow(
      image: cur.image,
      blurred: img,
      screen: widget.screenSize,
      overlayColor: widget.overlayColor,
    );
  }

  /// 按当前参数向共享缓存请求预模糊图（几何匹配才拿得到，σ 允许略旧），
  /// 并顺带调度重建。在 build 中调用，因此也顺带注册了对「玻璃细节」与
  /// MediaQuery 的依赖 —— σ / DPR / 屏幕变化时会重新走一遍。
  ///
  /// σ 必须与 AppCard 开窗 painter 用的完全一致：
  /// `effectiveGlassSigma(glassTuningOf(context).blur)`（见 app_card.dart）。
  void _requestBlur() {
    final src = _window.value?.image;
    if (src == null) return;
    WallpaperBlurCache.request(
      src: src,
      screen: widget.screenSize,
      dpr: MediaQuery.devicePixelRatioOf(context),
      sigma: effectiveGlassSigma(glassTuningOf(context).blur),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    WallpaperBlurCache.image.removeListener(_onBlurredChanged);
    _unsubscribe();
    _window.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _requestBlur();
    return _WallpaperWindowInherited(window: _window, child: widget.child);
  }
}

class _WallpaperWindowInherited extends InheritedWidget {
  final ValueNotifier<WallpaperWindow?> window;
  const _WallpaperWindowInherited({required this.window, required super.child});

  @override
  bool updateShouldNotify(_WallpaperWindowInherited old) => window != old.window;
}
