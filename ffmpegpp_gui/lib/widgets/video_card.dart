import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import '../pages/pipeline_editor_page.dart';
import '../services/ffmpeg_installer.dart';
import '../app.dart';
import 'config_dialog.dart';

class VideoCard extends StatelessWidget {
  final VideoFile video;
  final VoidCallback? onEdit;
  const VideoCard({super.key, required this.video, this.onEdit});

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
            child: video.parsed ? _ThumbWidget(filepath: video.filepath, isAudio: video.fileMediaType == MediaType.audio, ffmpeg: state.config.ffmpegPath) : Icon(Icons.movie_outlined, color: scheme.outline, size: 28),
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
              onPressed: video.parsed ? (onEdit ?? () => _openConfig(context, state)) : null),
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
  final bool isAudio;
  final String? ffmpeg;
  const _ThumbWidget({required this.filepath, this.isAudio = false, this.ffmpeg});
  @override
  State<_ThumbWidget> createState() => _ThumbWidgetState();
}
class _ThumbWidgetState extends State<_ThumbWidget> {
  String? _thumbPath;
  @override
  void initState() { super.initState(); _gen(); }

  Future<void> _gen() async {
    final suffix = widget.isAudio ? '_cover' : '';
    final f = File('${Directory.systemTemp.path}/ffmpegpp_thumb_${widget.filepath.hashCode}$suffix.jpg');
    if (await f.exists()) { if (mounted) setState(() => _thumbPath = f.path); return; }
    try {
      final ext = widget.filepath.split('.').last.toLowerCase();
      final isImage = kImageExts.contains(ext);
      final args = <String>['-y'];
      if (!isImage && !widget.isAudio) args.addAll(['-ss', '5']);
      if (widget.isAudio) {
        args.addAll(['-i', widget.filepath, '-an', '-vframes', '1', '-q:v', '3', f.path]);
      } else {
        args.addAll(['-i', widget.filepath, '-vframes', '1', '-q:v', '3', '-s', '176x108', f.path]);
      }
      // 超时兜底（修复：批量导入后缩略图 ffmpeg 偶发悬挂——损坏文件/超长
      // seek 会卡住进程，除了自身永不返回外还会拖住同应用进程内其它子进程
      // 的管道读取，表现为后续导入项一直「解析中」）。用 Process.start +
      // 定时 kill 而不是 Process.run().timeout()：后者只是放弃等待，
      // 悬挂的 ffmpeg 进程会继续活着持有管道资源。
      final proc = await Process.start(FfmpegInstaller.resolveFfmpeg(configured: widget.ffmpeg), args);
      final killTimer = Timer(const Duration(seconds: 30), () => proc.kill());
      try {
        // 排空 stdout/stderr：ffmpeg 的日志输出超过管道缓冲区时会阻塞在写端
        await Future.wait([proc.stdout.drain<void>(), proc.stderr.drain<void>()]);
        final exitCode = await proc.exitCode;
        if (exitCode == 0 && await f.exists()) { if (mounted) setState(() => _thumbPath = f.path); }
      } finally {
        killTimer.cancel();
      }
    } catch (_) {}
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
