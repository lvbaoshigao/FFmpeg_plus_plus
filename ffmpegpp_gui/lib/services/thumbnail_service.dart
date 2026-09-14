import 'dart:async';
import 'dart:io';
import '../models/models.dart';
import 'ffmpeg_installer.dart';

/// 统一的缩略图生成服务（视频抽帧 / 音频封面）。
///
/// 之前该逻辑在 video_card / task_card / container_detail_page /
/// pipeline_editor_page 各复制一份且参数互不一致；统一为：
/// - 缓存文件：`<systemTemp>/ffmpegpp_thumb_<fnv1a(path)><_cover>.jpg`，
///   以 176x108 / -q:v 3 生成一份，各显示处按需缩放；
/// - Process.start + 30 秒超时 kill（损坏文件/超长 seek 会卡住 ffmpeg，
///   裸 Process.run 只会放弃等待，悬挂进程仍持有管道拖住后续导入）；
/// - 同一文件的并发请求复用同一个 Future，避免重复起进程。
class ThumbnailService {
  ThumbnailService._();

  // 缓存键：FNV-1a 稳定摘要（String.hashCode 跨运行不稳定且 32 位易碰撞）
  static String stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static final Map<String, Future<String?>> _inFlight = {};

  static Future<String?> ensureThumbnail(
    String filepath, {
    String? ffmpeg,
    bool? isAudio,
  }) {
    // [FIX H-1] 规范化 key：isAudio 为 null 时按 false 处理，避免 "null" 与 "false"
    // 被视为两个不同 key 而对同一文件重复起进程。
    final audioFlag = (isAudio ?? false) ? 'a' : 'v';
    final key = '$filepath|$audioFlag';
    // [FIX H-1] 保留「先查后插」同步去重：并发调用同一 key 必须复用同一个 Future。
    final existing = _inFlight[key];
    if (existing != null) return existing;
    // [FIX H-1] Future.sync 包裹：即便 _generate 在首个 await 前同步抛异常，
    // 也不会在 _inFlight 残留永不完成的项；完成后移除 key，避免失败被永久缓存
    //（null）且 Map 无界增长。真正的成功缓存交给调用点的 f.exists() 判断。
    final fut = Future.sync(() => _generate(filepath, ffmpeg, isAudio))
        .whenComplete(() => _inFlight.remove(key));
    _inFlight[key] = fut;
    return fut;
  }

  static Future<String?> _generate(String filepath, String? ffmpeg, bool? isAudioOverride) async {
    final isAudio = isAudioOverride ?? detectMediaType(filepath) == MediaType.audio;
    final suffix = isAudio ? '_cover' : '';
    final f = File('${Directory.systemTemp.path}/ffmpegpp_thumb_${stableHash(filepath)}$suffix.jpg');
    try {
      if (await f.exists()) return f.path;
      final ext = filepath.split('.').last.toLowerCase();
      final isImage = kImageExts.contains(ext);
      final args = <String>['-y'];
      if (!isImage && !isAudio) args.addAll(['-ss', '5']);
      if (isAudio) {
        args.addAll(['-i', filepath, '-an', '-vframes', '1', '-q:v', '3', f.path]);
      } else {
        args.addAll(['-i', filepath, '-vframes', '1', '-q:v', '3', '-s', '176x108', f.path]);
      }
      final proc = await Process.start(FfmpegInstaller.resolveFfmpeg(configured: ffmpeg), args);
      final killTimer = Timer(const Duration(seconds: 30), () => proc.kill());
      try {
        // 排空 stdout/stderr：ffmpeg 的日志输出超过管道缓冲区时会阻塞在写端
        await Future.wait([proc.stdout.drain<void>(), proc.stderr.drain<void>()]);
        final exitCode = await proc.exitCode;
        if (exitCode != 0) return null;
      } finally {
        killTimer.cancel();
      }
      return await f.exists() ? f.path : null;
    } catch (_) {
      return null;
    }
  }
}
