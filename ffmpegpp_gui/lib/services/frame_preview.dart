import 'dart:io';
import 'ffmpeg_installer.dart';

class FramePreview {
  FramePreview._();

  /// 清理同一视频的旧预览缓存（每视频保留最近 [keep] 个），
  /// 避免快速拖动进度条时 /tmp 里堆积几十个永不删除的 jpg。
  static Future<void> _cleanupOldPreviews(String videoPath, String prefix, {int keep = 3}) async {
    try {
      final dir = Directory.systemTemp;
      final dirPrefix = '${dir.path}${Platform.pathSeparator}$prefix';
      final files = await dir
          .list()
          .where((e) => e is File && e.path.startsWith(dirPrefix) && e.path.endsWith('.jpg'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(keep)) {
        try { await f.delete(); } catch (_) {}
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
    // 用视频绝对路径 + 宽度作为稳定 key，避免 hashCode 碰撞
    final stableKey = videoPath.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final height = (width * 9 / 16).round();
    final key =
        'ffmpegpp_preview_${stableKey}_${width}_${(timeSeconds * 10).round()}';
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
        await _cleanupOldPreviews(videoPath, 'ffmpegpp_preview_${stableKey}_${width}_');
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
    final stableKey = videoPath.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final key =
        'ffmpegpp_full_${stableKey}_${(timeSeconds * 10).round()}';
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
        _cleanupOldPreviews(videoPath, 'ffmpegpp_full_${stableKey}_');
        return tmpPath;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
