import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../pages/container_detail_page.dart';
import '../pages/pipeline_editor_page.dart';

class ContainerCard extends StatelessWidget {
  final FileContainer container;
  const ContainerCard({super.key, required this.container});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clr = scheme.onSurface;
    final state = context.watch<AppState>();
    final s = AppStrings.of(state.config.language);
    final files = container.items.map((item) =>
        state.videos.where((v) => v.id == item.fileId).firstOrNull).whereType<VideoFile>().toList();
    final totalSize = files.fold(0.0, (sum, v) => sum + v.sizeMb);
    final parsedCount = files.where((v) => v.parsed).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withAlpha(80),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.folder_special, color: scheme.primary, size: 22),
              Text('${container.fileCount}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: scheme.primary)),
            ])),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(container.name, style: TextStyle(fontWeight: FontWeight.w600, color: clr), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text('${container.fileCount} ${s.containerFiles}  •  ${formatFileSize(totalSize)}  •  $parsedCount/${container.fileCount} ${s.isZh ? "已解析" : "parsed"}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ])),
          IconButton(icon: Icon(Icons.login, size: 20, color: scheme.primary), tooltip: s.containerEnter,
              onPressed: () => _enter(context, state)),
          IconButton(icon: Icon(Icons.edit_outlined, size: 20, color: clr), tooltip: s.edit,
              onPressed: parsedCount > 0 ? () => _editPipeline(context, state) : null),
          IconButton(icon: Icon(Icons.play_arrow, size: 20, color: parsedCount > 0 ? scheme.primary : scheme.outline),
              tooltip: s.containerQueueAll,
              onPressed: parsedCount > 0 ? () => state.addContainerTasks(container.id) : null),
          IconButton(icon: Icon(Icons.close, size: 18, color: clr), tooltip: s.remove,
              onPressed: () => state.removeContainer(container.id)),
        ]),
      ),
    );
  }

  void _enter(BuildContext context, AppState state) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ContainerDetailPage(containerId: container.id),
    ));
  }

  void _editPipeline(BuildContext context, AppState state) {
    final files = container.items.map((item) =>
        state.videos.where((v) => v.id == item.fileId).firstOrNull).whereType<VideoFile>().toList();
    final firstParsed = files.where((v) => v.parsed).firstOrNull;
    if (firstParsed == null) return;
    final typeCounts = <MediaType, int>{};
    for (final f in files) {
      typeCounts[f.fileMediaType] = (typeCounts[f.fileMediaType] ?? 0) + 1;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PipelineEditorPage(
        video: firstParsed,
        initialGraph: container.pipelineGraph,
        containerInfo: (name: container.name, fileCount: container.fileCount, typeCounts: typeCounts, fileIds: files.map((f) => f.id).toList()),
        onSave: (graph) {
          state.updateContainerPipeline(container.id, graph);
        },
      ),
    ));
  }
}
