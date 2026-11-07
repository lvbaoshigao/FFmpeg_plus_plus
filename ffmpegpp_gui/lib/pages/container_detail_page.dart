import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../services/thumbnail_service.dart';
import '../theme/app_strings.dart';
import '../widgets/app_card.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
// 统一下拉/弹出菜单样式（圆角 14 + 200ms 缩放展开，替代 PopupMenuButton）
import '../widgets/option_menu_bar.dart';
import '../widgets/wallpaper_background.dart';
// Linux 客户端修饰（CSD）：统一使用全应用唯一的 window_chrome.dart 实现。
import '../widgets/window_chrome.dart';
import 'pipeline_editor_page.dart';

class ContainerDetailPage extends StatefulWidget {
  final String containerId;
  const ContainerDetailPage({super.key, required this.containerId});
  @override
  State<ContainerDetailPage> createState() => _ContainerDetailPageState();
}

class _ContainerDetailPageState extends State<ContainerDetailPage> {
  int? _editingIndex;
  final _indexCtrl = TextEditingController();

  // 最大化图标状态 / 窗口拖动 / 最小化 / 关闭全部由 widgets/window_chrome.dart
  // 的 WindowChrome 自己维护，本页不再需要 WindowListener 与 _isMaximized。
  @override
  void dispose() {
    _indexCtrl.dispose();
    super.dispose();
  }

  FileContainer? _container(AppState state) =>
      state.containers.where((c) => c.id == widget.containerId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = AppStrings.of(state.config.language);
    final scheme = Theme.of(context).colorScheme;
    final container = _container(state);
    if (container == null) {
      // 空态同样要走 WindowChrome：本页是 pushed 全屏路由，Linux 上路由会
      // 盖住主窗口的 CSD 标题栏，不套的话这一页既不能拖动也无法关闭。
      return withWallpaper(
        context,
        WindowChrome(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: Text(s.isZh ? '容器不存在' : 'Container not found')),
          ),
        ),
      );
    }

    final items = container.sortedItems;
    final files = container.items
        .map((item) => state.videoById(item.fileId))
        .whereType<VideoFile>()
        .toList();
    final hasParsed = files.any((v) => v.parsed);

    final listWidget = items.isEmpty
        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.folder_open, size: 48, color: scheme.outline.withAlpha(80)),
            const SizedBox(height: 8),
            Text(s.isZh ? '容器为空，点击 + 添加文件' : 'Empty container, tap + to add files',
                style: TextStyle(color: scheme.outline, fontSize: 13)),
          ]))
        : ListView.builder(
            // 开窗卡所在列表必须关（见 app_card 的 _WallpaperWindowPainter）
            addRepaintBoundaries: false,
            // 移动端与其它二级页统一（左右 12、下 16）；桌面端保持原内边距
            padding: isMobilePlatform
                ? MobileUi.subListPadding(top: 4, bottom: 16)
                : const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: items.length,
            itemBuilder: (ctx, i) {
              final item = items[i];
              // O(1) 查表：原先是 itemBuilder 内对 state.videos 的线性扫描，
              // 列表整体退化为 O(items²)（items 可达数百）。
              final video = state.videoById(item.fileId);
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
      // 排序菜单：统一为 ScaleMenuButton（圆角 14 浮层 + 200ms 缩放展开），
      // 不再是系统 PopupMenuButton 的直角瞬时弹出。
      ScaleMenuButton<ContainerSortMode>(
        icon: Icons.sort,
        iconSize: 20,
        tooltip: s.isZh ? '排序' : 'Sort',
        items: [
          OptionItem(ContainerSortMode.name, s.containerSortName),
          OptionItem(ContainerSortMode.size, s.containerSortSize),
          OptionItem(ContainerSortMode.duration, s.containerSortDuration),
        ],
        onSelected: (mode) => state.sortContainerBy(container.id, mode),
      ),
      const SizedBox(width: 8),
    ];

    final content = Column(children: [
      // 移动端：二级页面玻璃药丸顶栏（返回圆钮 + 操作药丸 + 标题药丸），
      // 与其它子页面（命令/日志/设置二级页）保持一致；
      // 桌面端保留原平铺工具栏。
      if (isMobilePlatform)
        MobileSubPageTopBar(
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.folder_special, size: 15, color: scheme.primary),
            const SizedBox(width: 4),
            // 标题药丸按内容取宽，长容器名约束在屏宽 1/3 内省略
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.34),
              child: Text(container.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Text(' (${container.fileCount})',
                style: TextStyle(fontSize: 11, color: scheme.outline, fontWeight: FontWeight.normal)),
          ]),
          actions: [
            MobileGlassPillAction(
              icon: Icons.edit_note,
              tooltip: s.isZh ? '编辑节点图' : 'Edit Pipeline',
              color: hasParsed ? scheme.onSurface : scheme.outlineVariant,
              onTap: hasParsed ? () => _editPipeline(state, container) : null,
            ),
            MobileGlassPillAction(
              icon: Icons.drive_file_rename_outline,
              tooltip: s.isZh ? '重命名' : 'Rename',
              color: scheme.onSurface,
              onTap: () => _rename(state, container, s),
            ),
            MobileGlassPillAction(
              icon: Icons.add,
              tooltip: s.containerAddFiles,
              color: scheme.onPrimary,
              bg: scheme.primary,
              onTap: () => _addFiles(state),
            ),
            // 排序菜单：与桌面端同一个 ScaleMenuButton（浮层宽度由 menuWidth 控制，
            // 不再依赖 PopupMenuButton 的 constraints 去压制菜单宽度）。
            ScaleMenuButton<ContainerSortMode>(
              icon: Icons.sort,
              iconSize: 19,
              size: 34,
              tooltip: s.isZh ? '排序' : 'Sort',
              items: [
                OptionItem(ContainerSortMode.name, s.containerSortName),
                OptionItem(ContainerSortMode.size, s.containerSortSize),
                OptionItem(ContainerSortMode.duration, s.containerSortDuration),
              ],
              onSelected: (mode) => state.sortContainerBy(container.id, mode),
            ),
          ],
        )
      else
      Padding(
        // 垂直内边距上下相等：原先下边距只有 2，工具栏整体偏上。
        // Linux 的 36px 自绘标题栏已统一由 WindowChrome 让位（内容整体下移），
        // 这里不再额外留 40；macOS 走系统标题栏，保留历史上的 40 视觉间距。
        padding: EdgeInsets.fromLTRB(8, Platform.isMacOS ? 40 : 4, 8, 4),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back, size: 20), onPressed: () => Navigator.pop(context)),
          const SizedBox(width: 4),
          // 标题组由「裸 GestureDetector + Spacer」改为 Expanded：容器名拿到有界宽度，
          // 大字号/超长名称时单行省略，而不是把整条工具栏撑到横向溢出。
          // Expanded 已吸收全部剩余空间，操作按钮依旧被顶到最右侧（原 Spacer 的作用）。
          Expanded(
            child: GestureDetector(
              onDoubleTap: () => _rename(state, container, s),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.folder_special, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(container.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                ),
                Text('  (${container.fileCount})', style: TextStyle(fontSize: 12, color: scheme.outline)),
              ]),
            ),
          ),
          ...toolbarActions,
        ]),
      ),
      Expanded(child: listWidget),
    ]);

    // Linux 客户端修饰（CSD）：统一使用 widgets/window_chrome.dart。
    //  * WindowChrome 必须放在 withWallpaper 的**内层**：标题栏玻璃用
    //    BackdropFilter 采样同一棵树里更早绘制的像素，套在壁纸外层只会透出
    //    窗口底色；
    //  * 不传 title / onBack：本页已自带工具栏（桌面）与药丸顶栏（移动端），
    //    避免出现「两层标题 / 两个返回」；
    //  * macOS/Windows 走系统标题栏，WindowChrome 内部自动 no-op，
    //    不会出现「双标题栏 + 重复窗口按钮」。
    // 历史上本页自绘过一份 _buildCsdTitleBar + _CsdBtn，现已删除（与主窗口、
    // 节点编辑器、独立面板统一到同一份实现，避免四处漂移）。
    return _withWallpaper(
      context,
      WindowChrome(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: content,
        ),
      ),
    );
  }

  Widget _buildItem(AppState state, AppStrings s, ColorScheme scheme,
      FileContainer container, ContainerItem item, VideoFile video) {
    final clr = scheme.onSurface;
    final isEditing = _editingIndex == item.index;

    final row = Padding(
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
                      if (newIdx != null && newIdx > 0 && newIdx <= container.items.length) state.updateContainerItemIndex(container.id, item.fileId, newIdx);
                      setState(() => _editingIndex = null);
                    },
                  ))
                : Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(color: scheme.primaryContainer.withAlpha(80), borderRadius: BorderRadius.circular(6)),
                    // 固定 36×36 容器内的单行序号：字号调大时等比缩小而不是换行/溢出
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('${item.index}', maxLines: 1,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.primary)),
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          // 缩略图
          ClipRRect(borderRadius: BorderRadius.circular(4),
            child: _Thumb(filepath: video.filepath, isAudio: video.fileMediaType == MediaType.audio, ffmpeg: state.config.ffmpegPath)),
          const SizedBox(width: 8),
          // 文件信息
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(video.filename, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: clr), maxLines: 1, overflow: TextOverflow.ellipsis),
            // 分辨率/时长/大小信息行单行省略：大字号下折成两行会把卡片撑高，
            // 并让右侧操作按钮与文件名首行错位
            if (video.parsed)
              Text('${video.resolution != "N/A" ? "${video.resolution}  •  " : ""}${video.durationStr}  •  ${formatFileSize(video.sizeMb)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))
            else
              Text(s.probing, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
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
    );

    // 卡片统一走 AppCard：移动端跟随「卡片样式」（liquid/blur/theme/gray），
    // 与项目页/设置页/配置库的卡片语言一致；桌面端保持原有 Card 外观不变。
    if (isMobilePlatform) {
      return AppCard(
        style: state.config.cardStyle,
        radius: 12,
        margin: const EdgeInsets.only(bottom: 6),
        child: row,
      );
    }
    return Card(margin: const EdgeInsets.only(bottom: 6), child: row);
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
        onSave: (graph) => state.updateContainerPipeline(container.id, graph),
      ),
    ));
  }

  Widget _withWallpaper(BuildContext context, Widget child) =>
      withWallpaper(context, child);

  Future<void> _addFiles(AppState state) async {
    final r = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'flv', 'wmv', 'ts', 'mpg', 'mpeg', 'm4v', '3gp',
          ...kAudioExts,
          'png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff', 'tif']);
    if (r.isNotEmpty) {
      final paths = r.where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isNotEmpty) state.addFilesToContainer(widget.containerId, paths);
    }
  }
}

class _Thumb extends StatefulWidget {
  final String filepath;
  final bool isAudio;
  final String? ffmpeg;
  const _Thumb({required this.filepath, this.isAudio = false, this.ffmpeg});
  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  String? _path;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await ThumbnailService.ensureThumbnail(widget.filepath,
        ffmpeg: widget.ffmpeg, isAudio: widget.isAudio);
    if (mounted && p != null) setState(() => _path = p);
  }
  @override
  Widget build(BuildContext context) {
    // 缩略图按显示尺寸 3x 封顶解码（1080p 源 ~8MB/张）
    if (_path != null) return Image.file(File(_path!), width: 40, height: 25, cacheWidth: 120, fit: widget.isAudio ? BoxFit.contain : BoxFit.cover);
    return Icon(widget.isAudio ? Icons.music_note : Icons.movie_outlined, size: 16, color: Theme.of(context).colorScheme.outline);
  }
}
