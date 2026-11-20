import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app.dart';
import '../providers/app_state.dart';
import '../services/image_memory_budget.dart';
import '../theme/app_neutral_surface.dart';
import 'desktop_resize_scope.dart';
// effectiveGlassSigma / glassTuningOf：开窗预模糊的 σ 必须与 AppCard 开窗
// painter 用的完全一致，否则玻璃里的清晰度会与「模糊度」设置脱节。
import 'liquid_glass_fallback.dart';

/// Gives an application route the shared opaque backdrop and optional wallpaper.
Widget withWallpaper(
  BuildContext _,
  Widget child, {
  bool transparentAppBar = false,
}) => WallpaperBackground(transparentAppBar: transparentAppBar, child: child);

/// Renders the same wallpaper and tint behind the main window and its routes.
final class WallpaperBackground extends StatelessWidget {
  /// Displays [child] over the configured wallpaper.
  const WallpaperBackground({
    super.key,
    this.transparentAppBar = false,
    required this.child,
  });

  /// Whether route app bars should let the wallpaper show through.
  final bool transparentAppBar;

  /// The content on top of the wallpaper.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final (path, opacity) = context.select<AppState, (String, double)>(
      (state) => (state.config.backgroundImage, state.config.backgroundOpacity),
    );
    final theme = Theme.of(context);
    final base = AppNeutralSurface.background(theme.brightness);
    final alpha = ((1.0 - opacity.clamp(0.0, 1.0)) * 220).round().clamp(
      20,
      240,
    );
    return _WallpaperViewport(
      path: path,
      background: base,
      overlay: base.withAlpha(alpha),
      child: Theme(
        data: theme.copyWith(
          scaffoldBackgroundColor: Colors.transparent,
          appBarTheme: transparentAppBar
              ? theme.appBarTheme.copyWith(backgroundColor: Colors.transparent)
              : null,
        ),
        child: child,
      ),
    );
  }
}

class _WallpaperViewport extends StatefulWidget {
  const _WallpaperViewport({
    required this.path,
    required this.background,
    required this.overlay,
    required this.child,
  });

  final String path;
  final Color background;
  final Color overlay;
  final Widget child;

  @override
  State<_WallpaperViewport> createState() => _WallpaperViewportState();
}

class _WallpaperViewportState extends State<_WallpaperViewport> {
  ({String path, Size size, double dpr})? _decodeTarget;
  ImageProvider<Object>? _provider;
  late bool _pathExists = _fileExists(widget.path);

  static bool _fileExists(String path) =>
      path.isNotEmpty && File(path).existsSync();

  @override
  void didUpdateWidget(_WallpaperViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _pathExists = _fileExists(widget.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    final screen = MediaQuery.sizeOf(context);
    final hasWallpaper = path.isNotEmpty && _pathExists;
    final resizing = DesktopResizeScope.isResizingOf(context);
    if (!hasWallpaper) {
      _provider = null;
      _decodeTarget = null;
    } else if (!resizing || path != _decodeTarget?.path) {
      final size = screen;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final target = (path: path, size: size, dpr: dpr);
      if (!size.isEmpty && target != _decodeTarget) {
        _provider = wallpaperImageProvider(path, size.width, size.height, dpr);
        _decodeTarget = target;
      } else if (size.isEmpty && path != _decodeTarget?.path) {
        _provider = null;
        _decodeTarget = null;
      }
    }

    // BoxFit.cover scales the displayed image immediately. Both the image and
    // the window cache keep the same decode target until the viewport settles.
    final provider = _provider;
    return WallpaperWindowScope(
      provider: provider,
      screenSize: screen,
      overlayColor: widget.overlay,
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: widget.background)),
          if (provider != null) ...[
            Positioned.fill(
              child: Image(
                key: ValueKey(path),
                image: provider,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
            Positioned.fill(child: ColoredBox(color: widget.overlay)),
          ],
          KeyedSubtree(
            key: const ValueKey('wallpaper-content'),
            child: widget.child,
          ),
        ],
      ),
    );
  }
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
  /// Its viewport crop and Gaussian-expanded intermediate each fit a 2 MiB
  /// raster budget, even at 4K/high DPR. Sigma scales with the reduced raster.
  /// The painter maps this bounded image back to the same screen rectangle.
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

/// One process-wide preblur, rebuilt serially within [ImageMemoryBudget].
/// Source clones are handles to shared pixels; only the latest pending request
/// survives while one raster operation is in flight.
class WallpaperBlurCache {
  WallpaperBlurCache._();

  static final ValueNotifier<ui.Image?> image = ValueNotifier<ui.Image?>(null);
  static const int kBlurRebuildRetryCooldownMs = 3000;

  /// An allocation boundary for deterministic concurrency/lifecycle tests.
  @visibleForTesting
  static Future<ui.Image> Function(ui.Picture picture, int width, int height)?
  rasterizeForTesting;

  static ui.Image? _src;
  static Size _screen = Size.zero;
  static double _dpr = -1;
  static double _sigma = -1;
  static int _token = 0;
  static Timer? _debounce;
  static _BlurRequest? _pending;
  static _BlurRequest? _running;
  static int? _failedKey;
  static int _failedAtMs = 0;
  static final _memoryObserver = _WallpaperMemoryObserver();
  static bool _observingMemory = false;

  /// A stale blur is reusable only if the cover geometry remains identical.
  /// Proportional resizing is safe; a changed aspect ratio uses the source until
  /// its newly cropped blur is ready instead of stretching the old crop.
  static ui.Image? currentFor(ui.Image src, Size screen) {
    final current = image.value;
    if (current == null ||
        _src == null ||
        !_src!.isCloneOf(src) ||
        screen.isEmpty ||
        _screen.isEmpty) {
      return null;
    }
    final ratio = _screen.aspectRatio / screen.aspectRatio;
    return (ratio - 1).abs() < 0.000000001 ? current : null;
  }

  static ui.Image? request({
    required ui.Image src,
    required Size screen,
    required double dpr,
    required double sigma,
  }) {
    if (screen.isEmpty || !screen.width.isFinite || !screen.height.isFinite) {
      return null;
    }
    final available = currentFor(src, screen);
    if (available != null &&
        _screen == screen &&
        _dpr == dpr &&
        _sigma == sigma) {
      if (_pending != null || (_running != null && _running!.token == _token)) {
        // Returning to the published target must also cancel a superseded
        // resize/tuning request, otherwise it could replace this valid crop.
        _token++;
        _debounce?.cancel();
        _debounce = null;
        _pending?.source.dispose();
        _pending = null;
      }
      return available;
    }
    if (_pending?.matches(src, screen, dpr, sigma) ?? false) return available;
    if (_pending == null &&
        _running?.token == _token &&
        (_running?.matches(src, screen, dpr, sigma) ?? false)) {
      return available;
    }
    final key = Object.hash(src.width, src.height, screen, dpr, sigma);
    if (key == _failedKey &&
        DateTime.now().millisecondsSinceEpoch - _failedAtMs <
            kBlurRebuildRetryCooldownMs) {
      return available;
    }
    if (!_observingMemory) {
      WidgetsBinding.instance.addObserver(_memoryObserver);
      _observingMemory = true;
    }
    _pending?.source.dispose();
    _pending = _BlurRequest(src.clone(), screen, dpr, sigma, key, ++_token);
    _debounce?.cancel();
    _debounce = null;
    _schedule();
    return available;
  }

  static void _schedule() {
    if (_pending == null || _running != null) return;
    if (_src == null) {
      _startPending();
    } else {
      _debounce = Timer(const Duration(milliseconds: 120), _startPending);
    }
  }

  static void _startPending() {
    _debounce = null;
    if (_pending == null || _running != null) return;
    final request = _pending!;
    _pending = null;
    // A different decode cannot use the old cropped blur. Stop retaining that
    // decoded size before starting the replacement raster (outside build).
    if (_src != null && !_src!.isCloneOf(request.source)) {
      final oldSource = _src!;
      final oldBlur = image.value;
      _src = null;
      image.value = null;
      _disposeAfterFrame(oldSource);
      if (oldBlur != null) _disposeAfterFrame(oldBlur);
    }
    _running = request;
    unawaited(
      _rebuild(request).whenComplete(() {
        _running = null;
        _schedule();
      }),
    );
  }

  /// Invalidates queued/in-flight results and relinquishes published images.
  /// The active raster owns its handle until its asynchronous allocation ends.
  static void release() {
    _token++;
    _debounce?.cancel();
    _debounce = null;
    _pending?.source.dispose();
    _pending = null;
    _failedKey = null;
    _failedAtMs = 0;
    final source = _src;
    final blurred = image.value;
    _src = null;
    _screen = Size.zero;
    _dpr = -1;
    _sigma = -1;
    image.value = null;
    if (source != null) _disposeAfterFrame(source);
    if (blurred != null) _disposeAfterFrame(blurred);
    if (_observingMemory) {
      WidgetsBinding.instance.removeObserver(_memoryObserver);
      _observingMemory = false;
    }
  }

  static void _disposeAfterFrame(ui.Image image) {
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static Future<ui.Image> _rasterize(
    ui.Picture picture,
    int width,
    int height,
  ) =>
      rasterizeForTesting?.call(picture, width, height) ??
      picture.toImage(width, height);

  static Future<void> _rebuild(_BlurRequest request) async {
    final source = request.source;
    final budget = ImageMemoryBudget.blurSize(
      request.screen.width,
      request.screen.height,
      request.dpr,
      request.sigma,
    );
    final pw = budget.width;
    final ph = budget.height;
    final pad = budget.padding;
    ui.Image? padded;
    ui.Image? next;
    ui.Picture? picture;
    ui.Picture? crop;
    var retained = false;
    try {
      final iw = source.width.toDouble();
      final ih = source.height.toDouble();
      final scale = math.max(pw / iw, ph / ih);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        source,
        Rect.fromLTWH(0, 0, iw, ih),
        Rect.fromLTWH(
          pad + (pw - iw * scale) / 2,
          pad + (ph - ih * scale) / 2,
          iw * scale,
          ih * scale,
        ),
        Paint()
          ..imageFilter = cachedGlassBlur(budget.sigma)
          ..filterQuality = FilterQuality.low,
      );
      picture = recorder.endRecording();
      padded = await _rasterize(
        picture,
        budget.paddedWidth,
        budget.paddedHeight,
      );
      picture.dispose();
      picture = null;
      if (request.token != _token) return;
      if (pad == 0) {
        next = padded;
        padded = null;
      } else {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawImageRect(
          padded,
          Rect.fromLTWH(
            pad.toDouble(),
            pad.toDouble(),
            pw.toDouble(),
            ph.toDouble(),
          ),
          Rect.fromLTWH(0, 0, pw.toDouble(), ph.toDouble()),
          Paint()..filterQuality = FilterQuality.none,
        );
        crop = recorder.endRecording();
        next = await _rasterize(crop, pw, ph);
        crop.dispose();
        crop = null;
      }
      if (request.token != _token) return;
      final old = image.value;
      final oldSource = _src;
      _src = source;
      retained = true;
      _screen = request.screen;
      _dpr = request.dpr;
      _sigma = request.sigma;
      _failedKey = null;
      image.value = next;
      next = null;
      if (oldSource != null) _disposeAfterFrame(oldSource);
      if (old != null) _disposeAfterFrame(old);
    } catch (_) {
      if (request.token == _token) {
        _failedKey = request.key;
        _failedAtMs = DateTime.now().millisecondsSinceEpoch;
      }
    } finally {
      picture?.dispose();
      crop?.dispose();
      padded?.dispose();
      next?.dispose();
      if (!retained) source.dispose();
    }
  }
}

final class _BlurRequest {
  const _BlurRequest(
    this.source,
    this.screen,
    this.dpr,
    this.sigma,
    this.key,
    this.token,
  );
  final ui.Image source;
  final Size screen;
  final double dpr;
  final double sigma;
  final int key;
  final int token;

  bool matches(ui.Image image, Size size, double density, double blur) =>
      source.isCloneOf(image) &&
      screen == size &&
      dpr == density &&
      sigma == blur;
}

final class _WallpaperMemoryObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() => WallpaperBlurCache.release();
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
  ImageInfo? _imageInfo;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageProvider? _resolvedFor;
  bool _disposed = false;
  int _resolveEpoch = 0;

  /// [FIX M1] 当前仍持有壁纸的 scope 数量。
  ///
  /// 用来判断「壁纸是否已经彻底不需要了」：provider 由 `config.backgroundImage`
  /// 派生，所以主壳只在**配置了壁纸**时才会创建本 scope，二级页则始终创建。
  /// 于是「计数归零」⟺「当前没有任何地方在显示壁纸」⟹ 可以安全释放进程级的
  /// 预模糊图与源图引用。
  ///
  /// 只靠 `_resolve(provider == null)` 是不够的：用户在**主界面**直接移除壁纸时，
  /// 主壳的 scope 是**整体卸载**（app.dart 在无壁纸时根本不构造 WallpaperWindowScope），
  /// 走不到 _resolve，要等到用户下次打开任意二级页才会释放。
  static int _liveWithProvider = 0;
  bool _counted = false;

  void _track(bool has) {
    if (has == _counted) return;
    _counted = has;
    _liveWithProvider += has ? 1 : -1;
  }

  @override
  void initState() {
    super.initState();
    _track(widget.provider != null);
    WallpaperBlurCache.image.addListener(_onBlurredChanged);
    _resolve();
  }

  /// 共享缓存的预模糊图更新（首次生成完成 / σ 或尺寸变化重建完成）→
  /// 重新发布给页内玻璃卡。由缓存变更触发，不在 build 期间，可安全改 notifier。
  void _onBlurredChanged() {
    if (_disposed) return;
    _publish();
  }

  /// provider 的「壁纸源」：ResizeImage 只是**[FileImage] + 目标尺寸**的包装，
  /// 剥掉尺寸后剩下的才是「用哪张图」。
  ///
  /// 用来区分两种 provider 变化：同一个文件的目标尺寸变了（横竖屏切换、
  /// 窗口缩放 —— 尺寸来自屏幕逻辑尺寸 × DPR），与真的换了壁纸文件。
  /// 前者旧图仍与新背景同源同内容，可以继续用；后者必须立刻作废旧窗口，
  /// 否则会出现「卡片里是旧壁纸、卡外是新壁纸」的错配。
  static ImageProvider? _sourceOf(ImageProvider? p) =>
      p is ResizeImage ? p.imageProvider : p;

  @override
  void didUpdateWidget(WallpaperWindowScope old) {
    super.didUpdateWidget(old);
    // ── 第 1 步：几何 / 遮罩先跟上，且**与是否重新解码无关** ──
    // 原实现在 provider 变化时直接 `_resolve(); return;`，把这一步整个跳过，
    // 于是横竖屏切换后窗口的 screen 停留在旧尺寸 —— painter 用它算「屏幕矩形
    // → 卡片本地坐标」的映射，卡内壁纸会与卡外背景错位。
    _track(widget.provider != null);
    _refreshGeometry();
    if (old.provider == widget.provider) return;
    // ── 第 2 步：同源换尺寸 vs 换文件，决定要不要作废旧窗口 ──
    _resolve(
      clearWindow: _sourceOf(old.provider) != _sourceOf(widget.provider),
    );
  }

  /// 用当前 widget 的 screenSize / overlayColor 原地更新已有窗口
  /// （image 沿用，不重新解码）。
  ///
  /// [blurred] 必须向共享缓存**重新取**而不是沿用：预模糊图是按「旧屏幕 cover
  /// 铺满 + 旧 DPR 换算的 σ」离屏渲染的，直接铺到新长宽比的屏幕矩形上会被拉伸
  /// 变形。几何不匹配时它自然返回 null，painter 先走实时模糊，等缓存重建完成
  /// 再由 [_onBlurredChanged] 发布新图。
  void _refreshGeometry() {
    final cur = _window.value;
    if (cur == null) return;
    if (cur.screen == widget.screenSize &&
        cur.overlayColor == widget.overlayColor) {
      return;
    }
    _window.value = WallpaperWindow(
      image: cur.image,
      blurred: WallpaperBlurCache.currentFor(cur.image, widget.screenSize),
      screen: widget.screenSize,
      overlayColor: widget.overlayColor,
    );
  }

  /// 解析壁纸为 [ui.Image]。
  ///
  /// [clearWindow] 为 true 时先把当前窗口置空（换壁纸文件：旧图与新背景不再是
  /// 同一张，必须作废）；为 false 时**保留旧窗口**直到新图解码完成 —— 横竖屏
  /// 切换正是这种情况：目标尺寸变了必须重新解码（不重解码会因 fit 策略拿到
  /// 偏小的图、放大后发糊），但旧图与新背景是同源同内容的，留着它继续渲染远好过
  /// 让所有玻璃卡掉回退路径、整屏只剩主题底色（用户看到的「切方向后界面变灰」）。
  void _resolve({bool clearWindow = true}) {
    final p = widget.provider;
    if (p == null) {
      _unsubscribe();
      _resolvedFor = null;
      _window.value = null;
      _releaseImageInfo();
      // [FIX M1] 没有壁纸 ⇒ 预模糊图与源壁纸引用都不再需要，全局释放掉。
      // 释放前必须先把本 scope 的窗口置空（上面一行）：否则下面 release() 触发的
      // image 通知会走 _publish()，用已释放的旧图重建一次窗口。
      if (_liveWithProvider == 0) WallpaperBlurCache.release();
      return;
    }
    // 用 == 而不是 identical：壁纸 provider 每次 build 都是新实例，ResizeImage
    // 自身实现了值语义的 ==，用它才能挡住「内容相同的重复解析」。
    if (p == _resolvedFor) return;
    _unsubscribe();
    _resolvedFor = p;
    if (clearWindow) {
      _window.value = null;
      _releaseImageInfo();
    }
    final epoch = _resolveEpoch;
    final listener = ImageStreamListener(
      (info, _) {
        if (_disposed || epoch != _resolveEpoch) {
          info.dispose();
          return;
        }
        _releaseImageInfo();
        _imageInfo = info;
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
        if (!_disposed && epoch == _resolveEpoch) {
          _window.value = null;
          _releaseImageInfo();
        }
      },
    );
    _listener = listener;
    _stream = p.resolve(ImageConfiguration.empty);
    _stream!.addListener(listener);
  }

  void _releaseImageInfo() {
    final old = _imageInfo;
    _imageInfo = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  void _unsubscribe() {
    _resolveEpoch++;
    final previous = _resolvedFor;
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _stream = null;
    _listener = null;
    _resolvedFor = null;
    if (previous != null) {
      unawaited(_evictOldDecode(previous));
    }
  }

  // Evict the keep-alive entry, while other live views may still reuse it. Their
  // ImageInfo handles and ImageStream listeners retain pixels until replacement.
  static Future<void> _evictOldDecode(ImageProvider provider) async {
    try {
      final key = await provider.obtainKey(ImageConfiguration.empty);
      PaintingBinding.instance.imageCache.evict(key, includeLive: false);
    } catch (_) {
      // A failed provider has no decoded keep-alive image to retain.
    }
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
    if (DesktopResizeScope.isResizingOf(context)) {
      return;
    }
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
    _releaseImageInfo();
    final wasShowing = _counted;
    _track(false);
    // [FIX M1] 最后一个「有壁纸」的 scope 消失 ⇒ 壁纸已从配置里移除，释放进程级缓存。
    // 此时其余 scope 的 _window.value 必为 null（它们本来就没有 provider），
    // 所以 release() 触发的 image 通知走 _publish() 会立即 return —— 不会在
    // 卸载阶段去改活动 widget 的状态。
    if (wasShowing && _liveWithProvider == 0) WallpaperBlurCache.release();
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
  bool updateShouldNotify(_WallpaperWindowInherited old) =>
      window != old.window;
}
