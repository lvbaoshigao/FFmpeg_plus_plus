import 'dart:io';

import 'android_platform.dart';

/// 小米「超级岛」进度卡推送服务（设置→任务→通知→「允许将进度展示在超级岛上」，
/// 该开关仅在支持岛的 HyperOS（协议 ≥3 且有焦点通知权限）时显示）。
///
/// 职责与边界（与 services/fluid_cloud_progress.dart 同构，两条链路按 ROM
/// 互斥生效——设置项各自按能力条件显隐）：
///  - 节流：进度事件按「≥1 秒间隔 + 进度推进 ≥2%」合并后再发
///    （进度回落=新任务开始时必发），避免秒级刷新通知/岛；
///  - 单卡：全应用只维护一张进度通知（固定通知 id，见 HyperOsIsland.kt），
///    并发多任务时显示最近更新的一条 —— 岛一次只显示一条焦点通知；
///  - 短路：非 Android 直接 O(1) 返回；调用方（AppState）已按
///    `config.islandProgress` 预判后才进来，服务内不持有 AppState
///    （services 不反向依赖 providers）；
///  - 失败静默：发送失败（系统太旧 / 通知被拒）只把重试频率压到节流间隔，
///    绝不抛异常、绝不影响任务本身。
class IslandProgress {
  IslandProgress._();

  /// 当前是否有一张「活着」的进度通知（发送成功且未销卡）。
  static bool _cardAlive = false;

  /// 上次成功推送时刻（无论成败都占住节流窗口：失败重试最多 1 次/秒）。
  static DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  static int _lastPercent = -1;

  static const Duration _minInterval = Duration(seconds: 1);

  /// 任务进度心跳。调用方：`AppState._flushProgress`（其自身已按 300ms 批量
  /// 节流，这里再做系统侧刷新频率要求的合并）。
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
    AndroidPlatformBridge.islandProgress(filename: filename, progress: pct)
        .then((ok) {
      if (ok == true) {
        _cardAlive = true;
        _lastPercent = pct;
      }
    });
  }

  /// 队列空闲检查。调用方：`AppState._tasksNotify` —— 任务完成/失败/取消的
  /// 状态落盘都汇聚于此。[hasRunningTasks] 为 false 且卡还活着 → 销卡
  /// （cancel 固定通知 id，见 HyperOsIsland.endProgress）。
  static void syncQueueIdle(bool hasRunningTasks) {
    if (!Platform.isAndroid || !_cardAlive || hasRunningTasks) return;
    _cardAlive = false;
    _lastPercent = -1;
    AndroidPlatformBridge.islandEnd();
  }
}
