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
import '../widgets/container_card.dart';
import '../widgets/glass_panel.dart';
import '../widgets/toast.dart';
import '../platform/app_platform.dart';
import '../services/quick_config_storage.dart';
import 'quick_config_page.dart';

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
  final Set<String> _selectedContainerIds = {};
  bool _dragging = false;
  /// 移动端多选模式：长按单个项目进入，选中项高亮（左侧不再常驻复选框）。
  bool _selectionMode = false;

  void _enterSelectionMode() {
    if (_selectionMode) return;
    setState(() => _selectionMode = true);
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
      _selectedContainerIds.clear();
    });
  }

  void _deleteSelected(AppState state) {
    setState(() {
      for (final id in _selectedIds) {
        state.removeVideo(id);
      }
      for (final id in _selectedContainerIds) {
        state.removeContainer(id);
      }
      _selectedIds.clear();
      _selectedContainerIds.clear();
      _selectionMode = false;
    });
  }

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
              title: (isMobilePlatform && _selectionMode)
                ? Text(
                    '${s.isZh ? '已选' : 'Selected'} ${_selectedIds.length + _selectedContainerIds.length} ${s.isZh ? '项' : 'items'}',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface),
                  )
                : _searchVisible
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
            actions: (isMobilePlatform && _selectionMode)
                ? [
                    IconButton(
                      icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
                      tooltip: s.deleteSelected,
                      onPressed: () => _deleteSelected(state),
                    ),
                    TextButton(
                      onPressed: _exitSelectionMode,
                      child: Text(s.isZh ? '取消' : 'Cancel',
                          style: TextStyle(fontSize: 14, color: scheme.primary, fontWeight: FontWeight.w600)),
                    ),
                  ]
                : [
              IconButton(
                icon: Icon(_searchVisible ? Icons.close : Icons.search, size: 20),
                tooltip: _searchVisible ? s.close : s.search,
                onPressed: () => setState(() {
                  _searchVisible = !_searchVisible;
                  if (!_searchVisible) _searchQuery = '';
                }),
              ),
              if (state.videos.isNotEmpty || state.containers.isNotEmpty)
                IconButton(
                  icon: Icon(
                    _selectedIds.length == state.videos.length && _selectedContainerIds.length == state.containers.length
                        ? Icons.deselect : Icons.select_all,
                    size: 20,
                  ),
                  tooltip: _selectedIds.isEmpty && _selectedContainerIds.isEmpty ? s.selectAll : s.deselectAll,
                  onPressed: () => setState(() {
                    if (isMobilePlatform) {
                      // 移动端：点击「全选」进入多选模式并全选（不显示常驻复选框）
                      _selectionMode = true;
                      _selectedIds.addAll(state.videos.map((v) => v.id));
                      _selectedContainerIds.addAll(state.containers.map((c) => c.id));
                    } else if (_selectedIds.length == state.videos.length && _selectedContainerIds.length == state.containers.length) {
                      _selectedIds.clear();
                      _selectedContainerIds.clear();
                    } else {
                      _selectedIds.addAll(state.videos.map((v) => v.id));
                      _selectedContainerIds.addAll(state.containers.map((c) => c.id));
                    }
                  }),
                ),
              if (!isMobilePlatform && (_selectedIds.isNotEmpty || _selectedContainerIds.isNotEmpty))
                IconButton(
                  icon: Icon(Icons.delete_outline, size: 20, color: scheme.error),
                  tooltip: s.deleteSelected,
                  onPressed: () => _deleteSelected(state),
                ),
              IconButton(
                icon: const Icon(Icons.file_download_outlined, size: 20),
                tooltip: s.isZh ? '导入配置' : 'Import Config',
                onPressed: state.videos.isEmpty ? null : () => _importConfig(state, s),
              ),
              // 圆形图标按钮：新建容器（主题色描边玻璃圆底）+ 添加文件（主色圆底），无文字
              if (state.config.editMode != 1) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: s.container,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => _showContainerMenu(context, state, s),
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withAlpha(160),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.primary.withAlpha(90), width: 1.2),
                      ),
                      child: Icon(Icons.create_new_folder_outlined, size: 18, color: scheme.primary),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 10),
              Tooltip(
                message: s.addVideo,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _pick(state),
                  child: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.primary.withAlpha(90), width: 1.2),
                      boxShadow: [BoxShadow(color: scheme.primary.withAlpha(90), blurRadius: 8, offset: const Offset(0, 2))],
                    ),
                    child: Icon(Icons.add, size: 24, color: scheme.onPrimary),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            // 移动端无桌面拖放能力，直接渲染内容
            child: isMobilePlatform
                ? _buildBody(context, state, videos, s, clr, scheme)
                : DropTarget(
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

    if (state.videos.isEmpty && state.containers.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.video_library_outlined, size: 64, color: clr),
        const SizedBox(height: 16),
        Text(s.noVideos, style: TextStyle(fontSize: 16, color: clr)),
        const SizedBox(height: 8),
        Text(s.clickAdd, style: TextStyle(fontSize: 13, color: clr)),
        if (!isMobilePlatform) ...[
          const SizedBox(height: 8),
          Text(s.dragDropHint, style: TextStyle(fontSize: 12, color: clr.withAlpha(150))),
        ],
      ]));
    }

    final standalone = state.standaloneVideos;
    final filteredStandalone = _searchQuery.isEmpty ? standalone
        : standalone.where((v) => v.filename.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    final containerCount = state.containers.length;
    final totalCount = containerCount + filteredStandalone.length;

    if (totalCount == 0 && _searchQuery.isNotEmpty) {
      return Center(child: Text(s.noMatch, style: TextStyle(fontSize: 14, color: clr)));
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, 16, 16, isMobilePlatform ? kMobileNavClearance : 16),
      itemCount: totalCount,
      itemBuilder: (_, i) {
        if (i < containerCount) {
          final c = state.containers[i];
          final isSelected = _selectedContainerIds.contains(c.id);
          if (!isMobilePlatform) {
            return Row(children: [
              Checkbox(
                value: isSelected,
                onChanged: (v) => setState(() {
                  if (v == true) { _selectedContainerIds.add(c.id); }
                  else { _selectedContainerIds.remove(c.id); }
                }),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(child: ContainerCard(container: c)),
            ]);
          }
          return _mobileSelectableItem(
            isSelected: isSelected,
            scheme: scheme,
            onLongPress: () {
              _enterSelectionMode();
              setState(() => _selectedContainerIds.add(c.id));
            },
            onTap: () {
              if (_selectionMode) {
                setState(() {
                  if (!_selectedContainerIds.remove(c.id)) _selectedContainerIds.add(c.id);
                });
              }
            },
            child: ContainerCard(container: c),
          );
        }
        final video = filteredStandalone[i - containerCount];
        final isSelected = _selectedIds.contains(video.id);
        if (!isMobilePlatform) {
          return Row(children: [
            Checkbox(
              value: isSelected,
              onChanged: (v) => setState(() {
                if (v == true) { _selectedIds.add(video.id); }
                else { _selectedIds.remove(video.id); }
              }),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: state.config.editMode == 1
                  ? GestureDetector(
                      onTap: () => _showQuickConfigDialog(context, state, video, s),
                      child: VideoCard(video: video, onEdit: () => _showQuickConfigDialog(context, state, video, s)),
                    )
                  : VideoCard(video: video),
            ),
          ]);
        }
        return _mobileSelectableItem(
          isSelected: isSelected,
          scheme: scheme,
          onLongPress: () {
            _enterSelectionMode();
            setState(() => _selectedIds.add(video.id));
          },
          onTap: () {
            if (_selectionMode) {
              setState(() {
                if (!_selectedIds.remove(video.id)) _selectedIds.add(video.id);
              });
            } else if (state.config.editMode == 1) {
              _showQuickConfigDialog(context, state, video, s);
            }
          },
          child: state.config.editMode == 1
              ? VideoCard(video: video, onEdit: () => _showQuickConfigDialog(context, state, video, s))
              : VideoCard(video: video),
        );
      },
    );
  }

  /// 移动端可多选条目：长按进入多选模式，选中项高亮（不显示常驻复选框）。
  Widget _mobileSelectableItem({
    required bool isSelected,
    required ColorScheme scheme,
    required Widget child,
    required VoidCallback onLongPress,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onLongPress: onLongPress,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected ? scheme.primaryContainer.withAlpha(80) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: child,
      ),
    );
  }

  Future<void> _importConfig(AppState state, AppStrings s) async {
    final zh = s.isZh;
    // Android 上 fppx 无 MIME 映射，FileType.custom 会失效。
    final r = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: zh ? '选择配置文件' : 'Select Config File',
    );
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final name = r.files.first.name;
    if (!name.endsWith('.fppx')) {
      if (mounted) showToast(context, zh ? '请选择 .fppx 文件' : 'Please select a .fppx file', type: ToastType.warning);
      return;
    }

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
    final r = await FilePicker.platform.pickFiles(
      allowMultiple: true, type: FileType.custom, allowedExtensions: _exts,
      withData: isMobilePlatform);
    if (r != null && r.files.isNotEmpty) {
      final paths = <String>[];
      for (final f in r.files) {
        // 保留扩展名，后续 addVideos 复制到应用私有目录时可正确识别媒体类型
        final ext = f.name.contains('.') ? f.name.substring(f.name.lastIndexOf('.')) : '';
        final stem = f.name.contains('.') ? f.name.substring(0, f.name.lastIndexOf('.')) : f.name;
        final isContentUri = f.path != null && f.path!.startsWith('content://');
        if (isContentUri && f.bytes != null) {
          // Android 11+: content:// URI 无法被 File/ffprobe 读取，用字节写入缓存
          try {
            final dest = File('${Directory.systemTemp.path}/ffmpegpp_import_${stem}_${DateTime.now().millisecondsSinceEpoch}$ext');
            await dest.writeAsBytes(f.bytes!);
            paths.add(dest.path);
          } catch (e) {
            // 如果字节写入也失败，仍尝试原始路径作为兜底
            if (f.path != null) paths.add(f.path!);
          }
        } else if (f.path != null) {
          paths.add(f.path!);
        } else if (f.bytes != null) {
          try {
            final dest = File('${Directory.systemTemp.path}/ffmpegpp_import_${stem}_${DateTime.now().millisecondsSinceEpoch}$ext');
            await dest.writeAsBytes(f.bytes!);
            paths.add(dest.path);
          } catch (_) {}
        }
      }
      if (paths.isNotEmpty) state.addVideos(paths);
    }
  }

  /// 快速模式：选择文件后弹出快速配置选择对话框
  Future<void> _showQuickConfigDialog(BuildContext context, AppState state, VideoFile video, AppStrings s) async {
    final zh = s.isZh;
    final fileType = _fileTypeForMediaType(video.fileMediaType);
    final configs = await QuickConfigStorage.loadAll(fileType);
    if (!context.mounted) return;
    final selected = await showDialog<QuickConfig>(
      context: context,
      builder: (ctx) => _QuickConfigPicker(
        configs: configs,
        fileType: fileType,
        scheme: Theme.of(context).colorScheme,
        isZh: zh,
      ),
    );
    if (selected == null || !context.mounted) return;
    final saved = await showDialog<QuickConfig>(
      context: context,
      barrierDismissible: false,
      builder: (_) => QuickConfigPage(
        config: selected,
        onSave: (updated) async {
          await QuickConfigStorage.save(updated);
        },
      ),
    );
    if (saved != null && context.mounted) {
      showToast(context, zh ? '配置已保存' : 'Config saved', type: ToastType.success);
    }
  }

  QuickFileType _fileTypeForMediaType(MediaType? mt) {
    if (mt == null) return QuickFileType.video;
    switch (mt) {
      case MediaType.image: return QuickFileType.image;
      case MediaType.audio: return QuickFileType.audio;
      default: return QuickFileType.video;
    }
  }

  void _showContainerMenu(BuildContext context, AppState state, AppStrings s) {
    final scheme = Theme.of(context).colorScheme;
    final zh = s.isZh;
    // 创建/重命名容器共用：弹出命名框
    Future<void> promptCreate(String defaultName, {bool empty = false}) async {
      final ctrl = TextEditingController(text: defaultName);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(zh ? '容器名称' : 'Container Name', style: TextStyle(color: scheme.onSurface)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: ''),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(zh ? '创建' : 'Create')),
          ],
        ),
      ).whenComplete(() => ctrl.dispose());
      if (name == null || name.isEmpty) return;
      if (empty) {
        state.addEmptyContainer(name);
      } else {
        final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom, allowedExtensions: _exts);
        if (r != null && r.files.isNotEmpty) {
          final paths = r.files.where((f) => f.path != null).map((f) => f.path!).toList();
          if (paths.isNotEmpty) state.addContainer(name, paths);
        }
      }
    }

    // 液态玻璃菜单
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassPanel(
            radius: 22,
            blur: 16,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(children: [
                Icon(Icons.create_new_folder_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(zh ? '新建容器' : 'New Container',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              ]),
            ),
            ListTile(
              leading: Icon(Icons.create_new_folder_outlined, color: scheme.primary),
              title: Text(zh ? '创建空容器' : 'Empty Container'),
              subtitle: Text(zh ? '先创建容器，稍后再添加文件（存于程序临时目录）' : 'Create an empty container, add files later',
                  style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                promptCreate(zh ? '新容器' : 'New Container', empty: true);
              },
            ),
            ListTile(
              leading: Icon(Icons.folder_open, color: scheme.primary),
              title: Text(s.containerFromFolder),
              subtitle: Text(zh ? '选择一个文件夹，其中的媒体文件将作为容器内容' : 'Select a folder, media files inside become container items',
                  style: const TextStyle(fontSize: 12)),
              onTap: () async {
                Navigator.pop(ctx);
                final dir = await FilePicker.platform.getDirectoryPath();
                if (dir != null) state.addContainerFromFolder(dir);
              },
            ),
            ListTile(
              leading: Icon(Icons.file_copy_outlined, color: scheme.primary),
              title: Text(s.containerFromFiles),
              subtitle: Text(zh ? '手动选择多个文件放入新容器' : 'Manually select files for a new container',
                  style: const TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                promptCreate(zh ? '新容器' : 'New Container');
              },
            ),
            const SizedBox(height: 6),
          ]),
          ),
        ),
      ),
    );
  }
}

/// 快速模式配置选择器对话框
class _QuickConfigPicker extends StatelessWidget {
  final List<QuickConfig> configs;
  final QuickFileType fileType;
  final ColorScheme scheme;
  final bool isZh;

  const _QuickConfigPicker({
    required this.configs,
    required this.fileType,
    required this.scheme,
    required this.isZh,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        Icon(Icons.tune, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Text(isZh ? '选择快速配置' : 'Select Quick Config',
            style: TextStyle(color: scheme.onSurface, fontSize: 16)),
      ]),
      content: SizedBox(
        width: 400,
        child: configs.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.inbox_outlined, size: 48, color: scheme.outlineVariant),
                  const SizedBox(height: 12),
                  Text(isZh ? '暂无匹配的快速配置' : 'No matching quick configs',
                      style: TextStyle(fontSize: 14, color: scheme.outline)),
                  const SizedBox(height: 4),
                  Text(isZh ? '请先在设置中创建快速配置' : 'Create one in Settings first',
                      style: TextStyle(fontSize: 12, color: scheme.outline.withAlpha(150))),
                ]),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: configs.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final cfg = configs[i];
                  return ListTile(
                    leading: _fileTypeIcon(cfg.fileType),
                    title: Text(cfg.name.isNotEmpty ? cfg.name : '(unnamed)',
                        style: TextStyle(fontSize: 14, color: scheme.onSurface, fontWeight: FontWeight.w500)),
                    subtitle: cfg.description.isNotEmpty
                        ? Text(cfg.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: scheme.outline))
                        : Text(
                            isZh ? '${cfg.items.where((i) => i.enabled).length} 项已启用' : '${cfg.items.where((i) => i.enabled).length} items enabled',
                            style: TextStyle(fontSize: 11, color: scheme.outline.withAlpha(150))),
                    trailing: Icon(Icons.chevron_right, size: 18, color: scheme.outline),
                    onTap: () => Navigator.pop(context, cfg),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isZh ? '取消' : 'Cancel'),
        ),
      ],
    );
  }

  Widget _fileTypeIcon(QuickFileType ft) {
    return Container(
      width: 32, height: 32,
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withAlpha(120),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        switch (ft) {
          QuickFileType.video => Icons.videocam_outlined,
          QuickFileType.image => Icons.image_outlined,
          QuickFileType.audio => Icons.audiotrack_outlined,
        },
        size: 16, color: scheme.primary,
      ),
    );
  }
}
