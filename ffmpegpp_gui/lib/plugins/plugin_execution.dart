import 'dart:convert';

/// Host operations discovered from this backend, never from a saved graph.
final class PluginExecutionCapabilities {
  const PluginExecutionCapabilities() : _ffmpeg = null;

  PluginExecutionCapabilities._(this._ffmpeg);

  final Map<String, dynamic>? _ffmpeg;

  static const legacyOperations = [
    'media.copy',
    'audio.volume',
    'video.flip',
    'video.scale',
  ];

  factory PluginExecutionCapabilities.fromBackendResponse(
    Map<String, dynamic> response,
  ) {
    final data = response['data'];
    if (response['success'] != true ||
        data is! Map ||
        data['available'] != true) {
      return const PluginExecutionCapabilities();
    }
    final value = data['ffmpeg'];
    if (value is! Map ||
        value['api_version'] is! int ||
        value['api_version'] != 1) {
      return const PluginExecutionCapabilities();
    }
    const maxima = {
      'max_arguments': 128,
      'max_argument_bytes': 8192,
      'max_total_argument_bytes': 32768,
    };
    final normalized = <String, dynamic>{'api_version': 1};
    for (final entry in maxima.entries) {
      final limit = value[entry.key];
      if (limit is! int || limit < 1 || limit > entry.value) {
        return const PluginExecutionCapabilities();
      }
      normalized[entry.key] = limit;
    }
    for (final key in const ['options', 'filters']) {
      final items = value[key];
      if (items is! List ||
          items.length > 1024 ||
          items.any(
            (item) => item is! String || item.isEmpty || item.length > 128,
          ) ||
          items.toSet().length != items.length) {
        return const PluginExecutionCapabilities();
      }
      normalized[key] = List<String>.unmodifiable(items.cast<String>());
    }
    return PluginExecutionCapabilities._(Map.unmodifiable(normalized));
  }

  bool get supportsFfmpeg => _ffmpeg != null;

  Map<String, dynamic> toRequestHost() => {
    'api_version': 1,
    'operations': [...legacyOperations, if (supportsFfmpeg) 'ffmpeg.execute'],
    if (_ffmpeg case final ffmpeg?)
      'ffmpeg': {
        ...ffmpeg,
        'options': List<String>.of(ffmpeg['options'] as List<String>),
        'filters': List<String>.of(ffmpeg['filters'] as List<String>),
      },
  };

  /// Native validation remains authoritative for option arity and filter safety.
  List<String> validateFfmpegResult(Map<String, dynamic> result) {
    final ffmpeg = _ffmpeg;
    if (ffmpeg == null) {
      throw const FormatException(
        'This backend does not support ffmpeg.execute.',
      );
    }
    final arguments = result['arguments'];
    if (result.length != 2 ||
        result['operation'] != 'ffmpeg.execute' ||
        arguments is! List ||
        arguments.length > (ffmpeg['max_arguments'] as int)) {
      throw const FormatException('Invalid ffmpeg.execute result.');
    }
    var totalBytes = 0;
    final normalized = <String>[];
    for (final argument in arguments) {
      if (argument is! String || argument.contains('\u0000')) {
        throw const FormatException(
          'FFmpeg arguments must be strings without NUL.',
        );
      }
      final bytes = utf8.encode(argument).length;
      totalBytes += bytes;
      if (bytes > (ffmpeg['max_argument_bytes'] as int) ||
          totalBytes > (ffmpeg['max_total_argument_bytes'] as int)) {
        throw const FormatException(
          'FFmpeg arguments exceed the backend limits.',
        );
      }
      normalized.add(argument);
    }
    return normalized;
  }
}
