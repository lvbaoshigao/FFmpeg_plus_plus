library;

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// 平台判定工具 —— 所有移动端适配都通过这里的判定 gate 起来，
/// 桌面端（Windows/Linux/macOS）行为完全不变。

/// 是否为移动端（Android / iOS）。Web 上禁用 dart:io，先行短路。
bool get isMobilePlatform => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// 是否为 Android。
bool get isAndroidPlatform => !kIsWeb && Platform.isAndroid;

/// 是否为 Windows（桌面端）。
bool get isWindowsPlatform => !kIsWeb && Platform.isWindows;

/// 是否为 Linux（桌面端）。
bool get isLinuxPlatform => !kIsWeb && Platform.isLinux;

/// 移动端悬浮底部导航栏整体占据的底部高度（胶囊高 + 上下留白 + 安全区）。
/// 各 Tab 页主滚动区用它作为底部 padding，避免内容被悬浮导航遮挡。
const double kMobileNavClearance = 96.0;

/// 菜单栏改为左侧 / 右侧竖排导轨时，主滚动区底部只需常规留白。
/// 竖排导轨与内容**并排**布局（见 app.dart 的 Row 分支），不再悬浮遮挡内容，
/// 若继续让出 96px，宽屏设备列表底部会白空一大块。
const double kMobileNavSideClearance = 20.0;

/// 移动端主导航的摆放位置。
///
/// * [bottom] —— 默认：悬浮在屏幕底部的玻璃胶囊（手机竖屏的唯一合理形态）；
/// * [left] / [right] —— 竖排导轨，与内容并排：宽屏（平板 / 横屏）下把
///   96px 的底部占用换成 60px 的侧向占用，纵向空间全部还给内容。
enum MobileNavPlacement { bottom, left, right }

/// 自动判定宽屏的横纵比阈值：宽 / 高 ≥ 该值即认为「横向比例过大」→ 左侧导轨。
///
/// 取值依据：手机竖屏 411×915 ≈ 0.45、折叠屏内屏展开 884×1104 ≈ 0.80 都远低于
/// 阈值；平板横屏 1280×800 = 1.60、手机横屏 915×411 ≈ 2.23 都显著高于阈值。
/// 1.25 落在两者之间，给「近方形」的折叠屏留出余量（仍走底部，符合手机手感）。
const double kMobileNavAutoAspect = 1.25;

/// 配置字符串（'auto' / 'bottom' / 'left' / 'right'）→ 生效位置。
///
/// 抽成纯函数的原因：**同一个判定必须被三处共用** —— AppShell（决定用
/// Stack 悬浮还是 Row 并排）、NavGlassShell（决定四周安全区取哪一边）、
/// 以及各主 Tab 页（决定底部让出多少）。任何一处自己写一份就会漂移。
///
/// * 'bottom' / 'left' / 'right'：用户强制指定的方向，直接采纳（设置项「仅移动端
///   可用」由设置页的 `isMobilePlatform` 门控，这里不重复判定平台）。
/// * 'auto' 与未知值：按屏幕横纵比判定（见 [kMobileNavAutoAspect]），
///   尺寸非法（0 / 负值，如首帧）时按底部处理。
MobileNavPlacement resolveMobileNavPlacement(
  String configured,
  double width,
  double height,
) {
  switch (configured) {
    case 'bottom':
      return MobileNavPlacement.bottom;
    case 'left':
      return MobileNavPlacement.left;
    case 'right':
      return MobileNavPlacement.right;
  }
  if (width <= 0 || height <= 0) return MobileNavPlacement.bottom;
  return width / height >= kMobileNavAutoAspect
      ? MobileNavPlacement.left
      : MobileNavPlacement.bottom;
}
