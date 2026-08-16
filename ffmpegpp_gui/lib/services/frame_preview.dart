import 'dart:io';
import 'ffmpeg_installer.dart';

class FramePreview {
  FramePreview._();

  /// 清理同一视频的旧预览缓存（每视频保留最近 [keep] 个），
  /// 避免快速拖动进度条时 /tmp 里堆积几十个永不删除的 jpg。
  static void _cleanupOldPreviews(String videoPath, String prefix, {int keep = 3}) {
    try {
      final dir = Directory.systemTemp;
      final dirPrefix = '${dir.path}${Platform.pathSeparator}$prefix';
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.startsWith(dirPrefix) && f.path.endsWith('.jpg'))
          .toList()
        // 文件名含时间戳，字典序倒序 = 最新在前
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(keep)) {
        try { f.deleteSync(); } catch (_) {}
      }
    } catch (_) {}
  }

  static String _formatTime(double seconds) {
    final totalMs = (seconds * 1000).round();
    final h = totalMs ~/ 3600000;
    final m = (totalMs % 3600000) ~/ 60000;
    final s = (totalMs % 60000) ~/ 1000;
    final ms = totalMs % 1000;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${ms.toString().padLeft(3, '0')}';
  }

  static Future<String?> generatePreview(
    String videoPath,
    double timeSeconds, {
    int width = 480,
  }) async {
    final height = (width * 9 / 16).round();
    final key =
        'ffmpegpp_preview_${videoPath.hashCode}_${(timeSeconds * 10).round()}';
    final tmpDir = Directory.systemTemp;
    final tmpPath = '${tmpDir.path}${Platform.pathSeparator}$key.jpg';

    if (await File(tmpPath).exists()) {
      return tmpPath;
    }

    final timeStr = _formatTime(timeSeconds);

    try {
      final result = await Process.run(FfmpegInstaller.resolveFfmpeg(), [
        '-ss', timeStr,
        '-i', videoPath,
        '-vframes', '1',
        '-s', '${width}x$height',
        '-q:v', '2',
        tmpPath,
      ]);

      if (result.exitCode != 0) {
        return null;
      }

      if (await File(tmpPath).exists()) {
        _cleanupOldPreviews(videoPath, 'ffmpegpp_preview_${videoPath.hashCode}_');
        return tmpPath;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> generateFullFrame(
    String videoPath,
    double timeSeconds,
  ) async {
    final key =
        'ffmpegpp_full_${videoPath.hashCode}_${(timeSeconds * 10).round()}';
    final tmpPath = '${Directory.systemTemp.path}${Platform.pathSeparator}$key.jpg';

    if (await File(tmpPath).exists()) return tmpPath;

    final timeStr = _formatTime(timeSeconds);
    try {
      final result = await Process.run(FfmpegInstaller.resolveFfmpeg(), [
        '-ss', timeStr,
        '-i', videoPath,
        '-vframes', '1',
        '-q:v', '2',
        tmpPath,
      ]);
      if (result.exitCode != 0) return null;
      if (await File(tmpPath).exists()) {
        _cleanupOldPreviews(videoPath, 'ffmpegpp_full_${videoPath.hashCode}_');
        return tmpPath;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
