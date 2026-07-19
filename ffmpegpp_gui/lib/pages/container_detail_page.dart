import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:window_manager/window_manager.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import 'pipeline_editor_page.dart';
import '../app.dart';

class ContainerDetailPage extends StatefulWidget {
  final String containerId;
  const ContainerDetailPage({super.key, required this.containerId});
  @override
  State<ContainerDetailPage> createState() => _ContainerDetailPageState();
}

class _ContainerDetailPageState extends State<ContainerDetailPage> with WindowListener {
  int? _editingIndex;
  final _indexCtrl = TextEditingController();
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) { if (mounted) setState(() => _isMaximized = v); });
  }

  @override
  void dispose() {
    _indexCtrl.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() { if (mounted) setState(() => _isMaximized = true); }
  @override
  void onWindowUnmaximize() { if (mounted) setState(() => _isMaximized = false); }

  FileContainer? _container(AppState state) =>
      state.containers.where((c) => c.id == widget.containerId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = AppStrings.of(state.config.language);
    final scheme = Theme.of(context).colorScheme;
    final container = _container(state);
    if (container == null) {
      return Scaffold(body: Center(child: Text(s.isZh ? '容器不存在' : 'Container not found')));
    }

    final items = container.sortedItems;
    final files = container.items.map((item) =>
        state.videos.where((v) => v.id == item.fileId).firstOrNull).whereType<VideoFile>().toList();
    final hasParsed = files.any((v) => v.parsed);

    final listWidget = items.isEmpty
        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.folder_open, size: 48, color: scheme.outline.withAlpha(80)),
            const SizedBox(height: 8),
            Text(s.isZh ? '容器为空，点击 + 添加文件' : 'Empty container, tap + to add files',
                style: TextStyle(color: scheme.outline, fontSize: 13)),
          ]))
        : ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: items.length,
            itemBuilder: (ctx, i) {
              final item = items[i];
              final video = state.videos.where((v) => v.id == item.fileId).firstOrNull;
              if (video == null) return const SizedBox.shrink();
              return _buildItem(state, s, scheme, container, item, video);
            },
          );

    // 工具栏按钮
    final toolbarActions = <Widget>[
      IconButton(icon: const Icon(Icons.edit_note, size: 20),
          tooltip: s.isZh ? '编辑节点图' : 'Edit Pipeline',
          onPressed: hasParsed ? () => _editPipeline(state, container) : null),
      IconButton(icon: const Icon(Icons.drive_file_rename_outline, size: 20),
          tooltip: s.isZh ? '重命名' : 'Rename',
          onPressed: () => _rename(state, container, s)),
      IconButton(icon: const Icon(Icons.add, size: 20),
          tooltip: s.containerAddFiles,
          onPressed: () => _addFiles(state)),
      PopupMenuButton<ContainerSortMode>(
        icon: const Icon(Icons.sort, size: 20),
        tooltip: s.isZh ? '排序' : 'Sort',
        onSelected: (mode) => state.sortContainerBy(container.id, mode),
        itemBuilder: (_) => [
          PopupMenuItem(value: ContainerSortMode.name, child: Text(s.containerSortName)),
          PopupMenuItem(value: ContainerSortMode.size, child: Text(s.containerSortSize)),
          PopupMenuItem(value: ContainerSortMode.duration, child: Text(s.containerSortDuration)),
        ],
      ),
      const SizedBox(width: 8),
    ];

    final content = Column(children: [
      // 工具栏
      Padding(
        padding: EdgeInsets.fromLTRB(8, Platform.isWindows ? 4 : 40, 8, 2),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back, size: 20), onPressed: () => Navigator.pop(context)),
          const SizedBox(width: 4),
          GestureDetector(
            onDoubleTap: () => _rename(state, container, s),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.folder_special, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(container.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              Text('  (${container.fileCount})', style: TextStyle(fontSize: 12, color: scheme.outline)),
            ]),
          ),
          const Spacer(),
          ...toolbarActions,
        ]),
      ),
      Expanded(child: listWidget),
    ]);

    Widget page = _withWallpaper(context, Scaffold(
      backgroundColor: Colors.transparent,
      body: content,
    ));

    if (!Platform.isWindows) {
      page = Stack(children: [
        page,
        Positioned(left: 0, right: 0, top: 0, child: _buildCsdTitleBar(scheme)),
      ]);
    }
    return page;
  }

  Widget _buildItem(AppState state, AppStrings s, ColorScheme scheme,
      FileContainer container, ContainerItem item, VideoFile video) {
    final clr = scheme.onSurface;
    final isEditing = _editingIndex == item.index;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          // 编号
          GestureDetector(
            onDoubleTap: () => setState(() { _editingIndex = item.index; _indexCtrl.text = '${item.index}'; }),
            child: isEditing
                ? SizedBox(width: 40, child: TextField(
                    controller: _indexCtrl, autofocus: true, textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: scheme.primary),
                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 6), border: OutlineInputBorder()),
                    onSubmitted: (v) {
                      final newIdx = int.tryParse(v);
                      if (newIdx != null && newIdx > 0) state.updateContainerItemIndex(container.id, item.fileId, newIdx);
                      setState(() => _editingIndex = null);
                    },
                  ))
                : Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(color: scheme.primaryContainer.withAlpha(80), borderRadius: BorderRadius.circular(6)),
                    child: Center(child: Text('${item.index}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.primary))),
                  ),
          ),
          const SizedBox(width: 8),
          // 缩略图
          ClipRRect(borderRadius: BorderRadius.circular(4),
            child: _Thumb(filepath: video.filepath, isAudio: video.fileMediaType == MediaType.audio)),
          const SizedBox(width: 8),
          // 文件信息
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(video.filename, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: clr), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (video.parsed)
              Text('${video.resolution != "N/A" ? "${video.resolution}  •  " : ""}${video.durationStr}  •  ${formatFileSize(video.sizeMb)}',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))
            else
              Text(s.probing, style: TextStyle(fontSize: 11, color: scheme.outline)),
          ])),
          // 仅删除按钮
          IconButton(icon: Icon(Icons.arrow_upward, size: 16, color: scheme.outline), tooltip: s.isZh ? '上移' : 'Move Up',
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: item.index > 1 ? () => _swapItems(state, container, item.index, item.index - 1) : null),
          IconButton(icon: Icon(Icons.arrow_downward, size: 16, color: scheme.outline), tooltip: s.isZh ? '下移' : 'Move Down',
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: item.index < container.items.length ? () => _swapItems(state, container, item.index, item.index + 1) : null),
          IconButton(icon: Icon(Icons.close, size: 16, color: scheme.error), tooltip: s.remove,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => state.removeFileFromContainer(container.id, item.fileId)),
        ]),
      ),
    );
  }

  void _swapItems(AppState state, FileContainer container, int idxA, int idxB) {
    state.swapContainerItems(container.id, idxA, idxB);
  }

  void _rename(AppState state, FileContainer container, AppStrings s) {
    final ctrl = TextEditingController(text: container.name);
    showDialog(context: context, builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: Text(s.isZh ? '重命名容器' : 'Rename Container', style: TextStyle(color: cs.onSurface)),
        content: TextField(
          controller: ctrl, autofocus: true,
          style: TextStyle(color: cs.onSurface),
          decoration: InputDecoration(
            hintText: s.isZh ? '容器名称' : 'Container name',
            hintStyle: TextStyle(color: cs.outline),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: Text(s.isZh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () {
            if (ctrl.text.trim().isNotEmpty) {
              state.renameContainer(container.id, ctrl.text.trim());
            }
            Navigator.pop(ctx);
          }, child: Text(s.isZh ? '确定' : 'OK')),
        ],
      );
    }).then((_) => ctrl.dispose());
  }

  void _editPipeline(AppState state, FileContainer container) {
    final files = container.items.map((item) =>
        state.videos.where((v) => v.id == item.fileId).firstOrNull).whereType<VideoFile>().toList();
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
        onSave: (graph) => state.updateContainerPipeline(container.id, graph),
      ),
    ));
  }

  Widget _withWallpaper(BuildContext context, Widget child) {
    final cfg = context.watch<AppState>().config;
    final bg = cfg.backgroundImage;
    if (bg.isEmpty || !File(bg).existsSync()) return child;
    final scheme = Theme.of(context).colorScheme;
    final a = ((1.0 - cfg.backgroundOpacity) * 220).round().clamp(20, 240);
    return Stack(children: [
      Positioned.fill(child: Image.file(File(bg), fit: BoxFit.cover)),
      Positioned.fill(child: Container(color: scheme.surface.withAlpha(a))),
      Theme(data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: Colors.transparent,
      ), child: child),
    ]);
  }

  Widget _buildCsdTitleBar(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [
              scheme.surface.withAlpha(isDark ? 160 : 180),
              scheme.surface.withAlpha(isDark ? 120 : 140),
            ]),
            border: Border(bottom: BorderSide(color: scheme.outlineVariant.withAlpha(isDark ? 60 : 80), width: 0.5)),
          ),
          child: Stack(children: [
            DragToMoveArea(child: GestureDetector(
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) { windowManager.unmaximize(); }
                else { windowManager.maximize(); }
              },
              child: Container(color: Colors.transparent),
            )),
            Positioned(right: 0, top: 0, bottom: 0, child: Row(mainAxisSize: MainAxisSize.min, children: [
              _CsdBtn(icon: Icons.remove, color: scheme.onSurfaceVariant, onTap: () => windowManager.minimize()),
              _CsdBtn(
                icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
                color: scheme.onSurfaceVariant,
                onTap: () async {
                  if (await windowManager.isMaximized()) { windowManager.unmaximize(); }
                  else { windowManager.maximize(); }
                },
              ),
              _CsdBtn(icon: Icons.close, color: scheme.onSurface, hoverBg: Colors.red, onTap: () => windowManager.close()),
            ])),
          ]),
        ),
      ),
    );
  }

  Future<void> _addFiles(AppState state) async {
    final r = await FilePicker.platform.pickFiles(
        allowMultiple: true, type: FileType.custom,
        allowedExtensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'flv', 'wmv', 'ts', 'mpg', 'mpeg', 'm4v', '3gp',
          'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'ac3',
          'png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff', 'tif']);
    if (r != null && r.files.isNotEmpty) {
      final paths = r.files.where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isNotEmpty) state.addFilesToContainer(widget.containerId, paths);
    }
  }
}

class _CsdBtn extends StatefulWidget {
  final IconData icon;
  final Color color;
  final Color? hoverBg;
  final VoidCallback onTap;
  const _CsdBtn({required this.icon, required this.color, this.hoverBg, required this.onTap});
  @override
  State<_CsdBtn> createState() => _CsdBtnState();
}

class _CsdBtnState extends State<_CsdBtn> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46, height: 36,
          color: _hovering ? (widget.hoverBg?.withAlpha(200) ?? widget.color.withAlpha(30)) : Colors.transparent,
          child: Center(child: Icon(widget.icon, size: 16, color: _hovering && widget.hoverBg != null ? Colors.white : widget.color)),
        ),
      ),
    );
  }
}

class _Thumb extends StatefulWidget {
  final String filepath;
  final bool isAudio;
  const _Thumb({required this.filepath, this.isAudio = false});
  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  String? _path;
  @override
  void initState() { super.initState(); _gen(); }
  Future<void> _gen() async {
    final suffix = widget.isAudio ? '_cover' : '';
    final f = File('${Directory.systemTemp.path}/ffmpegpp_thumb_${widget.filepath.hashCode}${suffix}_q.jpg');
    if (await f.exists()) { if (mounted) setState(() => _path = f.path); return; }
    try {
      final ext = widget.filepath.split('.').last.toLowerCase();
      const imageExts = {'png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff', 'tif'};
      final isImage = imageExts.contains(ext);
      final args = <String>['-y'];
      if (!isImage && !widget.isAudio) args.addAll(['-ss', '2']);
      if (widget.isAudio) {
        args.addAll(['-i', widget.filepath, '-an', '-vframes', '1', '-q:v', '5', f.path]);
      } else {
        args.addAll(['-i', widget.filepath, '-vframes', '1', '-q:v', '5', '-s', '80x45', f.path]);
      }
      final r = await Process.run('ffmpeg', args);
      if (r.exitCode == 0 && await f.exists()) { if (mounted) setState(() => _path = f.path); }
    } catch (_) {}
  }
  @override
  Widget build(BuildContext context) {
    if (_path != null) return Image.file(File(_path!), width: 40, height: 25, fit: widget.isAudio ? BoxFit.contain : BoxFit.cover);
    return Icon(widget.isAudio ? Icons.music_note : Icons.movie_outlined, size: 16, color: Theme.of(context).colorScheme.outline);
  }
}
