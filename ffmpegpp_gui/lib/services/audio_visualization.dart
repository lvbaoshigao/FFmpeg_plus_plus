import 'dart:io';

/// A bounded, single-frame audio visualization passed directly to FFmpeg.
final class AudioVisualization {
  AudioVisualization.fromParams(Map<String, dynamic> params)
    : width = _dimension(params['width'], 1280),
      height = _dimension(params['height'], 720),
      format = normalizeFormat(params['output_format']);

  final int width;
  final int height;
  final String format;

  static int _dimension(Object? value, int fallback) =>
      number(value, 64, 4096, fallback.toDouble()).toInt();

  /// Uses the same numeric interpretation before and after opening an editor.
  static double number(Object? value, double min, double max, double fallback) {
    final parsed = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    return parsed != null && parsed.isFinite
        ? parsed.clamp(min, max).toDouble()
        : fallback;
  }

  static String uniqueOutput(String requested, Iterable<String> reserved) {
    String key(String value) {
      final normalized = File(value).absolute.uri.normalizePath().toFilePath();
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    final occupied = reserved.map(key).toSet();
    final slash = requested.lastIndexOf('/');
    final backslash = requested.lastIndexOf(r'\');
    final separator = slash > backslash ? slash : backslash;
    final dot = requested.lastIndexOf('.');
    final extension = dot > separator + 1 ? requested.substring(dot) : '';
    final base = extension.isEmpty
        ? requested
        : requested.substring(0, requested.length - extension.length);
    var candidate = requested;
    for (var suffix = 2; ; suffix++) {
      if (!occupied.contains(key(candidate)) &&
          FileSystemEntity.typeSync(candidate, followLinks: false) ==
              FileSystemEntityType.notFound) {
        return candidate;
      }
      candidate = '${base}_$suffix$extension';
    }
  }

  /// Publishes only an owned new file/directory, checking cancellation as well.
  static Future<String> publish(
    String source,
    String destination, {
    void Function()? checkCancelled,
  }) async {
    checkCancelled?.call();
    final target = File(destination);
    await target.parent.create(recursive: true);
    if (Directory(source).existsSync()) {
      // createTemp creates an exclusive directory, including on Windows.
      // Directory.create alone would silently accept a concurrently-created dir.
      final owned = await target.parent.createTemp(
        '${target.uri.pathSegments.last}_',
      );
      try {
        await for (final entity in Directory(
          source,
        ).list(recursive: true, followLinks: false)) {
          checkCancelled?.call();
          final relative = entity.path.substring(source.length);
          if (entity is Directory) {
            await Directory('${owned.path}$relative').create(recursive: true);
          } else if (entity is File) {
            await entity.copy('${owned.path}$relative');
          }
        }
        checkCancelled?.call();
        return owned.path;
      } catch (_) {
        await owned.delete(recursive: true);
        rethrow;
      }
    }
    // Exclusive creation is the second, race-safe check after queuing.
    await target.create(exclusive: true);
    try {
      checkCancelled?.call();
      await File(source).openRead().pipe(target.openWrite());
      checkCancelled?.call();
      return destination;
    } catch (_) {
      // Only this invocation's placeholder can reach this cleanup.
      await target.delete();
      rethrow;
    }
  }

  /// Imported JPEG aliases use the same codec and extension as JPG.
  static String normalizeFormat(Object? value) => switch (value) {
    final String value when value.trim().toLowerCase() == 'webp' => 'webp',
    final String value
        when const {'jpg', 'jpeg'}.contains(value.trim().toLowerCase()) =>
      'jpg',
    _ => 'png',
  };

  /// Replaces only the filename extension, including paths with dotted parents.
  static String withExtension(String path, String extension) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf(r'\');
    final separator = slash > backslash ? slash : backslash;
    final dot = path.lastIndexOf('.');
    final base = dot > separator + 1 ? path.substring(0, dot) : path;
    return '$base.$extension';
  }

  /// Creates argv, never a shell command or a user-supplied filter expression.
  List<String> arguments({
    required String input,
    required String output,
    required bool waveform,
    bool overwrite = false,
  }) {
    final filter = waveform
        ? 'showwavespic=s=${width}x$height:colors=0x4cc9f0:draw=full'
        : 'showspectrumpic=s=${width}x$height:legend=disabled:scale=log';
    return [
      '-hide_banner', '-nostdin', overwrite ? '-y' : '-n',
      '-i', File(input).absolute.path,
      '-filter_complex',
      '[0:a:0]$filter,format=rgb24[image]',
      '-map', '[image]',
      '-frames:v', '1', '-an', '-sn',
      ...switch (format) {
        'jpg' => ['-c:v', 'mjpeg', '-q:v', '2', '-pix_fmt', 'yuvj444p'],
        'webp' => ['-c:v', 'libwebp', '-quality', '90'],
        _ => ['-c:v', 'png', '-pix_fmt', 'rgb24'],
      },
      // One still file even when the filename contains percent signs.
      '-f', 'image2', '-update', '1', '-threads:v', '1',
      File(output).absolute.path,
    ];
  }
}

/// A stream's position on the input presentation timeline, in seconds.
final class VideoTimelineStream {
  const VideoTimelineStream(this.index, this.start, this.duration);
  final int index;
  final double start;
  final double? duration;
}

/// Reads stream durations, never substitutes a longer format/audio duration.
final class VideoTimeline {
  VideoTimeline.fromProbe(Map<String, dynamic> probe) {
    final format = probe['format'];
    formatStart = format is Map ? _decimal(format['start_time']) ?? 0 : 0;
    final streams = (probe['streams'] as List?) ?? const [];
    for (final stream in streams.whereType<Map>()) {
      final type = stream['codec_type'];
      if (type != 'video' && type != 'audio') continue;
      final start = _decimal(stream['start_time']) ?? 0;
      var duration = _decimal(stream['duration']);
      final ticks = _decimal(stream['duration_ts']);
      final timeBase = _rational(stream['time_base']);
      if (duration == null && ticks != null && timeBase != null) {
        duration = ticks * timeBase;
      }
      if (duration == null) {
        final tags = stream['tags'];
        if (tags is Map) {
          final end = _timestamp(tags['DURATION'] ?? tags['duration']);
          if (end != null) duration = end - start;
        }
      }
      final timing = VideoTimelineStream(
        (stream['index'] as num).toInt(),
        start,
        duration != null && duration.isFinite && duration > 0 ? duration : null,
      );
      if (type == 'video' && video == null) {
        video = timing;
        pixelFormat = stream['pix_fmt'] as String?;
      } else if (type == 'audio') {
        audio.add(timing);
      }
    }
    if (video == null) throw const FormatException('当前素材没有可用的视频流');
  }

  VideoTimelineStream? video;
  double formatStart = 0;
  String? pixelFormat;
  double get videoFilterStart =>
      (video!.start - formatStart).clamp(0.0, double.infinity);
  final List<VideoTimelineStream> audio = [];
  double? get videoDuration => video?.duration;

  static double? _decimal(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  static double? _rational(Object? value) {
    if (value is! String) return null;
    final parts = value.split('/');
    if (parts.length != 2) return null;
    final numerator = _decimal(parts[0]);
    final denominator = _decimal(parts[1]);
    return numerator != null && denominator != null && denominator != 0
        ? numerator / denominator
        : null;
  }

  static double? _timestamp(Object? value) {
    if (value is! String) return null;
    final parts = value.split(':');
    if (parts.length != 3) return _decimal(value);
    final hours = _decimal(parts[0]);
    final minutes = _decimal(parts[1]);
    final seconds = _decimal(parts[2]);
    return hours != null && minutes != null && seconds != null
        ? hours * 3600 + minutes * 60 + seconds
        : null;
  }

  /// Reverses all streams about the same end; a delay becomes an output tail gap.
  List<String> reverseArguments({
    required String input,
    required String output,
    required Map<String, dynamic> options,
  }) {
    final selected = [video!, ...audio];
    if (selected.any((stream) => stream.duration == null)) {
      throw const FormatException('无法确定每条视频/音轨的时长，已停止倒放以避免丢轨或破坏音画时序');
    }
    var end = double.negativeInfinity;
    for (final stream in selected) {
      final stop = stream.start + stream.duration!;
      if (stop > end) end = stop;
    }
    String reversed(VideoTimelineStream stream, bool video, String label) {
      final delay = (end - stream.start - stream.duration!).clamp(
        0.0,
        double.infinity,
      );
      final filter = video ? 'reverse,setpts' : 'areverse,asetpts';
      return '[0:${stream.index}]$filter=PTS-STARTPTS+${delay.toStringAsFixed(6)}/TB[$label]';
    }

    return [
      '-hide_banner',
      '-nostdin',
      '-y',
      '-i',
      File(input).absolute.path,
      '-filter_complex',
      [
        reversed(video!, true, 'v'),
        for (var i = 0; i < audio.length; i++) reversed(audio[i], false, 'a$i'),
      ].join(';'),
      '-map',
      '[v]',
      for (var i = 0; i < audio.length; i++) ...['-map', '[a$i]'],
      '-map_metadata',
      '0',
      '-map_chapters',
      '-1',
      for (var i = 0; i < audio.length; i++) ...[
        '-map_metadata:s:a:$i',
        '0:s:a:$i',
      ],
      ...encodingArguments({...options, 'source_pix_fmt': pixelFormat}),
      '-vsync',
      '0',
      File(output).absolute.path,
    ];
  }

  /// Fade maps all audio streams, including inputs without any audio.
  static List<String> fadeArguments({
    required String input,
    required String output,
    required List<String> filters,
    required Map<String, dynamic> options,
    String? sourcePixelFormat,
  }) => [
    '-hide_banner',
    '-nostdin',
    '-y',
    '-i',
    File(input).absolute.path,
    '-map',
    '0:v:0',
    '-map',
    '0:a?',
    '-map_metadata',
    '0',
    if (filters.isNotEmpty) ...['-vf', filters.join(',')],
    ...encodingArguments({...options, 'source_pix_fmt': sourcePixelFormat}),
    '-vsync',
    '0',
    File(output).absolute.path,
  ];

  static String _pixelFormat(Object? source) {
    if (source is String && RegExp(r'(10|12|14|16)').hasMatch(source)) {
      return source.startsWith('yuv') ? source : 'yuv444p10le';
    }
    return 'yuv420p';
  }

  static List<String> encodingArguments(Map<String, dynamic> options) => [
    if (options['video_codec'] == 'libvpx-vp9') ...[
      '-c:v',
      'libvpx-vp9',
      '-b:v',
      '0',
      '-crf',
      '32',
    ] else ...[
      '-c:v',
      'libx264',
      '-preset',
      'medium',
      '-crf',
      '20',
    ],
    '-pix_fmt',
    _pixelFormat(options['source_pix_fmt']),
    '-threads:v',
    '1',
    '-c:a',
    options['audio_codec'] == 'libopus' ? 'libopus' : 'aac',
  ];
}
