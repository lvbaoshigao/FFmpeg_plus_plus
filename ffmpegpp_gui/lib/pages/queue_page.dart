import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../services/system_monitor.dart';
import '../theme/app_strings.dart';
import '../widgets/task_card.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
import '../platform/app_platform.dart';

class QueuePage extends StatefulWidget {
  const QueuePage({super.key});
  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final _monitor = SystemMonitor();

  @override
  void initState() {
    super.initState();
    _monitor.start();
  }

  @override
  void dispose() {
    _monitor.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Consumer<AppState>(
      builder: (context, state, _) {
        final s = AppStrings.of(state.config.language);
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(children: [
            // 全屏可滚动的内容（移动端顶部留出药丸空间）
            isMobilePlatform
                ? Padding(
                    padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 60),
                    child: state.tasks.isEmpty
                        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.inbox_outlined, size: 64, color: scheme.outline),
                            const SizedBox(height: 16),
                            Text(s.emptyQueue, style: TextStyle(fontSize: 16, color: scheme.outline)),
                            const SizedBox(height: 8),
                            Text(s.emptyQueueHint, style: TextStyle(fontSize: 13, color: scheme.outline)),
                          ]))
                        : ListView.builder(
                            padding: EdgeInsets.fromLTRB(8, 8, 8, kMobileNavClearance),
                            itemCount: state.tasks.length,
                            itemBuilder: (_, i) => TaskCard(key: ValueKey(state.tasks[i].id), task: state.tasks[i]),
                          ),
                  )
                : Column(children: [
                    GlassTopBar(
                      title: Text(s.navQueue),
                      actions: _buildActions(scheme, state, s),
                    ),
                    Expanded(
                      child: state.tasks.isEmpty
                          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.inbox_outlined, size: 64, color: scheme.outline),
                              const SizedBox(height: 16),
                              Text(s.emptyQueue, style: TextStyle(fontSize: 16, color: scheme.outline)),
                              const SizedBox(height: 8),
                              Text(s.emptyQueueHint, style: TextStyle(fontSize: 13, color: scheme.outline)),
                            ]))
                          : RepaintBoundary(
                              child: ListView.builder(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                                itemCount: state.tasks.length,
                                itemBuilder: (_, i) => TaskCard(key: ValueKey(state.tasks[i].id), task: state.tasks[i]),
                              ),
                            ),
                    ),
                  ]),
            // 移动端顶栏浮层（不影响滚动）
            if (isMobilePlatform)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildMobileTopBar(scheme, state, s),
              ),
          ]),
        );
      },
    );
  }

  Widget _monitorBar(ColorScheme scheme, AppState state) {
    return _MonitorWidget(monitor: _monitor, scheme: scheme);
  }

  /// 顶栏操作按钮 + 资源占用（桌面端与移动端共用同一份逻辑）。
  List<Widget> _buildActions(ColorScheme scheme, AppState state, AppStrings s) {
    return [
      if (state.processing)
        OutlinedButton.icon(
            icon: const Icon(Icons.stop, size: 16), label: Text(s.cancelAll),
            onPressed: () => state.cancelProcessing())
      else ...[
        if (state.tasks.any((t) => t.status == TaskStatus.pending))
          FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 18), label: Text(s.startProcessing),
              onPressed: () => state.processAllTasks()),
        if (state.tasks.any((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed || t.status == TaskStatus.cancelled))
          TextButton.icon(
              icon: const Icon(Icons.cleaning_services_outlined, size: 16), label: Text(s.clearCompleted),
              onPressed: () => state.clearCompletedTasks()),
        if (state.tasks.isNotEmpty)
          TextButton.icon(
              icon: const Icon(Icons.delete_sweep, size: 16), label: Text(s.clearAll),
              onPressed: () => state.clearAllTasks()),
      ],
      // 紧凑资源占用（顶栏右侧，小尺寸）
      const SizedBox(width: 8),
      Padding(
        padding: const EdgeInsets.only(right: 12),
        child: _monitorBar(scheme, state),
      ),
    ];
  }

  /// 移动端顶栏：左侧标题药丸自适应宽度（内容贴合，不撑满），
  /// 右侧操作药丸也按内容自适应（贴合 CPU/内存占用条 + 按钮），
  /// 两者之间留固定 8px 间隙，不再用 Expanded 强制撑满剩余宽度。
  /// 移动端顶栏操作（紧凑图标按钮，无文字）：和处理队列相关的按钮全部用图标，
  /// 避免带文字的按钮在顶栏药丸里太长（任务全部完成时尤其突兀）。
  List<Widget> _buildMobileActions(ColorScheme scheme, AppState state, AppStrings s) {
    Widget iconBtn(IconData icon, String tooltip, VoidCallback? onTap, {Color? color}) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(shape: BoxShape.circle),
              child: Icon(icon, size: 19, color: color ?? scheme.onSurface),
            ),
          ),
        ),
      );
    }
    return [
      if (state.processing)
        iconBtn(Icons.stop, s.cancelAll, () => state.cancelProcessing()),
      if (!state.processing && state.tasks.any((t) => t.status == TaskStatus.pending))
        iconBtn(Icons.play_arrow, s.startProcessing, () => state.processAllTasks()),
      if (state.tasks.any((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed || t.status == TaskStatus.cancelled))
        iconBtn(Icons.cleaning_services_outlined, s.clearCompleted, () => state.clearCompletedTasks()),
      if (state.tasks.isNotEmpty)
        iconBtn(Icons.delete_sweep, s.clearAll, () => state.clearAllTasks()),
      const SizedBox(width: 8),
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: _monitorBar(scheme, state),
      ),
    ];
  }

  Widget _buildMobileTopBar(ColorScheme scheme, AppState state, AppStrings s) {
    final safeTop = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(8, safeTop + 6, 8, 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        // 左：标题药丸（高度 44，与项目页「项目」药丸完全一致）
        MobileGlassPill(
          radius: 22,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          pressable: true,
          child: Text(s.navQueue,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface)),
        ),
        const SizedBox(width: 8),
        // 右：操作药丸（高度 44；贴合内容：横向滚动防溢出，不再用 Expanded 强制填满剩余空间）。
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: MobileGlassPill(
              radius: 22,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: _buildMobileActions(scheme, state, s)),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _MonitorWidget extends StatefulWidget {
  final SystemMonitor monitor;
  final ColorScheme scheme;
  const _MonitorWidget({required this.monitor, required this.scheme});
  @override
  State<_MonitorWidget> createState() => _MonitorWidgetState();
}

class _MonitorWidgetState extends State<_MonitorWidget> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.monitor;
    final sc = widget.scheme;
    // 紧凑小尺寸：仅图标 + 数值，适合放在顶栏右侧
    // -1 表示读取失败（Android SELinux 拦截 /proc），显示 "--" 避免误导为 0%
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _mini(Icons.memory, m.cpuPercent < 0 ? '--' : '${m.cpuPercent.toStringAsFixed(0)}%', m.cpuPercent < 0 ? 0 : m.cpuPercent / 100, sc),
      const SizedBox(width: 8),
      _mini(Icons.storage, m.ramUsedGb < 0 ? '--' : '${m.ramUsedGb.toStringAsFixed(1)}G', m.ramPercent < 0 ? 0 : m.ramPercent / 100, sc),
      // GPU：拿到型号或占用率任一项即显示（Android 上 GPU 名走 EGL 查询，
      // 占用率依赖 sysfs，部分机型只能显示 "--"）。
      if (m.gpuName.isNotEmpty || m.gpuPercent >= 0) ...[
        const SizedBox(width: 8),
        _mini(Icons.videocam, m.gpuPercent < 0 ? '--' : '${m.gpuPercent.toStringAsFixed(0)}%', m.gpuPercent < 0 ? 0 : m.gpuPercent / 100, sc),
      ],
    ]);
  }

  /// 迷你指标：彩色图标 + 等宽数值。
  Widget _mini(IconData icon, String value, double progress, ColorScheme scheme) {
    final color = progress > 0.8 ? Colors.red : progress > 0.5 ? Colors.orange : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(value, style: TextStyle(fontSize: 10, color: scheme.onSurface, fontFamily: AppTheme.monoFont, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
