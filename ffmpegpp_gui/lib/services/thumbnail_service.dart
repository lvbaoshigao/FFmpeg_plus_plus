import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'diagnostic_trace.dart';
import 'ffmpeg_installer.dart';
import 'task_process_runner.dart';

/// Generates and caches video thumbnails and audio artwork.
final class ThumbnailService {
  ThumbnailService._(
    this._cacheDirectory,
    this._runner, {
    this._maxConcurrent = 2,
    this._maxQueued = 64,
    this._timeout = const Duration(seconds: 30),
  });

  /// Uses isolated temporary files and an injectable process runner in tests.
  @visibleForTesting
  factory ThumbnailService.forTesting({
    required Directory cacheDirectory,
    required TaskProcessRunner runner,
    int maxConcurrent = 2,
    int maxQueued = 64,
    Duration timeout = const Duration(seconds: 30),
  }) => ThumbnailService._(
    cacheDirectory,
    runner,
    maxConcurrent: maxConcurrent,
    maxQueued: maxQueued,
    timeout: timeout,
  );

  static final _shared = ThumbnailService._(
    Directory.systemTemp,
    TaskProcessRunner(captureLimit: 16 * 1024),
  );

  final Directory _cacheDirectory;
  final TaskProcessRunner _runner;
  final int _maxConcurrent;
  final int _maxQueued;
  final Duration _timeout;
  final _inFlight = <(String, bool), Future<String?>>{};
  final _queue = Queue<_ThumbnailRequest>();
  int _active = 0;

  /// Returns the stable digest used in thumbnail cache filenames.
  static String stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// Uses the shared thumbnail cache and process limit.
  static Future<String?> ensureThumbnail(
    String filepath, {
    String? ffmpeg,
    bool? isAudio,
    DiagnosticTrace? trace,
  }) => _shared.requestThumbnail(filepath, ffmpeg: ffmpeg, isAudio: isAudio, trace: trace);

  /// Reuses a pending request for the same file and artwork mode.
  ///
  /// Cache misses beyond the backlog limit return null and may be retried.
  Future<String?> requestThumbnail(
    String filepath, {
    String? ffmpeg,
    bool? isAudio,
    DiagnosticTrace? trace,
  }) {
    final span = trace?.begin('thumbnail');
    final audio = isAudio ?? detectMediaType(filepath) == MediaType.audio;
    final key = (filepath, audio);
    if (_inFlight[key] case final pending?) {
      span?.record('thumbnail.coalesce', details: {'active': _active, 'queued': _queue.length});
      if (span != null) {
        unawaited(pending.then<void>((path) {
          span.finish(success: path != null, details: {'coalesced': true});
        }, onError: (Object error, StackTrace stack) {
          span.finish(success: false, error: error, details: {'coalesced': true});
        }));
      }
      return pending;
    }

    final suffix = audio ? '_cover' : '';
    final cache = File(
      '${_cacheDirectory.path}${Platform.pathSeparator}'
      'ffmpegpp_thumb_${stableHash(filepath)}$suffix.jpg',
    );
    final future = _cachedPath(cache);
    if (_inFlight.length >= _maxConcurrent + _maxQueued) {
      return future.then((cached) {
        span?.record(cached == null ? 'thumbnail.queue.reject' : 'thumbnail.cache.hit', details: {
          'active': _active, 'queued': _queue.length, 'maxConcurrent': _maxConcurrent, 'maxQueued': _maxQueued,
        });
        span?.finish(success: cached != null, details: {if (cached == null) 'failureType': 'queue_full'});
        return cached;
      });
    }

    final request = future
        .then((cached) {
          if (cached != null) {
            span?.record('thumbnail.cache.hit');
            return Future<String?>.value(cached);
          }
          span?.record('thumbnail.cache.miss');
          final job = _ThumbnailRequest(filepath, ffmpeg, audio, cache, span);
          _queue.addLast(job);
          span?.record('thumbnail.queue', details: {
            'active': _active, 'queued': _queue.length, 'maxConcurrent': _maxConcurrent, 'maxQueued': _maxQueued,
          });
          _pump();
          return job.result.future;
        })
        .then((path) {
          span?.finish(success: path != null);
          return path;
        }, onError: (Object error, StackTrace stack) {
          span?.finish(success: false, error: error);
          Error.throwWithStackTrace(error, stack);
        })
        .whenComplete(() {
          _inFlight.remove(key);
        });
    _inFlight[key] = request;
    return request;
  }

  static Future<String?> _cachedPath(File cache) async {
    try {
      return await cache.exists() ? cache.path : null;
    } on FileSystemException {
      return null;
    }
  }

  void _pump() {
    while (_active < _maxConcurrent && _queue.isNotEmpty) {
      _active++;
      unawaited(_runNext(_queue.removeFirst()));
    }
  }

  Future<void> _runNext(_ThumbnailRequest job) async {
    job.span?.record('thumbnail.concurrency', details: {'active': _active, 'queued': _queue.length});
    try {
      job.result.complete(await _generate(job));
    } finally {
      _active--;
      _pump();
    }
  }

  Future<String?> _generate(_ThumbnailRequest job) async {
    Directory? work;
    try {
      final cached = await _cachedPath(job.cache);
      if (cached != null) {
        job.span?.record('thumbnail.cache.hit');
        return cached;
      }
      // FFmpeg can leave partial output on failure. Publish only a complete
      // image and remove only the temporary directory this job owns.
      work = await _cacheDirectory.createTemp('ffmpegpp_thumbnail_work_');
      final output = File('${work.path}${Platform.pathSeparator}thumbnail.jpg');
      final ext = job.filepath.split('.').last.toLowerCase();
      final args = <String>[
        '-nostdin',
        '-loglevel',
        'error',
        '-y',
        if (!kImageExts.contains(ext) && !job.isAudio) ...['-ss', '5'],
        '-i',
        job.filepath,
        if (job.isAudio) '-an',
        '-vframes',
        '1',
        '-q:v',
        '3',
        if (job.isAudio) ...[
          '-vf',
          'scale=176:108:force_original_aspect_ratio=decrease:force_divisible_by=2',
        ] else ...[
          '-s',
          '176x108',
        ],
        output.path,
      ];
      final run = _runner.createRun();
      var timedOut = false;
      final processWatch = job.span == null ? null : (Stopwatch()..start());
      final timer = Timer(_timeout, () {
        timedOut = true;
        job.span?.record('thumbnail.timeout', details: {'timeoutMs': _timeout.inMilliseconds});
        run.cancel();
      });
      job.span?.record('thumbnail.ffmpeg.start', details: {'timeoutMs': _timeout.inMilliseconds});
      try {
        final result = await run.run(
          FfmpegInstaller.resolveFfmpeg(configured: job.ffmpeg),
          args,
        );
        job.span?.record('thumbnail.ffmpeg.exit', details: {
          'exitCode': result.exitCode, 'processMs': processWatch?.elapsedMilliseconds,
          'stdoutChars': result.stdout.toString().length, 'stderrChars': result.stderr.toString().length,
        });
        if (result.exitCode != 0 ||
            !await output.exists() ||
            await output.length() == 0) {
          job.span?.finish(success: false, cancelled: timedOut, details: {
            'exitCode': result.exitCode,
            'failureType': timedOut ? 'timeout' : result.exitCode != 0 ? 'exit_code' : 'missing_output',
          });
          return null;
        }
        return await _cachedPath(job.cache) ??
            (await output.rename(job.cache.path)).path;
      } on TaskProcessCancelled catch (error) {
        job.span?.finish(success: false, cancelled: true, error: error, details: {
          'failureType': timedOut ? 'timeout' : 'cancelled', 'processMs': processWatch?.elapsedMilliseconds,
        });
        return null;
      } finally {
        timer.cancel();
      }
    } catch (error) {
      job.span?.finish(success: false, error: error, details: {'failureType': 'generation'});
      return null;
    } finally {
      if (work != null) {
        try {
          await work.delete(recursive: true);
        } on FileSystemException {
          // The cache directory may already have been removed.
        }
      }
    }
  }
}

final class _ThumbnailRequest {
  _ThumbnailRequest(this.filepath, this.ffmpeg, this.isAudio, this.cache, this.span);

  final String filepath;
  final String? ffmpeg;
  final bool isAudio;
  final File cache;
  final DiagnosticSpan? span;
  final result = Completer<String?>();
}
