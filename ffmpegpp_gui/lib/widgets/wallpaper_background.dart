import 'dart:io';
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
  return Stack(children: children);
}
