import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/task_card.dart';

class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer<AppState>(
      builder: (context, state, _) {
        final s = AppStrings.of(state.config.language);
        return Scaffold(
          appBar: AppBar(
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
                if (state.tasks.any((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed))
                  TextButton.icon(
                      icon: const Icon(Icons.cleaning_services_outlined, size: 16), label: Text(s.clearCompleted),
                      onPressed: () => state.clearCompletedTasks()),
              ],
              const SizedBox(width: 12),
            ],
          ),
          body: state.tasks.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.inbox_outlined, size: 64, color: theme.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(s.emptyQueue, style: TextStyle(fontSize: 16, color: theme.colorScheme.outline)),
                  const SizedBox(height: 8),
                  Text(s.emptyQueueHint, style: TextStyle(fontSize: 13, color: theme.colorScheme.outline)),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(16), itemCount: state.tasks.length,
                  itemBuilder: (_, i) => TaskCard(task: state.tasks[i]),
                ),
        );
      },
    );
  }
}
