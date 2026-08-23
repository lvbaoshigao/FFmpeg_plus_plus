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
          body: Column(children: [
            isMobilePlatform
                ? _buildMobileTopBar(scheme, state, s)
                : GlassTopBar(
                    title: Text(s.navQueue),
                    actions: _buildActions(scheme, state, s),
                  ),
          Expanded(child: Column(children: [
            // ── 任务列表 ──
            Expanded(child: state.tasks.isEmpty
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.inbox_outlined, size: 64, color: scheme.outline),
                    const SizedBox(height: 16),
                    Text(s.emptyQueue, style: TextStyle(fontSize: 16, color: scheme.outline)),
                    const SizedBox(height: 8),
                    Text(s.emptyQueueHint, style: TextStyle(fontSize: 13, color: scheme.outline)),
                  ]))
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, isMobilePlatform ? kMobileNavClearance : 8),
                    itemCount: state.tasks.length,
                    itemBuilder: (_, i) => TaskCard(key: ValueKey(state.tasks[i].id), task: state.tasks[i]),
                  )),
          ])),
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

  /// 移动端顶栏：左侧标题药丸 + 右侧操作药丸（液态玻璃），与项目/设置页一致；
  /// 右侧操作横向滚动，窄屏溢出时不会换行/报错。
  Widget _buildMobileTopBar(ColorScheme scheme, AppState state, AppStrings s) {
    final safeTop = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, safeTop + 6, 12, 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        // 左：标题药丸
        MobileGlassPill(
          radius: 22,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(s.navQueue,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface)),
        ),
        const SizedBox(width: 8),
        // 右：操作药丸（横向滚动防溢出）
        Expanded(
          child: MobileGlassPill(
            radius: 22,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: _buildActions(scheme, state, s)),
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
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _mini(Icons.memory, '${m.cpuPercent.toStringAsFixed(0)}%', m.cpuPercent / 100, sc),
      const SizedBox(width: 8),
      _mini(Icons.storage, '${m.ramUsedGb.toStringAsFixed(1)}G', m.ramPercent / 100, sc),
      if (m.gpuName.isNotEmpty) ...[
        const SizedBox(width: 8),
        _mini(Icons.videocam, '${m.gpuPercent.toStringAsFixed(0)}%', m.gpuPercent / 100, sc),
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
