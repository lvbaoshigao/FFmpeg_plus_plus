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

/// 是否为 macOS（桌面端）。
bool get isMacOSPlatform => !kIsWeb && Platform.isMacOS;

/// 是否为 Linux（桌面端）。
bool get isLinuxPlatform => !kIsWeb && Platform.isLinux;

/// 移动端悬浮底部导航栏整体占据的底部高度（胶囊高 + 上下留白 + 安全区）。
/// 各 Tab 页主滚动区用它作为底部 padding，避免内容被悬浮导航遮挡。
const double kMobileNavClearance = 96.0;
