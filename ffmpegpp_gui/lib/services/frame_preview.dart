import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'diagnostic_trace.dart';
import 'ffmpeg_installer.dart';
import 'task_process_runner.dart';

class FramePreview {
  FramePreview._();

  static const _defaultMaxConcurrent = 2;
  static const _defaultMaxQueued = 4;
  static const _defaultTimeout = Duration(seconds: 30);
  static final _defaultRunner = TaskProcessRunner(captureLimit: 16 * 1024);
  static TaskProcessRunner _runner = _defaultRunner;
  static int _maxConcurrent = _defaultMaxConcurrent;
  static int _maxQueued = _defaultMaxQueued;
  static Duration _timeout = _defaultTimeout;
  static int _active = 0;
  static final Queue<_QueuedPreview> _queue = Queue<_QueuedPreview>();

  @visibleForTesting
  static void configureForTest({
    required TaskProcessRunner runner,
    int maxConcurrent = _defaultMaxConcurrent,
    int maxQueued = _defaultMaxQueued,
    Duration timeout = _defaultTimeout,
  }) {
    _runner = runner;
    _maxConcurrent = maxConcurrent.clamp(1, 8);
    _maxQueued = maxQueued.clamp(0, 16);
    _timeout = timeout;
  }

  @visibleForTesting
  static void resetForTest() {
    _runner = _defaultRunner;
    _maxConcurrent = _defaultMaxConcurrent;
    _maxQueued = _defaultMaxQueued;
    _timeout = _defaultTimeout;
  }

  @visibleForTesting
  static int get activeForTest => _active;

  @visibleForTesting
  static int get queuedForTest => _queue.length;

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
    final span = trace?.begin(
      'frame.preview',
      details: {
        'mode': width == null ? 'full' : 'scaled',
        'timeoutEnabled': true,
      },
    );
    if (!timeSeconds.isFinite || timeSeconds < 0) {
      span?.finish(success: false, details: {'failureType': 'invalid_time'});
      return null;
    }
    var success = false;
    try {
      final result = await _generateRequest(
        videoPath,
        timeSeconds,
        prefix: prefix,
        width: width,
        span: span,
      );
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
        span?.finish(
          success: false,
          details: {'failureType': 'missing_source'},
        );
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
        span?.record(
          'frame.preview.coalesce',
          details: {'active': _active, 'queued': _queue.length},
        );
        return await pending;
      }
      final target = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}$key',
      );
      if (await target.exists()) {
        span?.record('frame.preview.cache.hit');
        return target.path;
      }

      final completer = Completer<String?>();
      final future = completer.future;
      _inFlight[key] = future;
      final job = _QueuedPreview(
        key,
        completer,
        () => _extract(source.path, time, group, key, width, span),
      );
      if (_active < _maxConcurrent) {
        _startQueued(job);
      } else if (_maxQueued == 0) {
        _inFlight.remove(key);
        completer.complete(null);
        span?.record(
          'frame.preview.queue.reject',
          details: {'reason': 'disabled'},
        );
      } else {
        if (_queue.length >= _maxQueued) {
          final stale = _queue.removeFirst();
          if (identical(_inFlight[stale.key], stale.completer.future)) {
            _inFlight.remove(stale.key);
          }
          if (!stale.completer.isCompleted) stale.completer.complete(null);
          span?.record(
            'frame.preview.queue.drop_oldest',
            details: {'active': _active, 'queued': _queue.length},
          );
        }
        _queue.addLast(job);
        span?.record(
          'frame.preview.queue',
          details: {
            'active': _active,
            'queued': _queue.length,
            'maxConcurrent': _maxConcurrent,
            'maxQueued': _maxQueued,
          },
        );
      }
      return await future;
    } on FileSystemException catch (error) {
      span?.finish(
        success: false,
        error: error,
        details: {'failureType': 'filesystem'},
      );
      return null;
    }
  }

  static final _inFlight = <String, Future<String?>>{};

  static void _startQueued(_QueuedPreview job) {
    _active++;
    unawaited(() async {
      try {
        final result = await job.run();
        if (!job.completer.isCompleted) job.completer.complete(result);
      } catch (error, stack) {
        if (!job.completer.isCompleted) {
          job.completer.completeError(error, stack);
        }
      } finally {
        if (identical(_inFlight[job.key], job.completer.future)) {
          _inFlight.remove(job.key);
        }
        _active--;
        _pumpQueue();
      }
    }());
  }

  static void _pumpQueue() {
    while (_active < _maxConcurrent && _queue.isNotEmpty) {
      _startQueued(_queue.removeFirst());
    }
  }

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
      span?.record(
        'frame.preview.ffmpeg.start',
        details: {'timeoutMs': _timeout.inMilliseconds},
      );
      final run = _runner.createRun();
      var timedOut = false;
      final timer = Timer(_timeout, () {
        timedOut = true;
        run.cancel();
      });
      final ProcessResult result;
      try {
        result = await run.run(FfmpegInstaller.resolveFfmpeg(), [
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
      } on TaskProcessCancelled {
        span?.record(
          'frame.preview.timeout',
          details: {
            'timeoutMs': _timeout.inMilliseconds,
            'processMs': processWatch?.elapsedMilliseconds,
          },
        );
        span?.finish(
          success: false,
          cancelled: true,
          details: {'failureType': timedOut ? 'timeout' : 'cancelled'},
        );
        return null;
      } finally {
        timer.cancel();
      }
      span?.record(
        'frame.preview.ffmpeg.exit',
        details: {
          'exitCode': result.exitCode,
          'processMs': processWatch?.elapsedMilliseconds,
          'stdoutChars': result.stdout.length,
          'stderrChars': result.stderr.length,
        },
      );
      if (result.exitCode != 0 || !await output.exists()) {
        span?.finish(
          success: false,
          details: {
            'exitCode': result.exitCode,
            'failureType': result.exitCode != 0
                ? 'exit_code'
                : 'missing_output',
          },
        );
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
      span?.finish(
        success: false,
        error: error,
        details: {'failureType': 'filesystem'},
      );
      return null;
    } on ProcessException catch (error) {
      span?.finish(
        success: false,
        error: error,
        details: {'failureType': 'process_start'},
      );
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
  }) => _generate(
    videoPath,
    timeSeconds,
    prefix: 'preview',
    width: width,
    trace: trace,
  );

  static Future<String?> generateFullFrame(
    String videoPath,
    double timeSeconds, {
    DiagnosticTrace? trace,
  }) => _generate(videoPath, timeSeconds, prefix: 'full', trace: trace);
}

final class _QueuedPreview {
  const _QueuedPreview(this.key, this.completer, this.run);

  final String key;
  final Completer<String?> completer;
  final Future<String?> Function() run;
}
