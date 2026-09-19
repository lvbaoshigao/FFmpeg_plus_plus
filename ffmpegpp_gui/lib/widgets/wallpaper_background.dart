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
  /// 长宽比 = 屏幕长宽比；绝对像素尺寸 ≤ 屏幕逻辑尺寸 × DPR（有真实模糊时按
  /// 1/2 分辨率渲染以省 3/4 纹理内存，见 [WallpaperBlurCache._rebuild]），
  /// σ 已按 DPR 换算到设备像素空间。painter 侧只做「整张 → 屏幕矩形」的映射，
  /// 因此分辨率与屏幕无关，不需要也不应该在这里假设满分辨率。
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

  /// [_failedKey] 记下失败的时刻（毫秒时间戳）。
  /// 失败不是**永久**弃用该参数，而是冷却 [kBlurRebuildRetryCooldownMs]
  /// 之后允许再试一次 —— 理由见 [request]。
  static int _failedAtMs = 0;

  /// 同一参数指纹失败后的重试冷却时长（毫秒）。
  ///
  /// 为什么要有冷却而不是「失败一次就永久放弃」（原实现）：预模糊图一旦
  /// 生成失败，painter 就会退化成**每帧 × 每张可见玻璃卡**对整屏跑一次
  /// σ 高斯模糊，每次都要按 3σ 外扩分配离屏纹理、并被 GPU 资源池长期缓存
  /// —— 代价远高于「暂时没有预模糊图」。而失败原因常常是一次性的
  /// （显存瞬时紧张、应用从后台切回、窗口正在缩放），永久放弃等于把偶发
  /// 故障升级成常驻劣化。冷却 3s 兼顾两者：持续失败时每 3s 只重试一次，
  /// 开销可忽略；偶发失败则自动恢复。
  static const int kBlurRebuildRetryCooldownMs = 3000;

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
    // 同参数此前失败过：冷却期内不再重试（否则每帧 build 都会重新排队一次
    // 离屏渲染）；冷却结束后放行，让它再试一次（见
    // kBlurRebuildRetryCooldownMs 的说明）。
    if (key == _failedKey &&
        DateTime.now().millisecondsSinceEpoch - _failedAtMs <
            kBlurRebuildRetryCooldownMs) {
      return geoOk;
    }
    if (key == _scheduledKey) return geoOk; // 已排队 / 已在途：不要重复发起
    _scheduledKey = key;
    _debounce?.cancel();
    // 首次请求立即执行，不防抖：`_src == null` 表示此前从未成功生成过任何图，
    // 即「开机 → 第一张预模糊图就绪」这段窗口。它是纯实时模糊窗口 —— 每帧 ×
    // 每张可见玻璃卡都要对整屏跑一次 σ 模糊（Skia 为每次模糊分配 3σ 外扩的
    // 离屏纹理），正是「刚进主界面内存飙到 500MB」的主因之一。这里白等 120ms
    // 毫无收益，直接渲染能把这段窗口压到最短。
    // 注意：**不清 `_scheduledKey`** —— 立即执行是异步的（`toImage` 需 1~3 帧），
    // 期间每帧 build 都会再调 request，靠它挡掉重复发起（否则会每帧渲染一张）。
    // 失败时 `_failedKey` 兜底，不会无限重试。
    // 除此之外的情况（换壁纸 / 窗口缩放 / 拖「模糊度」滑块）仍走防抖，避免
    // 连续变化时反复离屏渲染。
    if (_src == null) {
      unawaited(_rebuild(src, screen, dpr, sigma, key));
      return geoOk;
    }
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
    final int dw = (screen.width * dpr).round().clamp(1, 8192);
    final int dh = (screen.height * dpr).round().clamp(1, 8192);
    final double sigmaDev = sigma * dpr;
    // ── 半分辨率渲染（仅在有真实模糊时）──
    // 这张图随后只会被**模糊后**贴进玻璃，高频信息已经在模糊里丢掉了，因此
    // 按 1/2 分辨率渲染再放大回来，肉眼与满分辨率逐像素等价，而纹理内存与
    // 采样开销都降到 1/4。这是「进主界面时内存飙升」里最容易被忽略的一块：
    // 满分辨率下它是 (屏宽×DPR + 6σ)×(屏高×DPR + 6σ) 的 RGBA 大图
    // （2K/DPR1.25 实测约 25MB 常驻），半分辨率后只剩 ~6MB。
    // 唯一例外是「模糊度 = 0」（用户要的是清晰玻璃）：此时不能降采样，否则
    // 玻璃里的壁纸会被无谓地糊掉 —— 用 σ_dev 做门槛，σ 越大越安全。
    final int ds = sigmaDev >= 4.0 ? 2 : 1;
    // 用整数除法（dw/ds 恒为整数关系：ds 只取 1 或 2），避免 double → int 的 num 报错
    final int pw = (dw ~/ ds).clamp(1, 8192);
    final int ph = (dh ~/ ds).clamp(1, 8192);
    final double sigmaBs = sigmaDev / ds;
    // 模糊在图像边界外取透明（kDecal）并【向内】衰减：若直接渲染一张 pw×ph
    // 的图，屏幕最边缘（贴边的玻璃卡）会明显偏透、露出主题底色。原实现没有
    // 这个问题 —— 它模糊的是整张壁纸、dst 是可能比屏幕更大的 cover，屏幕边缘
    // 落在壁纸内部。这里用「外扩 3σ 画布 → 裁出中间 pw×ph」还原该行为：衰减
    // 落在被裁掉的 padding 上，最终交付给 painter 的仍是屏幕尺寸的图，因此
    // 不额外常驻内存（padding 那两张只是重建瞬间的临时对象）。
    final int pad = (3 * sigmaBs).ceil().clamp(0, 512);
    ui.Image? next;
    try {
      final iw = src.width.toDouble();
      final ih = src.height.toDouble();
      // 与 BoxFit.cover 一致：等比铺满整屏、居中裁切。与原 painter 的 cover
      // 计算等价，保证卡内壁纸与卡外背景逐像素对齐。
      final scale = math.max(pw / iw, ph / ih);
      final double cw = iw * scale;
      final double ch = ih * scale;
      final paint = Paint()
        // 预渲染画布已是设备像素，σ 需乘 DPR（painter 里的 σ 是逻辑单位）
        // 再除以降采样系数 ds（画布也同步缩小了 ds 倍，σ 必须同比例缩）
        // σ 走进程级缓存：改「模糊度」时会连续重建，避免反复新建 native filter。
        ..imageFilter = cachedGlassBlur(sigmaBs)
        // 用 low 而非 medium：这里是把源壁纸**放大**到 cover（最差也是 1:1），
        // mipmap 只在缩小采样时才有意义，而 medium 会让引擎为源图额外生成
        // 一条 mipmap 链（≈ +1/3 纹理内存）—— 壁纸常是几千万像素的大图，
        // 这笔开销在「进主界面」这个内存最紧张的时段尤其不值得。
        ..filterQuality = FilterQuality.low;

      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(
        src,
        Rect.fromLTWH(0, 0, iw, ih),
        Rect.fromLTWH(
            pad + (pw - cw) / 2, pad + (ph - ch) / 2, cw, ch),
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
          // 1:1 纯裁剪拷贝（pw×ph → pw×ph）：high（双三次）在这里毫无收益，
          // 只是每次重建都白做一遍高代价重采样。none = 精确像素拷贝。
          Paint()..filterQuality = FilterQuality.none,
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
      // 生成失败（如显存不足）：保留旧图，painter 仍可回退实时模糊。
      // 记下指纹与失败时刻 → 冷却期内不再重试，冷却后自动再试一次
      // （见 kBlurRebuildRetryCooldownMs）。
      //
      // 同时必须清掉 _scheduledKey：立即执行路径（`_src == null`）正是靠它
      // 挡掉重复发起的，失败时不清就会让后续每次 build 都命中
      // `key == _scheduledKey` 直接返回 —— 冷却机制形同虚设，重试永远排不上。
      _failedKey = failKey;
      _failedAtMs = DateTime.now().millisecondsSinceEpoch;
      _scheduledKey = null;
      return;
    }
    // 成功（含参数已变化后的首次成功）：清掉失败标记，让该指纹重新可试。
    _failedKey = null;
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
