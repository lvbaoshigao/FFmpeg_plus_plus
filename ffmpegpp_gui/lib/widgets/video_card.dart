import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../pages/pipeline_editor_page.dart';
import '../services/thumbnail_service.dart';
import '../app.dart';
import 'app_card.dart';

class VideoCard extends StatelessWidget {
  final VideoFile video;
  final VoidCallback? onEdit;
  const VideoCard({super.key, required this.video, this.onEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clr = scheme.onSurface;
    // 细粒度订阅：不 watch 整个 AppState（进度心跳/日志 notify 会让每张
    // 视频卡高频重建），只 select 语言/ffmpeg路径/本卡的探测错误。
    final s = AppStrings.of(context.select<AppState, String>((s) => s.config.language));
    final ffmpeg = context.select<AppState, String>((s) => s.config.ffmpegPath);
    final probeError = context.select<AppState, String?>((s) => s.probeErrors[video.filepath]);

    // 卡片样式由「主题→样式→卡片样式」（AppConfig.cardStyle）接管
    final cardStyle = context.select<AppState, String>((s) => s.config.cardStyle);
    return AppCard(
      style: cardStyle,
      radius: 12,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      child: Row(children: [
          Container(
            width: 88, height: 54,
            decoration: BoxDecoration(color: video.parsed ? Colors.black : scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
            child: video.parsed ? _ThumbWidget(filepath: video.filepath, isAudio: video.fileMediaType == MediaType.audio, ffmpeg: ffmpeg) : Icon(Icons.movie_outlined, color: scheme.outline, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(video.filename, style: TextStyle(fontWeight: FontWeight.w600, color: clr), maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            if (probeError != null)
              Text(probeError, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.error))
            else if (video.parsed)
              Text('${video.resolution}  •  ${video.durationStr}  •  ${formatFileSize(video.sizeMb)}  •  ${video.codec}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))
            else
              Text(s.probing, style: TextStyle(fontSize: 12, color: scheme.outline)),
          ])),
          IconButton(icon: Icon(Icons.edit_outlined, size: 20, color: clr), tooltip: s.edit,
              onPressed: video.parsed ? (onEdit ?? () => _openConfig(context, context.read<AppState>())) : null),
          IconButton(icon: Icon(Icons.play_arrow, size: 20, color: video.parsed ? scheme.primary : scheme.outline),
              tooltip: s.addToQueue, onPressed: video.parsed ? () => context.read<AppState>().addTask(video.id) : null),
          IconButton(icon: Icon(Icons.close, size: 18, color: clr), tooltip: s.remove,
              onPressed: () => context.read<AppState>().removeVideo(video.id)),
        ]),
    );
  }

  // 编辑统一进入节点编辑器（传统表单模式 ConfigDialog 已彻底移除）
  void _openConfig(BuildContext context, AppState state) {
    Navigator.of(context).push(smoothRoute(
      PipelineEditorPage(
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
  }
}

class _ThumbWidget extends StatefulWidget {
  final String filepath;
  final bool isAudio;
  final String? ffmpeg;
  const _ThumbWidget({required this.filepath, this.isAudio = false, this.ffmpeg});
  @override
  State<_ThumbWidget> createState() => _ThumbWidgetState();
}
class _ThumbWidgetState extends State<_ThumbWidget> {
  String? _thumbPath;
  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final p = await ThumbnailService.ensureThumbnail(widget.filepath,
        ffmpeg: widget.ffmpeg, isAudio: widget.isAudio);
    if (mounted && p != null) setState(() => _thumbPath = p);
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbPath != null) {
      return ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.file(File(_thumbPath!),
          fit: widget.isAudio ? BoxFit.contain : BoxFit.cover, width: 88, height: 54));
    }
    return Icon(Icons.music_note, color: Theme.of(context).colorScheme.outline, size: 24);
  }
}
