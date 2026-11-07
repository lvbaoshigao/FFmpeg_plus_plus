import 'package:flutter/widgets.dart';

// ═══════════════════════════════════════════
// 应用内字号缩放（设置 → 字体 → 字号）的唯一载体
// ═══════════════════════════════════════════
//
// 为什么需要这个文件（用户反馈「字体大小滑块不起作用 / 选项文字不该跟着变大」）：
//
// 1) 全局字号只有一条落地路径 —— app.dart 里 MaterialApp.builder 给整棵树换一个
//    MediaQuery 的 textScaler。这里把「系统倍率」和「应用内倍率」**分别**暴露出去，
//    而不是只丢一个乘积：
//    * 系统倍率来自 Android「设置 → 显示 → 字体大小」，任何界面都该跟；
//    * 应用内倍率来自 设置 → 字体 → 字号，只作用于「正文区域」。
// 2) 选项控件（下拉框 / 分段药丸，见 widgets/option_menu_bar.dart）**不跟**应用内
//    字号：它们的宽度是固定的（设置页 _kMenuWidth），字一大就只剩省略号。
//    用户明确要求「字体大小的调整不要应用于选项文字」。这类子树用
//    [withoutAppTextScale] 包一下即可 —— 仍然跟随系统字号，只是忽略应用内设置。
//
// 改动时注意：这里是「倍率」的唯一来源，不要在别处再乘一次 fontSize（会翻倍）。

/// 应用内字号缩放上下文。
///
/// 由 `app.dart` 的 `MaterialApp.builder` 注入（位于 MediaQuery 之上），
/// 因此导航栈里的每一页都能读到。
class AppTextScale extends InheritedWidget {
  const AppTextScale({
    super.key,
    required this.systemScale,
    required this.appScale,
    required super.child,
  });

  /// 系统字号倍率（Android 设置 → 显示 → 字体大小；其它平台通常为 1.0）。
  final double systemScale;

  /// 应用内字号倍率（设置里的 fontSize / 14）。
  final double appScale;

  /// 最终倍率（两者相乘后钳制），与 app.dart 写入 MediaQuery 的值一致。
  static const double minScale = 0.5;
  static const double maxScale = 2.6;

  /// 取系统字号倍率。
  ///
  /// 不在 [AppTextScale] 覆盖范围内时（例如单独的 widget 测试）退化为从
  /// MediaQuery 反推，保证行为一致。
  static double systemScaleOf(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<AppTextScale>();
    if (s != null) return s.systemScale;
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return 1.0;
    return mq.textScaler.scale(14.0) / 14.0;
  }

  @override
  bool updateShouldNotify(AppTextScale oldWidget) =>
      oldWidget.systemScale != systemScale || oldWidget.appScale != appScale;
}

/// 「这里的文字不跟随『设置 → 字体 → 字号』」—— 选项控件专用包装。
///
/// 只还原掉**应用内**倍率，系统字号设置仍然生效（用户在系统里调大字体，
/// 选项文字也该跟着大，否则会小得看不清）。
///
/// 已经是目标倍率时原样返回 [child]，不额外插一层 MediaQuery（少一次重建）。
Widget withoutAppTextScale(BuildContext context, Widget child) {
  final system = AppTextScale.systemScaleOf(context).clamp(
    AppTextScale.minScale,
    AppTextScale.maxScale,
  );
  final mq = MediaQuery.maybeOf(context);
  if (mq == null) return child;
  final current = mq.textScaler.scale(14.0) / 14.0;
  if ((current - system).abs() < 0.001) return child;
  return MediaQuery(
    data: mq.copyWith(textScaler: TextScaler.linear(system)),
    child: child,
  );
}
