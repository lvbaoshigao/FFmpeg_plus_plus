import 'dart:io';

import 'android_platform.dart';

/// ColorOS「流体云」进度卡推送服务（设置→任务→通知→「允许将进度展示在流体云上」，
/// 该开关仅在 ColorOS 且端侧意图共享 Provider 可达时显示）。
///
/// 职责与边界：
///  - 节流：流体云有系统级频次限制（错误码 10103002），进度事件按
///    「≥1 秒间隔 + 进度推进 ≥2%」合并后再发（进度回落=新任务开始时必发）；
///  - 单卡：全应用只维护一张进度卡（entityId 固定，见 ColorOsFluidCloud.kt），
///    并发多任务时显示最近更新的一条，避免实体数量超限（10103004）；
///  - 短路：非 Android 直接 O(1) 返回；调用方（AppState）已按
///    `config.fluidCloudProgress` 预判后才进来，服务内不持有 AppState
///    （services 不反向依赖 providers）；
///  - 失败静默：创卡失败（无权限 10101001 / 开关关闭 10103003）只把重试频率
///    压到节流间隔，绝不抛异常、绝不影响任务本身。
class FluidCloudProgress {
  FluidCloudProgress._();

  /// 当前是否有一张「活着」的进度卡（创卡成功且未销卡）。
  static bool _cardAlive = false;

  /// 上次成功推送时刻（无论成败都占住节流窗口：失败重试最多 1 次/秒）。
  static DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  static int _lastPercent = -1;

  static const Duration _minInterval = Duration(seconds: 1);

  /// 任务进度心跳。调用方：`AppState._flushProgress`（其自身已按 300ms 批量
  /// 节流，这里再做系统侧频次要求的合并）。
  static void reportProgress(String filename, double progress) {
    if (!Platform.isAndroid) return;
    final pct = progress.round().clamp(0, 100);
    final now = DateTime.now();
    if (_cardAlive) {
      if (now.difference(_lastSentAt) < _minInterval) return;
      // 同档进度不重发；进度回落（新任务）必发。
      if (pct > _lastPercent && pct - _lastPercent < 2 && pct < 100) return;
    }
    _lastSentAt = now;
    AndroidPlatformBridge.fluidCloudProgress(filename: filename, progress: pct)
        .then((ok) {
      if (ok == true) {
        _cardAlive = true;
        _lastPercent = pct;
      }
    });
  }

  /// 队列空闲检查。调用方：`AppState._tasksNotify` —— 任务完成/失败/取消的
  /// 状态落盘都汇聚于此。[hasRunningTasks] 为 false 且卡还活着 → 销卡
  /// （actionStatus=2）。销卡失败由原生侧自愈（见 ColorOsFluidCloud.endProgress）。
  static void syncQueueIdle(bool hasRunningTasks) {
    if (!Platform.isAndroid || !_cardAlive || hasRunningTasks) return;
    _cardAlive = false;
    _lastPercent = -1;
    AndroidPlatformBridge.fluidCloudEnd();
  }
}
