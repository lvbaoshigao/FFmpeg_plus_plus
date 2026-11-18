import 'package:flutter/material.dart';

/// User-selected neutral surfaces; independent of theme seed and Monet.
abstract final class AppNeutralSurface {
  static const darkBackground = Color(0xFF1A1A1A);
  static const lightBackground = Color(0xFFF2F2F2);
  static const darkCard = Color(0xFF2B2B2B);
  static const lightCard = Color(0xFFE4E4E4);

  /// 比 [card] 再高一档的容器色（对话框 / 最高层容器）。
  ///
  /// 存在的理由：`surfaceContainerHigh` 与 `surfaceContainerHighest` 若都映射到
  /// 同一个中性值，对话框就会和卡片完全同色 —— 暗色下只剩一圈 0.6px 描边可辨
  /// （「浮层糊在卡片里」）。这两档必须拉开。
  static const darkCardHigh = Color(0xFF333333);
  static const lightCardHigh = Color(0xFFDCDCDC);

  static Color background(Brightness brightness) =>
      brightness == Brightness.dark ? darkBackground : lightBackground;

  static Color card(Brightness brightness) =>
      brightness == Brightness.dark ? darkCard : lightCard;

  static Color cardHigh(Brightness brightness) =>
      brightness == Brightness.dark ? darkCardHigh : lightCardHigh;
}
