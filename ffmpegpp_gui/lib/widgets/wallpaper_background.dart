import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app.dart';
import '../providers/app_state.dart';

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

  /// 屏幕逻辑尺寸（壁纸 cover 铺满的目标矩形）。
  final Size screen;

  /// 壁纸之上的遮罩色（「背景不透明度」，withWallpaper 里叠在图片上的那层）。
  /// 卡片开窗必须复现它，否则玻璃里的壁纸比背景原亮度不一致。
  final Color overlayColor;

  const WallpaperWindow({
    required this.image,
    required this.screen,
    required this.overlayColor,
  });
}

/// 壁纸窗口作用域：把当前壁纸解析为 [ui.Image]（异步，加载完成前
/// [window] 为 null，玻璃卡自动走原 BackdropFilter 回退），并通过
/// InheritedWidget 下发给页内所有玻璃卡。
///
/// 解析走 ImageProvider.resolve + ImageStreamListener，与页面显示的
/// Image 共用同一份 ImageCache 条目 —— 不会二次解码、不额外占内存。
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

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(WallpaperWindowScope old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) _resolve();
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
    final listener = ImageStreamListener((info, _) {
      _window.value = WallpaperWindow(
        image: info.image,
        screen: widget.screenSize,
        overlayColor: widget.overlayColor,
      );
    });
    _listener = listener;
    _stream = p.resolve(ImageConfiguration.empty);
    _stream!.addListener(listener);
  }

  void _unsubscribe() {
    _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
    _resolvedFor = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    _window.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _WallpaperWindowInherited(window: _window, child: widget.child);
  }
}

class _WallpaperWindowInherited extends InheritedWidget {
  final ValueNotifier<WallpaperWindow?> window;
  const _WallpaperWindowInherited({required this.window, required super.child});

  @override
  bool updateShouldNotify(_WallpaperWindowInherited old) => window != old.window;
}
