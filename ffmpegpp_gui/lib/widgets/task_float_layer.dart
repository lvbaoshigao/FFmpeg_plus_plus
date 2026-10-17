import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import 'glass_panel.dart';

/// The first Unicode letter or number in a filename, ignoring symbols.
String taskDockInitial(String filename) {
  final match = RegExp(r'[\p{L}\p{N}]', unicode: true).firstMatch(filename);
  return match?.group(0)?.toUpperCase() ?? '?';
}

/// Global desktop task overlays, mounted last in a bounded shell [Stack].
///
/// Use Positioned.fill(child: TaskFloatLayer()) below the AppState provider.
/// Keep this widget mounted across page changes so hidden/minimized state lasts.
/// Only cards and dock buttons hit-test; the rest of the shell stays interactive.
class TaskFloatLayer extends StatefulWidget {
  const TaskFloatLayer({super.key});

  @override
  State<TaskFloatLayer> createState() => _TaskFloatLayerState();
}

class _TaskFloatLayerState extends State<TaskFloatLayer> {
  final Map<String, Offset> _positions = {};
  final Set<String> _minimized = {};
  final Set<String> _hidden = {};
  final List<String> _order = [];

  Offset _clamp(Offset position, Size bounds, Size card) => Offset(
    position.dx.clamp(0.0, math.max(0.0, bounds.width - card.width)),
    position.dy.clamp(0.0, math.max(0.0, bounds.height - card.height)),
  );

  void _raise(String id) {
    _order.remove(id);
    _order.add(id);
  }

  @override
  Widget build(BuildContext context) {
    if (isMobilePlatform) return const SizedBox.shrink();
    return Selector<AppState, (int, String)>(
      selector: (_, state) => (state.tasksVersion, state.config.language),
      builder: (context, _, _) {
        final state = context.read<AppState>();
        final tasks = {
          for (final task in state.tasks)
            if (task.status == TaskStatus.pending ||
                task.status == TaskStatus.processing)
              task.id: task,
        };
        // Terminal tasks leave immediately; a later retry starts a fresh overlay.
        _positions.removeWhere((id, _) => !tasks.containsKey(id));
        _hidden.removeWhere((id) => !tasks.containsKey(id));
        _minimized.removeWhere((id) => !tasks.containsKey(id));
        _order.removeWhere((id) => !tasks.containsKey(id));
        for (final id in tasks.keys) {
          if (!_order.contains(id)) {
            _order.add(id);
          }
        }
        final s = AppStrings.of(state.config.language);
        return LayoutBuilder(
          builder: (context, constraints) {
            final bounds = constraints.biggest;
            if (!bounds.isFinite || bounds.isEmpty) {
              return const SizedBox.shrink();
            }
            final width = math.min(320.0, bounds.width);
            final height = math.min(204.0, bounds.height);
            final cardSize = Size(width, height);
            final dock = _order
                .where((id) => _minimized.contains(id) && !_hidden.contains(id))
                .toList();
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (final id in _order.where(
                  (id) => !_hidden.contains(id) && !_minimized.contains(id),
                ))
                  _positionedCard(tasks[id]!, bounds, cardSize, s),
                if (dock.isNotEmpty)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(0, bounds.width - 24),
                        maxHeight: math.max(0, bounds.height - 24),
                      ),
                      child: SingleChildScrollView(
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final id in dock)
                              GlassPanel(
                                radius: 28,
                                child: SizedBox.square(
                                  dimension: 52,
                                  child: IconButton(
                                    key: ValueKey('task-dock-$id'),
                                    tooltip:
                                        '${s.isZh ? '恢复任务' : 'Restore task'}: ${tasks[id]!.filename}',
                                    onPressed: () => setState(() {
                                      _minimized.remove(id);
                                      _raise(id);
                                    }),
                                    icon: Text(
                                      taskDockInitial(tasks[id]!.filename),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 20,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _positionedCard(TaskInfo task, Size bounds, Size size, AppStrings s) {
    final index = _order.indexOf(task.id);
    final position = _clamp(
      _positions[task.id] ??
          Offset(
            bounds.width - size.width - 20 - (index % 5) * 24,
            // 停靠右下角：给底部的「最小化圆圈」坞留出 76px（52px 圆圈 + 12px 间隙 + 12px 外沿）。
            bounds.height - size.height - 76 - (index % 5) * 24,
          ),
      bounds,
      size,
    );
    // Store the clamped value too: dragging after resize must not jump offscreen.
    _positions[task.id] = position;
    void move(Offset delta) => setState(() {
      _positions[task.id] = _clamp(
        (_positions[task.id] ?? position) + delta,
        bounds,
        size,
      );
      _raise(task.id);
    });
    final pending = task.status == TaskStatus.pending;
    final progress = task.progress.isFinite
        ? (task.progress / 100).clamp(0.0, 1.0)
        : 0.0;
    final scheme = Theme.of(context).colorScheme;
    final calls = task.pipelineCalls?.length ?? 0;
    return Positioned(
      key: ValueKey('task-float-position-${task.id}'),
      left: position.dx,
      top: position.dy,
      width: size.width,
      height: size.height,
      child: Listener(
        onPointerDown: (_) => setState(() => _raise(task.id)),
        child: GlassPanel(
          radius: 18,
          child: Material(
            type: MaterialType.transparency,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: scheme.primary.withAlpha(28),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.movie_outlined,
                            size: 16,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(
                                LogicalKeyboardKey.arrowLeft,
                              ): () =>
                                  move(const Offset(-20, 0)),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowRight,
                              ): () =>
                                  move(const Offset(20, 0)),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowUp,
                              ): () =>
                                  move(const Offset(0, -20)),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowDown,
                              ): () =>
                                  move(const Offset(0, 20)),
                            },
                            child: Focus(
                              child: Semantics(
                                label: s.isZh
                                    ? '拖动任务，方向键移动'
                                    : 'Drag task; arrow keys move',
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.move,
                                  child: GestureDetector(
                                    key: ValueKey('task-drag-${task.id}'),
                                    onPanUpdate: (event) => move(event.delta),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        task.filename,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          key: ValueKey('task-minimize-${task.id}'),
                          tooltip: s.isZh ? '最小化任务' : 'Minimize task',
                          onPressed: () =>
                              setState(() => _minimized.add(task.id)),
                          icon: const Icon(Icons.minimize, size: 18),
                        ),
                        IconButton(
                          key: ValueKey('task-hide-${task.id}'),
                          tooltip: s.isZh
                              ? '隐藏悬浮卡片（任务继续）'
                              : 'Hide overlay (task continues)',
                          onPressed: () => setState(() {
                            _hidden.add(task.id);
                            _minimized.remove(task.id);
                          }),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    Text(
                      '${pending ? s.pending : s.processing} · ${s.qElapsed}: ${task.elapsed.isEmpty ? '—' : task.elapsed}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Determinate updates avoid perpetual motion and respect reduced motion.
                    LinearProgressIndicator(
                      value: progress,
                      semanticsLabel: task.filename,
                      semanticsValue: '${(progress * 100).round()}%',
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            calls > 0
                                ? '${s.isZh ? '步骤' : 'Step'} ${(task.currentCallIndex + 1).clamp(1, calls)}/$calls'
                                : (pending ? s.pending : s.processing),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        Text('${(progress * 100).round()}%'),
                        IconButton(
                          tooltip: s.isZh ? '停止任务' : 'Stop task',
                          onPressed: () =>
                              context.read<AppState>().cancelTask(task.id),
                          icon: Icon(
                            Icons.stop_circle_outlined,
                            color: scheme.error,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
