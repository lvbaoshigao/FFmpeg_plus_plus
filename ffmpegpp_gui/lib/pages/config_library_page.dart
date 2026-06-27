import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/config_export.dart';
import '../services/graph_executor.dart';
import '../theme/app_strings.dart';
import 'pipeline_editor_page.dart';

const _uuid = Uuid();

class ConfigEntry {
  final String id;
  final String name;
  final int mode;
  PipelineGraph? graph;
  TranscodeConfig? config;
  String description;

  ConfigEntry({required this.id, required this.name, required this.mode,
    this.graph, this.config, this.description = ''});
}

class ConfigLibraryPage extends StatefulWidget {
  const ConfigLibraryPage({super.key});
  @override
  State<ConfigLibraryPage> createState() => _ConfigLibraryPageState();
}

class _ConfigLibraryPageState extends State<ConfigLibraryPage> {
  final List<ConfigEntry> _configs = [];

  void _newConfig() {
    final scheme = Theme.of(context).colorScheme;
    final zh = AppStrings.of(context.read<AppState>().config.language).isZh;

    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: zh ? '新配置' : 'New Config');
        int selectedMode = modeNodeEditor;
        return StatefulBuilder(builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Icon(Icons.add_circle_outline, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(zh ? '新建配置' : 'New Config', style: TextStyle(color: scheme.onSurface)),
          ]),
          content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: zh ? '配置名称' : 'Config Name',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              style: TextStyle(fontSize: 14, color: scheme.onSurface),
            ),
            const SizedBox(height: 16),
            Text(zh ? '选择编辑模式' : 'Choose Edit Mode',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
            const SizedBox(height: 8),
            RadioListTile<int>(
              title: Text(zh ? '节点编辑器' : 'Node Editor', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
              subtitle: Text(zh ? '蓝图式画布，适合复杂流程' : 'Blueprint canvas for complex workflows',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
              value: modeNodeEditor,
              groupValue: selectedMode,
              onChanged: (v) => setDlgState(() => selectedMode = v!),
              dense: true,
            ),
            RadioListTile<int>(
              title: Text(zh ? '传统模式' : 'Legacy Mode', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
              subtitle: Text(zh ? '简单配置表单，适合快速操作' : 'Simple form for quick tasks',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
              value: modeLegacy,
              groupValue: selectedMode,
              onChanged: (v) => setDlgState(() => selectedMode = v!),
              dense: true,
            ),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(zh ? '取消' : 'Cancel')),
            FilledButton(onPressed: () {
              Navigator.pop(ctx);
              final entry = ConfigEntry(
                id: _uuid.v4(), name: nameCtrl.text.trim().isEmpty ? (zh ? '新配置' : 'New Config') : nameCtrl.text.trim(),
                mode: selectedMode,
                graph: selectedMode == modeNodeEditor ? PipelineGraph() : null,
                config: selectedMode == modeLegacy ? TranscodeConfig() : null,
              );
              nameCtrl.dispose();
              setState(() => _configs.add(entry));
              _openEditor(entry);
            }, child: Text(zh ? '创建' : 'Create')),
          ],
        ));
      },
    );
  }

  void _openEditor(ConfigEntry entry) {
    if (entry.mode == modeNodeEditor) {
      final dummyVideo = VideoFile(id: 'config_${entry.id}', filename: entry.name);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PipelineEditorPage(
          video: dummyVideo.copyWith(pipelineGraph: entry.graph),
          onSave: (graph) {
            setState(() => entry.graph = graph);
          },
        ),
      ));
    }
  }

  Future<void> _exportEntry(ConfigEntry entry) async {
    final s = AppStrings.of(context.read<AppState>().config.language);
    final zh = s.isZh;
    final scheme = Theme.of(context).colorScheme;

    if (entry.mode == modeNodeEditor && entry.graph != null) {
      final errors = GraphExecutor.validateGraph(entry.graph!);
      if (errors.isNotEmpty) {
        showDialog(context: context, builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Icon(Icons.error_outline, size: 20, color: scheme.error),
            const SizedBox(width: 8),
            Text(zh ? '无法导出' : 'Cannot Export'),
          ]),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(zh ? '配置存在逻辑错误：' : 'Config has errors:', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            ...errors.map((e) => Padding(padding: const EdgeInsets.only(bottom: 3), child: Row(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('• ', style: TextStyle(color: scheme.error)),
                Expanded(child: Text(e, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
              ],
            ))),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(zh ? '知道了' : 'OK'))],
        ));
        return;
      }
    }

    final descCtrl = TextEditingController(text: entry.description);
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(zh ? '导出配置' : 'Export Config'),
      content: SizedBox(width: 380, child: TextField(
        controller: descCtrl, maxLines: 3,
        decoration: InputDecoration(
          labelText: zh ? '介绍（可选）' : 'Description',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(zh ? '取消' : 'Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(zh ? '导出' : 'Export')),
      ],
    ));
    if (confirmed != true) { descCtrl.dispose(); return; }

    entry.description = descCtrl.text;
    descCtrl.dispose();

    final result = await FilePicker.platform.saveFile(
      dialogTitle: zh ? '保存配置' : 'Save Config',
      fileName: '${entry.name}.fppx',
      type: FileType.custom, allowedExtensions: ['fppx'],
    );
    if (result == null) return;

    final bytes = entry.mode == modeNodeEditor
        ? FppxExporter.exportGraph(entry.graph!, entry.description)
        : FppxExporter.exportLegacy(entry.config!, entry.description);
    await File(result).writeAsBytes(bytes);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(zh ? '已导出: $result' : 'Exported: $result'), backgroundColor: Colors.green));
    }
  }

  void _deleteEntry(int index) {
    setState(() => _configs.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final zh = AppStrings.of(context.watch<AppState>().config.language).isZh;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(zh ? '配置库' : 'Config Library'),
        actions: [
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: Text(zh ? '新建' : 'New'),
            onPressed: _newConfig,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _configs.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.folder_open_outlined, size: 48, color: scheme.outline.withAlpha(80)),
              const SizedBox(height: 12),
              Text(zh ? '还没有配置' : 'No configs yet', style: TextStyle(color: scheme.outline, fontSize: 14)),
              const SizedBox(height: 6),
              Text(zh ? '点击右上角「新建」创建配置模板' : 'Click "New" to create a config template',
                  style: TextStyle(color: scheme.outline.withAlpha(120), fontSize: 12)),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _configs.length,
              itemBuilder: (_, i) => _buildCard(_configs[i], i, scheme, zh),
            ),
    );
  }

  Widget _buildCard(ConfigEntry entry, int index, ColorScheme scheme, bool zh) {
    final isNode = entry.mode == modeNodeEditor;
    final nodeCount = isNode ? (entry.graph?.nodes.length ?? 0) : 0;
    final connCount = isNode ? (entry.graph?.connections.length ?? 0) : 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: isNode ? scheme.primaryContainer : scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(isNode ? Icons.account_tree : Icons.tune,
                size: 20, color: isNode ? scheme.onPrimaryContainer : scheme.onTertiaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.name, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: scheme.onSurface)),
            const SizedBox(height: 2),
            Text(
              isNode
                  ? '${zh ? '节点' : 'Node'} • $nodeCount ${zh ? '节点' : 'nodes'} • $connCount ${zh ? '连线' : 'links'}'
                  : (zh ? '传统模式' : 'Legacy mode'),
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ])),
          IconButton(icon: const Icon(Icons.edit_outlined, size: 18), tooltip: zh ? '编辑' : 'Edit',
              onPressed: () => _openEditor(entry)),
          IconButton(icon: const Icon(Icons.file_upload_outlined, size: 18), tooltip: zh ? '导出' : 'Export',
              onPressed: () => _exportEntry(entry)),
          IconButton(icon: Icon(Icons.delete_outline, size: 18, color: scheme.error), tooltip: zh ? '删除' : 'Delete',
              onPressed: () => _deleteEntry(index)),
        ]),
      ),
    );
  }
}
