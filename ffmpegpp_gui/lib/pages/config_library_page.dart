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
import '../widgets/toast.dart';
import '../widgets/glass_panel.dart';
import '../app.dart';
import 'pipeline_editor_page.dart';

const _uuid = Uuid();

class _ConfigEntry {
  final String id;
  String name;
  PipelineGraph graph;
  String description;
  DateTime updatedAt;

  _ConfigEntry({
    required this.id,
    required this.name,
    required this.graph,
    this.description = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'graph': graph.toJson(),
    'description': description,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory _ConfigEntry.fromJson(Map<String, dynamic> json) => _ConfigEntry(
    id: json['id'] as String? ?? _uuid.v4(),
    name: json['name'] as String? ?? '',
    graph: json['graph'] != null ? PipelineGraph.fromJson(json['graph'] as Map<String, dynamic>) : PipelineGraph(),
    description: json['description'] as String? ?? '',
    updatedAt: json['updated_at'] != null ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now() : DateTime.now(),
  );
}

class ConfigLibraryPage extends StatefulWidget {
  const ConfigLibraryPage({super.key});
  @override
  State<ConfigLibraryPage> createState() => _ConfigLibraryPageState();
}

class _ConfigLibraryPageState extends State<ConfigLibraryPage> {
  final List<_ConfigEntry> _configs = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final state = context.read<AppState>();
    final list = await state.configService.loadLibrary();
    if (!mounted) return;
    setState(() {
      _configs.clear();
      for (final json in list) {
        try { _configs.add(_ConfigEntry.fromJson(json)); } catch (_) {}
      }
      _loaded = true;
    });
  }

  Future<void> _saveLibrary() async {
    final state = context.read<AppState>();
    await state.configService.saveLibrary(_configs.map((e) => e.toJson()).toList());
  }

  void _newConfig() {
    final scheme = Theme.of(context).colorScheme;
    final zh = AppStrings.of(context.read<AppState>().config.language).isZh;
    final nameCtrl = TextEditingController(text: zh ? '新配置' : 'New Config');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.add_circle_outline, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Text(zh ? '新建配置' : 'New Config', style: TextStyle(color: scheme.onSurface)),
        ]),
        content: SizedBox(width: 360, child: TextField(
          controller: nameCtrl, autofocus: true,
          decoration: InputDecoration(
            labelText: zh ? '配置名称' : 'Config Name',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          style: TextStyle(fontSize: 14, color: scheme.onSurface),
          onSubmitted: (_) {
            Navigator.pop(ctx);
            _createEntry(nameCtrl.text, zh);
            nameCtrl.dispose();
          },
        )),
        actions: [
          TextButton(onPressed: () { Navigator.pop(ctx); nameCtrl.dispose(); },
              child: Text(zh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () {
            Navigator.pop(ctx);
            _createEntry(nameCtrl.text, zh);
            nameCtrl.dispose();
          }, child: Text(zh ? '创建' : 'Create')),
        ],
      ),
    );
  }

  void _createEntry(String rawName, bool zh) {
    final name = rawName.trim().isEmpty ? (zh ? '新配置' : 'New Config') : rawName.trim();
    final entry = _ConfigEntry(id: _uuid.v4(), name: name, graph: PipelineGraph());
    setState(() => _configs.add(entry));
    _saveLibrary();
    _openEditor(entry);
  }

  Future<void> _importFppx() async {
    final zh = AppStrings.of(context.read<AppState>().config.language).isZh;
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['fppx'],
      dialogTitle: zh ? '导入配置' : 'Import Config',
    );
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final bytes = await File(r.files.first.path!).readAsBytes();
    final fppx = FppxExporter.import(bytes);
    if (fppx == null || !fppx.isNodeEditor) {
      if (mounted) showToast(context, zh ? '仅支持导入节点编辑器配置' : 'Only node editor configs supported', type: ToastType.warning);
      return;
    }
    if (fppx.errors.isNotEmpty) {
      if (mounted) {
        showDialog(context: context, builder: (ctx) {
          final scheme = Theme.of(context).colorScheme;
          return AlertDialog(
            title: Row(children: [
              Icon(Icons.error_outline, size: 20, color: scheme.error),
              const SizedBox(width: 8),
              Text(zh ? '导入失败' : 'Import Failed', style: TextStyle(color: scheme.onSurface)),
            ]),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final e in fppx.errors) Padding(padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $e', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
            ]),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(zh ? '知道了' : 'OK'))],
          );
        });
      }
      return;
    }
    if (fppx.graph == null) {
      if (mounted) showToast(context, zh ? '配置解析失败' : 'Config parse failed', type: ToastType.warning);
      return;
    }
    if (fppx.warnings.isNotEmpty && mounted) {
      final scheme = Theme.of(context).colorScheme;
      final proceed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.warning_amber, size: 20, color: Colors.orange),
          const SizedBox(width: 8),
          Text(zh ? '版本警告' : 'Version Warning', style: TextStyle(color: scheme.onSurface)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final w in fppx.warnings) Padding(padding: const EdgeInsets.only(bottom: 4),
            child: Text('• $w', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
          const SizedBox(height: 8),
          Text(zh ? '是否继续导入？' : 'Continue importing?', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(zh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(zh ? '继续' : 'Continue')),
        ],
      ));
      if (proceed != true) return;
    }
    final baseName = r.files.first.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    final entry = _ConfigEntry(
      id: _uuid.v4(),
      name: baseName,
      graph: fppx.graph!,
      description: fppx.description,
    );
    setState(() => _configs.add(entry));
    _saveLibrary();
    if (mounted) showToast(context, zh ? '已导入: $baseName' : 'Imported: $baseName', type: ToastType.success);
  }

  void _openEditor(_ConfigEntry entry) {
    final dummyVideo = VideoFile(id: 'config_${entry.id}', filename: entry.name);
    Navigator.of(context).push(smoothRoute(
      PipelineEditorPage(
        video: dummyVideo.copyWith(pipelineGraph: entry.graph),
        onSave: (graph) {
          setState(() {
            entry.graph = graph;
            entry.updatedAt = DateTime.now();
          });
          _saveLibrary();
        },
      ),
    ));
  }

  void _renameEntry(_ConfigEntry entry) {
    final zh = AppStrings.of(context.read<AppState>().config.language).isZh;
    final scheme = Theme.of(context).colorScheme;
    final ctrl = TextEditingController(text: entry.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(zh ? '重命名' : 'Rename', style: TextStyle(color: scheme.onSurface)),
        content: TextField(
          controller: ctrl, autofocus: true,
          decoration: InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          style: TextStyle(fontSize: 14, color: scheme.onSurface),
          onSubmitted: (_) { Navigator.pop(ctx); _doRename(entry, ctrl.text, zh); ctrl.dispose(); },
        ),
        actions: [
          TextButton(onPressed: () { Navigator.pop(ctx); ctrl.dispose(); }, child: Text(zh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () { Navigator.pop(ctx); _doRename(entry, ctrl.text, zh); ctrl.dispose(); },
              child: Text(zh ? '确认' : 'Confirm')),
        ],
      ),
    );
  }

  void _doRename(_ConfigEntry entry, String rawName, bool zh) {
    final name = rawName.trim();
    if (name.isEmpty || name == entry.name) return;
    setState(() { entry.name = name; entry.updatedAt = DateTime.now(); });
    _saveLibrary();
  }

  void _duplicateEntry(_ConfigEntry entry) {
    final zh = AppStrings.of(context.read<AppState>().config.language).isZh;
    final copy = _ConfigEntry(
      id: _uuid.v4(),
      name: '${entry.name} ${zh ? '(副本)' : '(copy)'}',
      graph: entry.graph.copy(),
      description: entry.description,
    );
    setState(() => _configs.add(copy));
    _saveLibrary();
    showToast(context, zh ? '已复制' : 'Duplicated', type: ToastType.success);
  }

  Future<void> _exportEntry(_ConfigEntry entry) async {
    final zh = AppStrings.of(context.read<AppState>().config.language).isZh;
    final scheme = Theme.of(context).colorScheme;

    final errors = GraphExecutor.validateGraph(entry.graph);
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
    _saveLibrary();

    final result = await FilePicker.platform.saveFile(
      dialogTitle: zh ? '保存配置' : 'Save Config',
      fileName: '${entry.name}.fppx',
      type: FileType.custom, allowedExtensions: ['fppx'],
    );
    if (result == null) return;
    await File(result).writeAsBytes(FppxExporter.exportGraph(entry.graph, entry.description));
    if (mounted) showToast(context, zh ? '已导出: $result' : 'Exported: $result', type: ToastType.success);
  }

  void _deleteEntry(int index) {
    final zh = AppStrings.of(context.read<AppState>().config.language).isZh;
    final entry = _configs[index];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(zh ? '确认删除' : 'Confirm Delete'),
        content: Text(zh ? '确定要删除「${entry.name}」吗？' : 'Delete "${entry.name}"?',
            style: TextStyle(fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(zh ? '取消' : 'Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _configs.removeAt(index));
              _saveLibrary();
            },
            child: Text(zh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final zh = AppStrings.of(context.watch<AppState>().config.language).isZh;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        GlassTopBar(
          title: Text(zh ? '配置库' : 'Config Library'),
          actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined, size: 20),
            tooltip: zh ? '导入 .fppx' : 'Import .fppx',
            onPressed: _importFppx,
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: Text(zh ? '新建' : 'New'),
            onPressed: _newConfig,
          ),
        ],
      ),
      Expanded(
        child: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _configs.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.folder_open_outlined, size: 48, color: scheme.outline.withAlpha(80)),
                  const SizedBox(height: 12),
                  Text(zh ? '还没有配置' : 'No configs yet', style: TextStyle(color: scheme.outline, fontSize: 14)),
                  const SizedBox(height: 6),
                  Text(zh ? '点击「新建」创建节点编辑器配置模板' : 'Click "New" to create a node editor config',
                      style: TextStyle(color: scheme.outline.withAlpha(120), fontSize: 12)),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: Text(zh ? '或导入 .fppx 文件' : 'Or import .fppx file'),
                    onPressed: _importFppx,
                  ),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _configs.length,
                  itemBuilder: (_, i) => _buildCard(_configs[i], i, scheme, zh),
                ),
      ),
      ]),
    );
  }

  String _formatTime(DateTime dt, bool zh) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return zh ? '刚刚' : 'just now';
    if (diff.inHours < 1) return zh ? '${diff.inMinutes} 分钟前' : '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return zh ? '${diff.inHours} 小时前' : '${diff.inHours}h ago';
    if (diff.inDays < 30) return zh ? '${diff.inDays} 天前' : '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Widget _buildCard(_ConfigEntry entry, int index, ColorScheme scheme, bool zh) {
    final nodeCount = entry.graph.nodes.length;
    final connCount = entry.graph.connections.length;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openEditor(entry),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.account_tree, size: 20, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(entry.name, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: scheme.onSurface)),
              const SizedBox(height: 3),
              Row(children: [
                Icon(Icons.circle, size: 6, color: scheme.outline.withAlpha(100)),
                const SizedBox(width: 4),
                Text('$nodeCount ${zh ? '节点' : 'nodes'}', style: TextStyle(fontSize: 11, color: scheme.outline)),
                const SizedBox(width: 8),
                Icon(Icons.circle, size: 6, color: scheme.outline.withAlpha(100)),
                const SizedBox(width: 4),
                Text('$connCount ${zh ? '连线' : 'links'}', style: TextStyle(fontSize: 11, color: scheme.outline)),
                const SizedBox(width: 8),
                Icon(Icons.access_time, size: 11, color: scheme.outline.withAlpha(100)),
                const SizedBox(width: 3),
                Text(_formatTime(entry.updatedAt, zh), style: TextStyle(fontSize: 11, color: scheme.outline)),
              ]),
              if (entry.description.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(entry.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.outline.withAlpha(150))),
              ],
            ])),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 18, color: scheme.outline),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Row(children: [
                  Icon(Icons.edit_outlined, size: 16, color: scheme.onSurface),
                  const SizedBox(width: 8),
                  Text(zh ? '编辑' : 'Edit'),
                ])),
                PopupMenuItem(value: 'rename', child: Row(children: [
                  Icon(Icons.drive_file_rename_outline, size: 16, color: scheme.onSurface),
                  const SizedBox(width: 8),
                  Text(zh ? '重命名' : 'Rename'),
                ])),
                PopupMenuItem(value: 'duplicate', child: Row(children: [
                  Icon(Icons.copy_outlined, size: 16, color: scheme.onSurface),
                  const SizedBox(width: 8),
                  Text(zh ? '复制' : 'Duplicate'),
                ])),
                PopupMenuItem(value: 'export', child: Row(children: [
                  Icon(Icons.file_upload_outlined, size: 16, color: scheme.onSurface),
                  const SizedBox(width: 8),
                  Text(zh ? '导出' : 'Export'),
                ])),
                const PopupMenuDivider(),
                PopupMenuItem(value: 'delete', child: Row(children: [
                  Icon(Icons.delete_outline, size: 16, color: scheme.error),
                  const SizedBox(width: 8),
                  Text(zh ? '删除' : 'Delete', style: TextStyle(color: scheme.error)),
                ])),
              ],
              onSelected: (action) {
                switch (action) {
                  case 'edit': _openEditor(entry);
                  case 'rename': _renameEntry(entry);
                  case 'duplicate': _duplicateEntry(entry);
                  case 'export': _exportEntry(entry);
                  case 'delete': _deleteEntry(index);
                }
              },
            ),
          ]),
        ),
      ),
    );
  }
}
