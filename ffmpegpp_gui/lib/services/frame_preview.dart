import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'diagnostic_trace.dart';
import 'ffmpeg_installer.dart';

class FramePreview {
  FramePreview._();

  /// 清理同一视频的旧预览缓存（每视频保留最近 [keep] 个），
  /// 避免快速拖动进度条时 /tmp 里堆积几十个永不删除的 jpg。
  static Future<void> _cleanupOldPreviews(
    String prefix,
    String current, {
    int keep = 3,
  }) async {
    try {
      final dir = Directory.systemTemp;
      final dirPrefix = '${dir.path}${Platform.pathSeparator}$prefix';
      final files = await dir
          .list()
          .where(
            (e) =>
                e is File &&
                e.path.startsWith(dirPrefix) &&
                e.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();
      final candidates = await Future.wait([
        for (final file in files)
          if (file.path != current)
            file.stat().then((stat) => (file, stat.modified)),
      ]);
      candidates.sort((a, b) => b.$2.compareTo(a.$2));
      for (final (f, _) in candidates.skip(keep - 1)) {
        if (_inFlight.containsKey(f.uri.pathSegments.last)) continue;
        try {
          await f.delete();
        } catch (_) {}
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

  /// 共用实现：[width] 为空时不缩放（原尺寸抽帧）。
  static Future<String?> _generate(
    String videoPath,
    double timeSeconds, {
    required String prefix,
    int? width,
    DiagnosticTrace? trace,
  }) async {
    final span = trace?.begin('frame.preview', details: {
      'mode': width == null ? 'full' : 'scaled',
      'timeoutEnabled': false,
    });
    if (!timeSeconds.isFinite || timeSeconds < 0) {
      span?.finish(success: false, details: {'failureType': 'invalid_time'});
      return null;
    }
    var success = false;
    try {
      final result = await _generateRequest(videoPath, timeSeconds, prefix: prefix, width: width, span: span);
      success = result != null;
      return result;
    } catch (error) {
      span?.finish(success: false, error: error);
      rethrow;
    } finally {
      span?.finish(success: success);
    }
  }

  static Future<String?> _generateRequest(
    String videoPath,
    double timeSeconds, {
    required String prefix,
    int? width,
    DiagnosticSpan? span,
  }) async {
    try {
      final source = File(videoPath).absolute;
      final stat = await source.stat();
      if (stat.type != FileSystemEntityType.file) {
        span?.finish(success: false, details: {'failureType': 'missing_source'});
        return null;
      }
      final digest = sha256.convert(
        utf8.encode(
          jsonEncode([
            source.path,
            stat.modified.microsecondsSinceEpoch,
            stat.size,
            width,
          ]),
        ),
      );
      final time = _formatTime(timeSeconds);
      final group = 'ffmpegpp_${prefix}_${digest}_';
      final key =
          '$group${(timeSeconds * 1000).round().toString().padLeft(12, '0')}.jpg';
      if (_inFlight[key] case final pending?) {
        span?.record('frame.preview.coalesce', details: {'active': _inFlight.length});
        return await pending;
      }
      span?.record('frame.preview.concurrency', details: {'active': _inFlight.length + 1});
      return await _inFlight.putIfAbsent(key, () async {
        try {
          return await _extract(source.path, time, group, key, width, span);
        } finally {
          _inFlight.remove(key);
        }
      });
    } on FileSystemException catch (error) {
      span?.finish(success: false, error: error, details: {'failureType': 'filesystem'});
      return null;
    }
  }

  static final _inFlight = <String, Future<String?>>{};

  static Future<String?> _extract(
    String source,
    String time,
    String group,
    String key,
    int? width,
    DiagnosticSpan? span,
  ) async {
    Directory? staging;
    try {
      final separator = Platform.pathSeparator;
      final target = File('${Directory.systemTemp.path}$separator$key');
      if (await target.exists()) {
        span?.record('frame.preview.cache.hit');
        return target.path;
      }
      span?.record('frame.preview.cache.miss');

      // Publish only complete frames; separate windows may share the cache.
      staging = await Directory.systemTemp.createTemp('fpp_frame_');
      final output = File('${staging.path}${separator}frame.jpg');
      final processWatch = span == null ? null : (Stopwatch()..start());
      span?.record('frame.preview.ffmpeg.start');
      final result = await Process.run(FfmpegInstaller.resolveFfmpeg(), [
        '-ss',
        time,
        '-i',
        source,
        '-vframes',
        '1',
        if (width != null) ...['-s', '${width}x${(width * 9 / 16).round()}'],
        '-q:v',
        '2',
        output.path,
      ]);
      span?.record('frame.preview.ffmpeg.exit', details: {
        'exitCode': result.exitCode, 'processMs': processWatch?.elapsedMilliseconds,
        'stdoutChars': result.stdout.toString().length, 'stderrChars': result.stderr.toString().length,
      });
      if (result.exitCode != 0 || !await output.exists()) {
        span?.finish(success: false, details: {
          'exitCode': result.exitCode,
          'failureType': result.exitCode != 0 ? 'exit_code' : 'missing_output',
        });
        return null;
      }
      try {
        await output.rename(target.path);
      } on FileSystemException {
        if (!await target.exists()) rethrow;
      }
      _cleanupOldPreviews(group, target.path);
      return target.path;
    } on FileSystemException catch (error) {
      span?.finish(success: false, error: error, details: {'failureType': 'filesystem'});
      return null;
    } on ProcessException catch (error) {
      span?.finish(success: false, error: error, details: {'failureType': 'process_start'});
      return null;
    } finally {
      try {
        await staging?.delete(recursive: true);
      } on FileSystemException {
        // A temporary directory may already have been removed by the OS.
      }
    }
  }

  static Future<String?> generatePreview(
    String videoPath,
    double timeSeconds, {
    int width = 480,
    DiagnosticTrace? trace,
  }) => _generate(videoPath, timeSeconds, prefix: 'preview', width: width, trace: trace);

  static Future<String?> generateFullFrame(
    String videoPath,
    double timeSeconds, {
    DiagnosticTrace? trace,
  }) => _generate(videoPath, timeSeconds, prefix: 'full', trace: trace);
}
