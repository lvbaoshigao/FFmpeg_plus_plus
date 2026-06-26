import 'dart:io';

class FramePreview {
  FramePreview._();

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
      final result = await Process.run('ffmpeg', [
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
        return tmpPath;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
