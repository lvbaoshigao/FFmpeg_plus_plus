library;

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// 平台判定工具 —— 所有移动端适配都通过这里的判定 gate 起来，
/// 桌面端（Windows/Linux/macOS）行为完全不变。

/// 是否为移动端（Android / iOS）。Web 上禁用 dart:io，先行短路。
bool get isMobilePlatform => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// 是否为 Android。
bool get isAndroidPlatform => !kIsWeb && Platform.isAndroid;
