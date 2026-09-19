import 'package:flutter/services.dart';

import '../platform/app_platform.dart';

/// 高刷新率（90 / 120 / 144Hz）支持 —— 仅 Android 有实现，其它平台全部 no-op。
///
/// **为什么需要原生侧动手**：Android 应用默认不一定跑在屏幕的最高刷新率上。
/// 大量 ROM（MIUI / ColorOS / HarmonyOS 等）只给「声明了高刷意图」的应用开高帧，
/// 窗口的 `preferredRefreshRate` 留空时会把帧率锁在 60Hz —— 于是 120Hz 屏幕上
/// Flutter 界面仍按 60fps 渲染。原生侧（MainActivity）三条路径一起上：
///
/// * **API 30+**：`View.setFrameRate(rate, FRAME_RATE_COMPATIBILITY_DEFAULT)`
///   —— 官方推荐入口，也是唯一能被系统「自适应刷新率（VRR/LTPO）」策略正常
///   协商的 API（它会随滚动/静止状态自动升降，而不是死锁 120Hz）。
/// * **全版本兜底**：`WindowManager.LayoutParams.preferredRefreshRate`
///   —— 部分 ROM 只认这个字段，必须一并设置。
/// * **API 23~29**：额外用 `preferredDisplayModeId` 精确选中「**同分辨率**下
///   刷新率最高」的显示模式。绝不能跨分辨率选模式（会把屏幕分辨率改掉），
///   所以原生侧只在与当前模式同宽高的候选里挑最高刷新率。
///
/// 关闭该开关（或请求 0）表示「不干预」：交还系统默认，不做任何强制。
class RefreshRate {
  RefreshRate._();

  /// 与 MainActivity 的其它原生能力共用同一条 channel（见 android_platform.dart）。
  static const MethodChannel _channel = MethodChannel('ffmpegpp/android');

  /// 当前分辨率下可用的最高刷新率（Hz）。
  /// 非 Android / 系统取不到 / 调用失败均返回 null（调用方据此回退为「不干预」）。
  static Future<double?> maxRefreshRate() async {
    if (!isAndroidPlatform) return null;
    try {
      final v = await _channel.invokeMethod<num>('maxRefreshRate');
      final d = v?.toDouble();
      return (d == null || d <= 0) ? null : d;
    } catch (_) {
      return null;
    }
  }

  /// 请求以 [hz] 刷新；`null` 或 `<= 0` 表示交还系统默认（不干预）。
  /// 返回是否至少有一条设置路径生效（用于日志/诊断，失败不抛异常）。
  static Future<bool> apply(double? hz) async {
    if (!isAndroidPlatform) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setPreferredRefreshRate',
        {'rate': (hz == null || hz <= 0) ? 0.0 : hz},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 按设置项求值：
  /// * `enabled == false` → 交还系统默认（0 = 无偏好）；
  /// * `enabled == true`  → 取当前分辨率下的最高刷新率并请求之；
  ///   取不到（模拟器/异常 ROM）则**什么都不做**，而不是盲目塞一个 120。
  static Future<bool> applyEnabled(bool enabled) async {
    if (!isAndroidPlatform) return false;
    if (!enabled) return apply(0);
    final max = await maxRefreshRate();
    if (max == null) return false;
    return apply(max);
  }
}
