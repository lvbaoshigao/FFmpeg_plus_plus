import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

class TaskCard extends StatelessWidget {
  final TaskInfo task;
  const TaskCard({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = context.watch<AppState>();
    final s = AppStrings.of(state.config.language);
    final clr = scheme.onSurface;

    String statusLabel() => switch (task.status) {
      TaskStatus.pending => s.pending, TaskStatus.processing => s.processing,
      TaskStatus.completed => s.completed, TaskStatus.failed => s.failed,
      TaskStatus.cancelled => s.cancelled,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => state.toggleTaskExpanded(task.id),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(children: [
                // 缩略图
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: _ThumbWidget(filepath: task.inputPath),
                ),
                const SizedBox(width: 8),
                Icon(_statusIcon, size: 20, color: _statusColor(scheme)),
                const SizedBox(width: 10),
                Expanded(child: Text(task.filename,
                    style: TextStyle(fontWeight: FontWeight.w600, color: clr),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (task.status == TaskStatus.pending)
                  IconButton(icon: Icon(Icons.play_circle_filled, color: scheme.primary, size: 22),
                      tooltip: s.startProcessing, onPressed: () => state.processSingleTask(task.id)),
                if (task.status == TaskStatus.processing)
                  TextButton.icon(icon: const Icon(Icons.stop, size: 14),
                      label: Text(s.cancel, style: const TextStyle(fontSize: 11)),
                      onPressed: () => state.cancelProcessing(),
                      style: TextButton.styleFrom(foregroundColor: scheme.error,
                          padding: const EdgeInsets.symmetric(horizontal: 6))),
                Text(statusLabel(), style: TextStyle(fontSize: 11, color: _statusColor(scheme))),
                const SizedBox(width: 8),
                Icon(task.expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: scheme.outline),
              ]),
              const SizedBox(height: 8),
              if (task.status == TaskStatus.processing || task.status == TaskStatus.completed)
                ClipRRect(borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: task.progress / 100, minHeight: 4,
                        backgroundColor: scheme.surfaceContainerHighest)),
              const SizedBox(height: 4),
              Row(children: [
                _chip(Icons.timer_outlined, '${s.remaining}: ${task.remaining}', scheme),
                const SizedBox(width: 12), _chip(Icons.speed, task.speed, scheme),
                const Spacer(),
                Text('${task.progress.toStringAsFixed(0)}%', style: TextStyle(fontSize: 12, color: clr)),
              ]),
            ]),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: _expanded(context, s, clr, scheme),
          crossFadeState: task.expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 250),
        ),
      ]),
    );
  }

  Widget _expanded(BuildContext ctx, AppStrings s, Color clr, ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(),
      _row(s.qInput, task.inputPath, scheme.outline, clr),
      _row(s.qOutput, task.outputPath, scheme.outline, clr),
      _row('FPS', task.fps, scheme.outline, clr),
      _row('Bitrate', task.bitrate, scheme.outline, clr),
      _row('Size', task.outputSizeStr, scheme.outline, clr),
      if (task.command != null) ...[
        const SizedBox(height: 8),
        Text('${s.qCmd}:', style: TextStyle(fontSize: 11, color: scheme.outline)),
        Container(
          width: double.infinity, padding: const EdgeInsets.all(8), margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
          child: SelectableText(task.command!.join(' '),
              style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: clr)),
        ),
      ],
      if (task.logLines.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('${s.qLogs}:', style: TextStyle(fontSize: 11, color: scheme.outline)),
        Container(
          width: double.infinity, constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(8), margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
          child: SingleChildScrollView(
            child: SelectableText(task.logLines.join('\n'),
                style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: clr)),
          ),
        ),
      ],
      if (task.error != null)
        Padding(padding: const EdgeInsets.only(top: 8),
            child: SelectableText('${s.qError}: ${task.error}',
                style: TextStyle(color: scheme.error, fontSize: 11))),
    ]),
  );

  Widget _row(String l, String v, Color outline, Color clr) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(children: [
      SizedBox(width: 50, child: Text(l, style: TextStyle(fontSize: 11, color: outline))),
      Expanded(child: Text(v, style: TextStyle(fontSize: 11, color: clr),
          maxLines: 1, overflow: TextOverflow.ellipsis)),
    ]),
  );

  Widget _chip(IconData icon, String text, ColorScheme scheme) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 12, color: scheme.outline), const SizedBox(width: 3),
    Text(text, style: TextStyle(fontSize: 10, color: scheme.outline)),
  ]);

  IconData get _statusIcon => switch (task.status) {
    TaskStatus.pending => Icons.schedule, TaskStatus.processing => Icons.sync,
    TaskStatus.completed => Icons.check_circle, TaskStatus.failed => Icons.error,
    TaskStatus.cancelled => Icons.cancel,
  };

  Color _statusColor(ColorScheme sc) => switch (task.status) {
    TaskStatus.pending => sc.outline, TaskStatus.processing => sc.primary,
    TaskStatus.completed => Colors.green, TaskStatus.failed => sc.error,
    TaskStatus.cancelled => Colors.orange,
  };
}

// 缩略图（与 video_card 共用逻辑）
class _ThumbWidget extends StatefulWidget {
  final String filepath;
  const _ThumbWidget({required this.filepath});
  @override
  State<_ThumbWidget> createState() => _ThumbWidgetState();
}
class _ThumbWidgetState extends State<_ThumbWidget> {
  String? _path;
  @override
  void initState() { super.initState(); _gen(); }
  Future<void> _gen() async {
    final f = File('${Directory.systemTemp.path}/ffmpegpp_thumb_${widget.filepath.hashCode}_q.jpg');
    if (await f.exists()) { if (mounted) setState(() => _path = f.path); return; }
    try {
      final r = await Process.run('ffmpeg', ['-y', '-ss', '2', '-i', widget.filepath, '-vframes', '1', '-q:v', '5', '-s', '80x45', f.path]);
      if (r.exitCode == 0 && await f.exists()) { if (mounted) setState(() => _path = f.path); }
    } catch (_) {}
  }
  @override
  Widget build(BuildContext context) {
    if (_path != null) return Image.file(File(_path!), width: 40, height: 25, fit: BoxFit.cover);
    return const SizedBox(width: 40, height: 25);
  }
}
