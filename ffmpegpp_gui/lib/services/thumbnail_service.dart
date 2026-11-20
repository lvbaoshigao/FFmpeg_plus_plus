import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
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
  }) => _shared.requestThumbnail(filepath, ffmpeg: ffmpeg, isAudio: isAudio);

  /// Reuses a pending request for the same file and artwork mode.
  ///
  /// Cache misses beyond the backlog limit return null and may be retried.
  Future<String?> requestThumbnail(
    String filepath, {
    String? ffmpeg,
    bool? isAudio,
  }) {
    final audio = isAudio ?? detectMediaType(filepath) == MediaType.audio;
    final key = (filepath, audio);
    if (_inFlight[key] case final pending?) return pending;

    final suffix = audio ? '_cover' : '';
    final cache = File(
      '${_cacheDirectory.path}${Platform.pathSeparator}'
      'ffmpegpp_thumb_${stableHash(filepath)}$suffix.jpg',
    );
    final future = _cachedPath(cache);
    if (_inFlight.length >= _maxConcurrent + _maxQueued) return future;

    final request = future
        .then((cached) {
          if (cached != null) return Future<String?>.value(cached);
          final job = _ThumbnailRequest(filepath, ffmpeg, audio, cache);
          _queue.addLast(job);
          _pump();
          return job.result.future;
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
      if (cached != null) return cached;
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
      final timer = Timer(_timeout, run.cancel);
      try {
        final result = await run.run(
          FfmpegInstaller.resolveFfmpeg(configured: job.ffmpeg),
          args,
        );
        if (result.exitCode != 0 ||
            !await output.exists() ||
            await output.length() == 0) {
          return null;
        }
        return await _cachedPath(job.cache) ??
            (await output.rename(job.cache.path)).path;
      } finally {
        timer.cancel();
      }
    } catch (_) {
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
  _ThumbnailRequest(this.filepath, this.ffmpeg, this.isAudio, this.cache);

  final String filepath;
  final String? ffmpeg;
  final bool isAudio;
  final File cache;
  final result = Completer<String?>();
}
