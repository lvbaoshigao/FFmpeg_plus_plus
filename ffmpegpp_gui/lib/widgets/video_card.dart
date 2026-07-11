import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../pages/pipeline_editor_page.dart';
import 'config_dialog.dart';

class VideoCard extends StatelessWidget {
  final VideoFile video;
  const VideoCard({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clr = scheme.onSurface;
    final state = context.watch<AppState>();
    final s = AppStrings.of(state.config.language);
    final probeError = state.probeErrors[video.filepath];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Container(
            width: 88, height: 54,
            decoration: BoxDecoration(color: video.parsed ? Colors.black : scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
            child: video.parsed ? _ThumbWidget(filepath: video.filepath) : Icon(Icons.movie_outlined, color: scheme.outline, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(video.filename, style: TextStyle(fontWeight: FontWeight.w600, color: clr), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            if (probeError != null)
              Text(probeError, style: TextStyle(fontSize: 12, color: scheme.error))
            else if (video.parsed)
              Text('${video.resolution}  •  ${video.durationStr}  •  ${video.sizeMb.toStringAsFixed(1)} MB  •  ${video.codec}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))
            else
              Text(s.probing, style: TextStyle(fontSize: 12, color: scheme.outline)),
          ])),
          IconButton(icon: Icon(Icons.edit_outlined, size: 20, color: clr), tooltip: s.edit,
              onPressed: video.parsed ? () => _openConfig(context, state) : null),
          IconButton(icon: Icon(Icons.play_arrow, size: 20, color: video.parsed ? scheme.primary : scheme.outline),
              tooltip: s.addToQueue, onPressed: video.parsed ? () => state.addTask(video.id) : null),
          IconButton(icon: Icon(Icons.close, size: 18, color: clr), tooltip: s.remove,
              onPressed: () => state.removeVideo(video.id)),
        ]),
      ),
    );
  }

  void _openConfig(BuildContext context, AppState state) {
    if (state.config.useNodeEditor) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PipelineEditorPage(
          video: video,
          onSave: (graph) {
            state.updateVideoConfig(video.id, video.config);
            final idx = state.videos.indexWhere((v) => v.id == video.id);
            if (idx >= 0) {
              state.updateVideoPipeline(video.id, graph);
            }
          },
        ),
      ));
    } else {
      showDialog(
        context: context,
        builder: (_) => ConfigDialog(
          video: video,
          onSave: (cfg) {
            state.updateVideoConfig(video.id, cfg);
          },
        ),
      );
    }
  }
}

class _ThumbWidget extends StatefulWidget {
  final String filepath;
  const _ThumbWidget({required this.filepath});
  @override
  State<_ThumbWidget> createState() => _ThumbWidgetState();
}
class _ThumbWidgetState extends State<_ThumbWidget> {
  String? _thumbPath;
  @override
  void initState() { super.initState(); _gen(); }

  Future<void> _gen() async {
    final f = File('${Directory.systemTemp.path}/ffmpegpp_thumb_${widget.filepath.hashCode}.jpg');
    if (await f.exists()) { if (mounted) setState(() => _thumbPath = f.path); return; }
    try {
      final ext = widget.filepath.split('.').last.toLowerCase();
      final isImage = kImageExts.contains(ext);
      final args = <String>['-y'];
      if (!isImage) args.addAll(['-ss', '5']);
      args.addAll(['-i', widget.filepath, '-vframes', '1', '-q:v', '3', '-s', '176x108', f.path]);
      final r = await Process.run('ffmpeg', args);
      if (r.exitCode == 0 && await f.exists()) { if (mounted) setState(() => _thumbPath = f.path); }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbPath != null) return ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.file(File(_thumbPath!), fit: BoxFit.cover, width: 88, height: 54));
    return const SizedBox.shrink();
  }
}
