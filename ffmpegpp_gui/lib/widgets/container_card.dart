import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../models/models.dart';
import '../pages/container_detail_page.dart';
import '../pages/pipeline_editor_page.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

class ContainerCard extends StatelessWidget {
  final FileContainer container;
  const ContainerCard({super.key, required this.container});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clr = scheme.onSurface;
    // 细粒度订阅：不 watch 整个 AppState。原先的 context.watch 让每张容器卡在
    // 每次进度心跳/日志通知（~3.3Hz）时全部重建，而紧邻的 video_card 用的是
    // 4 个 context.select —— 两者行为不一致，这里对齐。
    final s = AppStrings.of(context.select<AppState, String>((s) => s.config.language));
    // 本卡只展示「总大小 / 已解析数」两个聚合值，用记录作为 select 结果：
    // Dart record 是结构相等，只有这两个数真的变了才重建本卡。
    // 反查走 AppState.videoById（O(1)），替代原先的 O(items × videos) 嵌套扫描。
    final stats = context.select<AppState, ({double totalSize, int parsed})>((s) {
      var sizeSum = 0.0;
      var parsedSum = 0;
      for (final item in container.items) {
        final v = s.videoById(item.fileId);
        if (v == null) continue;
        sizeSum += v.sizeMb;
        if (v.parsed) parsedSum++;
      }
      return (totalSize: sizeSum, parsed: parsedSum);
    });
    final totalSize = stats.totalSize;
    final parsedCount = stats.parsed;
    // 仅供按钮回调使用（read 不建立订阅）
    final state = context.read<AppState>();

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
                maxLines: 1, overflow: TextOverflow.ellipsis,
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
    Navigator.of(context).push(smoothRoute(
      ContainerDetailPage(containerId: container.id),
    ));
  }

  void _editPipeline(BuildContext context, AppState state) {
    final files = container.items
        .map((item) => state.videoById(item.fileId))
        .whereType<VideoFile>()
        .toList();
    final firstParsed = files.where((v) => v.parsed).firstOrNull;
    if (firstParsed == null) return;
    final typeCounts = <MediaType, int>{};
    for (final f in files) {
      typeCounts[f.fileMediaType] = (typeCounts[f.fileMediaType] ?? 0) + 1;
    }
    Navigator.of(context).push(smoothRoute(
      PipelineEditorPage(
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
