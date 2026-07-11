import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../providers/app_state.dart';
import '../models/models.dart';
import '../services/config_export.dart';
import '../theme/app_strings.dart';
import '../widgets/video_card.dart';
import '../widgets/glass_panel.dart';
import '../widgets/toast.dart';

class ProjectPage extends StatefulWidget {
  const ProjectPage({super.key});
  @override
  State<ProjectPage> createState() => ProjectPageState();
}

class ProjectPageState extends State<ProjectPage> {
  static const _videoExts = ['mp4', 'avi', 'mkv', 'mov', 'flv', 'wmv', 'webm', 'm4v', 'mpg', 'mpeg', '3gp', 'ts', 'm2ts'];
  static const _audioExts = ['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'ac3'];
  static const _imageExts = ['png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff', 'tif'];
  static final _exts = [..._videoExts, ..._audioExts, ..._imageExts];

  String _searchQuery = '';
  bool _searchVisible = false;
  final Set<String> _selectedIds = {};
  bool _dragging = false;

  void selectAll(List videos) {
    setState(() {
      if (_selectedIds.length == videos.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(videos.map((v) => v.id));
      }
    });
  }

  void _onDrop(DropDoneDetails details) {
    setState(() => _dragging = false);
    final paths = details.files
        .map((f) => f.path)
        .where((p) {
          final ext = p.split('.').last.toLowerCase();
          return _exts.contains(ext);
        })
        .toList();
    if (paths.isNotEmpty) {
      context.read<AppState>().addVideos(paths);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clr = theme.colorScheme.outline;
    final scheme = theme.colorScheme;

    return Consumer<AppState>(
      builder: (context, state, _) {
        final s = AppStrings.of(state.config.language);

        // 搜索过滤
        final videos = _searchQuery.isEmpty
            ? state.videos
            : state.videos.where((v) => v.filename.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(children: [
            GlassTopBar(
              title: _searchVisible
                ? TextField(
                    autofocus: true,
                    style: TextStyle(fontSize: 14, color: scheme.onSurface),
                    decoration: InputDecoration(
                      hintText: s.searchVideos,
                      hintStyle: TextStyle(color: scheme.outline, fontSize: 14),
                      border: InputBorder.none,
                      prefixIcon: Icon(Icons.search, size: 18, color: scheme.outline),
                      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  )
                : Text(s.navProjects),
            actions: [
              IconButton(
                icon: Icon(_searchVisible ? Icons.close : Icons.search, size: 20),
                tooltip: _searchVisible ? s.close : s.search,
                onPressed: () => setState(() {
                  _searchVisible = !_searchVisible;
                  if (!_searchVisible) _searchQuery = '';
                }),
              ),
              if (state.videos.isNotEmpty)
                IconButton(
                  icon: Icon(
                    _selectedIds.length == state.videos.length ? Icons.deselect : Icons.select_all,
                    size: 20,
                  ),
                  tooltip: _selectedIds.isEmpty ? s.selectAll : s.deselectAll,
                  onPressed: () => setState(() {
                    if (_selectedIds.length == state.videos.length) {
                      _selectedIds.clear();
                    } else {
                      _selectedIds.addAll(state.videos.map((v) => v.id));
                    }
                  }),
                ),
              if (_selectedIds.isNotEmpty)
                IconButton(
                  icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
                  tooltip: s.deleteSelected,
                  onPressed: () => setState(() {
                    for (final id in _selectedIds) {
                      state.removeVideo(id);
                    }
                    _selectedIds.clear();
                  }),
                ),
              IconButton(
                icon: const Icon(Icons.file_download_outlined, size: 20),
                tooltip: s.isZh ? '导入配置' : 'Import Config',
                onPressed: state.videos.isEmpty ? null : () => _importConfig(state, s),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(s.addVideo),
                onPressed: () => _pick(state),
              ),
            ],
          ),
          Expanded(
            child: DropTarget(
              onDragDone: _onDrop,
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              child: _buildBody(context, state, videos, s, clr, scheme),
            ),
          ),
          ]),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppState state, List videos, AppStrings s, Color clr, ColorScheme scheme) {
    if (_dragging) {
      return Container(
        color: scheme.primary.withAlpha(30),
        child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_upload_outlined, size: 64, color: scheme.primary),
          const SizedBox(height: 16),
          Text(s.dropToAdd, style: TextStyle(fontSize: 18, color: scheme.primary, fontWeight: FontWeight.w600)),
        ])),
      );
    }

    if (state.videos.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.video_library_outlined, size: 64, color: clr),
        const SizedBox(height: 16),
        Text(s.noVideos, style: TextStyle(fontSize: 16, color: clr)),
        const SizedBox(height: 8),
        Text(s.clickAdd, style: TextStyle(fontSize: 13, color: clr)),
        const SizedBox(height: 8),
        Text(s.dragDropHint, style: TextStyle(fontSize: 12, color: clr.withAlpha(150))),
      ]));
    }

    if (videos.isEmpty && _searchQuery.isNotEmpty) {
      return Center(child: Text(s.noMatch, style: TextStyle(fontSize: 14, color: clr)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: videos.length,
      itemBuilder: (_, i) {
        final video = videos[i];
        final isSelected = _selectedIds.contains(video.id);
        return Row(children: [
          Checkbox(
            value: isSelected,
            onChanged: (v) => setState(() {
              if (v == true) { _selectedIds.add(video.id); }
              else { _selectedIds.remove(video.id); }
            }),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(child: VideoCard(video: video)),
        ]);
      },
    );
  }

  Future<void> _importConfig(AppState state, AppStrings s) async {
    final zh = s.isZh;
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['fppx'],
      dialogTitle: zh ? '选择配置文件' : 'Select Config File',
    );
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;

    final bytes = await File(r.files.first.path!).readAsBytes();
    final fppx = FppxExporter.import(bytes);

    if (fppx == null) {
      if (mounted) {
        showToast(context, zh ? '无法解析配置文件（格式错误）' : 'Cannot parse config file (invalid format)', type: ToastType.error);
      }
      return;
    }

    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final selectedVideos = <String>{};

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlgState) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Icon(Icons.file_download_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(zh ? '导入配置' : 'Import Config', style: TextStyle(color: scheme.onSurface)),
          ]),
          content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 兼容性错误
              if (fppx.errors.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.error_outline, size: 16, color: scheme.error),
                      const SizedBox(width: 6),
                      Text(zh ? '加载失败' : 'Load Failed',
                          style: TextStyle(fontSize: 13, color: scheme.error, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 6),
                    ...fppx.errors.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('• ', style: TextStyle(color: scheme.error)),
                        Expanded(child: Text(e, style: TextStyle(fontSize: 12, color: scheme.onErrorContainer))),
                      ]),
                    )),
                  ]),
                ),

              // 高版本警告
              if (fppx.warnings.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: Colors.orange.withAlpha(30), borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withAlpha(60))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                      const SizedBox(width: 6),
                      Text(zh ? '版本警告' : 'Version Warning',
                          style: const TextStyle(fontSize: 13, color: Colors.orange, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 6),
                    ...fppx.warnings.map((w) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text('• $w', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    )),
                  ]),
                ),

              // 信息
              _infoRow(scheme, zh ? '配置版本' : 'Config Version', fppx.configVersionStr),
              _infoRow(scheme, zh ? '兼容软件' : 'Compatible', fppx.softwareRangeStr),
              _infoRow(scheme, zh ? '模式' : 'Mode', fppx.isNodeEditor
                  ? (zh ? '节点编辑器' : 'Node Editor')
                  : (zh ? '传统模式' : 'Legacy')),
              if (fppx.graph != null)
                _infoRow(scheme, zh ? '内容' : 'Content',
                    '${fppx.graph!.nodes.length} ${zh ? '节点' : 'nodes'}, ${fppx.graph!.connections.length} ${zh ? '连线' : 'links'}'),
              _infoRow(scheme, zh ? '适用类型' : 'Media Type', fppx.detectedMediaLabel(zh)),

              // 介绍
              if (fppx.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(zh ? '介绍' : 'Description', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withAlpha(80),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(fppx.description, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
                ),
              ],

              // 选择视频
              const SizedBox(height: 16),
              Text(zh ? '应用到哪些文件？' : 'Apply to which files?',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              if (fppx.detectedMediaTypes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(
                    zh ? '仅显示与配置兼容的${fppx.detectedMediaLabel(zh)}文件' : 'Showing only compatible ${fppx.detectedMediaLabel(zh)} files',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ),
              const SizedBox(height: 8),
              ...state.videos.where((v) {
                if (!v.parsed) return false;
                final configTypes = fppx.detectedMediaTypes;
                if (configTypes.isEmpty) return true;
                return configTypes.contains(v.fileMediaType);
              }).map((v) => CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(v.filename, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
                subtitle: Text(v.resolution, style: TextStyle(fontSize: 11, color: scheme.outline)),
                value: selectedVideos.contains(v.id),
                onChanged: (checked) => setDlgState(() {
                  if (checked == true) { selectedVideos.add(v.id); } else { selectedVideos.remove(v.id); }
                }),
              )),
              if (state.videos.where((v) {
                if (!v.parsed) return false;
                final configTypes = fppx.detectedMediaTypes;
                if (configTypes.isEmpty) return true;
                return configTypes.contains(v.fileMediaType);
              }).isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(zh ? '没有兼容的文件' : 'No compatible files',
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
                ),
            ],
          ))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
            FilledButton(
              onPressed: (selectedVideos.isEmpty || !fppx.isCompatible) ? null : () {
                for (final vid in selectedVideos) {
                  if (fppx.graph != null) {
                    final graphCopy = fppx.graph!.copy();
                    final video = state.videos.firstWhere((v) => v.id == vid);
                    for (final n in graphCopy.nodes) {
                      if (n.type == PipelineStepType.start) {
                        n.params['file_media_type'] = video.fileMediaType.name;
                      }
                    }
                    state.updateVideoPipeline(vid, graphCopy);
                  }
                }
                Navigator.pop(ctx);
                showToast(context, zh ? '已应用到 ${selectedVideos.length} 个视频' : 'Applied to ${selectedVideos.length} videos', type: ToastType.success);
              },
              child: Text(zh ? '应用' : 'Apply'),
            ),
          ],
        );
      }),
    );
  }

  Widget _infoRow(ColorScheme scheme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        SizedBox(width: 90, child: Text(label, style: TextStyle(fontSize: 12, color: scheme.outline))),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurface)),
      ]),
    );
  }

  Future<void> _pick(AppState state) async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom, allowedExtensions: _exts);
    if (r != null && r.files.isNotEmpty) {
      final paths = r.files.where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isNotEmpty) state.addVideos(paths);
    }
  }
}
