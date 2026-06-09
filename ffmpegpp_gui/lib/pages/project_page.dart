import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../widgets/video_card.dart';

class ProjectPage extends StatefulWidget {
  const ProjectPage({super.key});
  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  static const _exts = ['mp4', 'avi', 'mkv', 'mov', 'flv', 'wmv', 'webm', 'm4v', 'mpg', 'mpeg', '3gp', 'ts', 'm2ts'];

  String _searchQuery = '';
  bool _searchVisible = false;
  final Set<String> _selectedIds = {};
  bool _dragging = false;

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
          appBar: AppBar(
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
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(s.addVideo),
                onPressed: () => _pick(state),
              ),
              const SizedBox(width: 16),
            ],
          ),
          body: DropTarget(
            onDragDone: _onDrop,
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            child: _buildBody(context, state, videos, s, clr, scheme),
          ),
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

  Future<void> _pick(AppState state) async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom, allowedExtensions: _exts);
    if (r != null && r.files.isNotEmpty) {
      final paths = r.files.where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isNotEmpty) state.addVideos(paths);
    }
  }
}
