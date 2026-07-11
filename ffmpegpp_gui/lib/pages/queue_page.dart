import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/system_monitor.dart';
import '../theme/app_strings.dart';
import '../widgets/task_card.dart';
import '../widgets/glass_panel.dart';

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
            GlassTopBar(
              title: Text(s.navQueue),
              actions: [
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
            ],
          ),
          Expanded(child: Column(children: [
            // ── 系统监控条 ──
            _monitorBar(scheme, state),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: state.tasks.length,
                    itemBuilder: (_, i) => TaskCard(task: state.tasks[i]),
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
}

class _MonitorWidget extends StatefulWidget {
  final SystemMonitor monitor;
  final ColorScheme scheme;
  const _MonitorWidget({required this.monitor, required this.scheme});
  @override
  State<_MonitorWidget> createState() => _MonitorWidgetState();
}

class _MonitorWidgetState extends State<_MonitorWidget> {
  @override
  void initState() {
    super.initState();
    // 每 2 秒刷新 UI
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) setState(() {});
      return mounted;
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.monitor;
    final sc = widget.scheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: sc.surfaceContainerHighest.withAlpha(80),
      child: Row(children: [
        _chip(Icons.memory, 'CPU', '${m.cpuPercent.toStringAsFixed(0)}%', m.cpuPercent / 100, sc),
        const SizedBox(width: 16),
        _chip(Icons.storage, 'RAM', '${m.ramUsedGb.toStringAsFixed(1)}/${m.ramTotalGb.toStringAsFixed(1)} GB', m.ramPercent / 100, sc),
        const SizedBox(width: 16),
        if (m.gpuName.isNotEmpty) _chip(Icons.videocam, 'GPU', '${m.gpuPercent.toStringAsFixed(0)}%', m.gpuPercent / 100, sc),
      ]),
    );
  }

  Widget _chip(IconData icon, String label, String value, double progress, ColorScheme scheme) {
    final color = progress > 0.8 ? Colors.red : progress > 0.5 ? Colors.orange : scheme.primary;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 4),
      Text('$label: $value', style: TextStyle(fontSize: 11, color: scheme.onSurface, fontFamily: Platform.isWindows ? 'Consolas' : 'monospace')),
      const SizedBox(width: 6),
      SizedBox(width: 40, height: 4, child: LinearProgressIndicator(
        value: progress.clamp(0, 1), backgroundColor: scheme.surfaceContainerHighest,
        color: color, borderRadius: BorderRadius.circular(2))),
    ]);
  }
}
