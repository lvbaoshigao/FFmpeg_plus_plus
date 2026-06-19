import 'package:uuid/uuid.dart';

const _uuid = Uuid();

// ═══════════════════════════════════════════
// JSON 协议消息
// ═══════════════════════════════════════════

class JsonRequest {
  final String id;
  final String action;
  final Map<String, dynamic>? params;
  JsonRequest({required this.id, required this.action, this.params});

  Map<String, dynamic> toJson() => {
        'id': id,
        'action': action,
        if (params != null) 'params': params,
      };
}

class JsonResponse {
  final String id;
  final bool success;
  final Map<String, dynamic>? data;
  final String? error;
  JsonResponse({required this.id, required this.success, this.data, this.error});

  factory JsonResponse.fromJson(Map<String, dynamic> json) => JsonResponse(
        id: json['id'] as String,
        success: json['success'] as bool,
        data: json['data'] as Map<String, dynamic>?,
        error: json['error'] as String?,
      );
}

class ProgressUpdate {
  final String taskId;
  final double progress;
  final String currentTime;
  final String totalTime;
  final String speed;
  final String fps;
  final String bitrate;
  final int frame;
  final String remaining;

  ProgressUpdate({
    required this.taskId, required this.progress,
    required this.currentTime, required this.totalTime,
    required this.speed, required this.fps,
    required this.bitrate, required this.frame, required this.remaining,
  });

  factory ProgressUpdate.fromJson(Map<String, dynamic> json) => ProgressUpdate(
        taskId: json['task_id'] as String,
        progress: (json['progress'] as num).toDouble(),
        currentTime: json['current_time'] as String,
        totalTime: json['total_time'] as String,
        speed: json['speed'] as String,
        fps: json['fps'] as String,
        bitrate: json['bitrate'] as String,
        frame: json['frame'] as int,
        remaining: json['remaining'] as String,
      );
}

// ═══════════════════════════════════════════
// 视频文件信息
// ═══════════════════════════════════════════

class VideoFile {
  final String id;
  final String filepath;
  final String filename;
  final String format;
  final double sizeMb;
  final double duration;
  final String durationStr;
  final double bitRateKbps;
  final String codec;
  final String codecLongName;
  final int width;
  final int height;
  final String resolution;
  final double fps;
  final String pixFmt;
  final bool isHdr;
  final String audioCodec;
  final int audioChannels;
  final String audioSampleRate;
  final bool hasSubtitles;
  final int subtitleCount;
  final List<SubtitleStream> subtitles;
  final TranscodeConfig config;
  final bool parsed;

  VideoFile({
    required this.id, this.filepath = '', this.filename = '',
    this.format = '', this.sizeMb = 0, this.duration = 0, this.durationStr = '',
    this.bitRateKbps = 0, this.codec = '', this.codecLongName = '',
    this.width = 0, this.height = 0, this.resolution = '', this.fps = 0,
    this.pixFmt = '', this.isHdr = false, this.audioCodec = '',
    this.audioChannels = 0, this.audioSampleRate = '',
    this.hasSubtitles = false, this.subtitleCount = 0, this.subtitles = const [],
    TranscodeConfig? config, this.parsed = false,
  }) : config = config ?? TranscodeConfig();

  VideoFile copyWith({
    String? filepath, String? filename, String? format, double? sizeMb,
    double? duration, String? durationStr, double? bitRateKbps,
    String? codec, String? codecLongName, int? width, int? height,
    String? resolution, double? fps, String? pixFmt, bool? isHdr,
    String? audioCodec, int? audioChannels, String? audioSampleRate,
    bool? hasSubtitles, int? subtitleCount, List<SubtitleStream>? subtitles,
    TranscodeConfig? config, bool? parsed,
  }) => VideoFile(
        id: id, filepath: filepath ?? this.filepath,
        filename: filename ?? this.filename, format: format ?? this.format,
        sizeMb: sizeMb ?? this.sizeMb, duration: duration ?? this.duration,
        durationStr: durationStr ?? this.durationStr, bitRateKbps: bitRateKbps ?? this.bitRateKbps,
        codec: codec ?? this.codec, codecLongName: codecLongName ?? this.codecLongName,
        width: width ?? this.width, height: height ?? this.height,
        resolution: resolution ?? this.resolution, fps: fps ?? this.fps,
        pixFmt: pixFmt ?? this.pixFmt, isHdr: isHdr ?? this.isHdr,
        audioCodec: audioCodec ?? this.audioCodec, audioChannels: audioChannels ?? this.audioChannels,
        audioSampleRate: audioSampleRate ?? this.audioSampleRate,
        hasSubtitles: hasSubtitles ?? this.hasSubtitles, subtitleCount: subtitleCount ?? this.subtitleCount,
        subtitles: subtitles ?? this.subtitles, config: config ?? this.config, parsed: parsed ?? this.parsed,
      );

  factory VideoFile.fromFilepath(String filepath, {String? id}) => VideoFile(
        id: id ?? _uuid.v4(), filepath: filepath,
        filename: filepath.split('\\').last.split('/').last,
      );

  factory VideoFile.fromProbeResult(String filepath, Map<String, dynamic> info, {String? id}) {
    id ??= _uuid.v4();
    return VideoFile(
      id: id, filepath: filepath,
      filename: info['filename'] as String? ?? '',
      format: info['format_long_name'] as String? ?? '',
      sizeMb: (info['size_mb'] as num?)?.toDouble() ?? 0,
      duration: (info['duration'] as num?)?.toDouble() ?? 0,
      durationStr: info['duration_str'] as String? ?? '',
      bitRateKbps: (info['bit_rate_kbps'] as num?)?.toDouble() ?? 0,
      codec: info['codec'] as String? ?? '',
      codecLongName: info['codec_long_name'] as String? ?? '',
      width: info['width'] as int? ?? 0, height: info['height'] as int? ?? 0,
      resolution: info['resolution'] as String? ?? '',
      fps: (info['fps'] as num?)?.toDouble() ?? 0,
      pixFmt: info['pix_fmt'] as String? ?? '',
      isHdr: info['is_hdr'] as bool? ?? false,
      audioCodec: info['audio_codec'] as String? ?? '',
      audioChannels: info['audio_channels'] as int? ?? 0,
      audioSampleRate: '${info['audio_sample_rate'] ?? 'N/A'}',
      hasSubtitles: info['has_subtitles'] as bool? ?? false,
      subtitleCount: info['subtitle_count'] as int? ?? 0,
      subtitles: (info['subtitles'] as List<dynamic>?)
              ?.map((s) => SubtitleStream.fromJson(s as Map<String, dynamic>)).toList() ?? [],
      config: TranscodeConfig(), parsed: true,
    );
  }
}

class SubtitleStream {
  final int index;
  final String codec;
  final String language;
  final String title;
  final bool forced;
  final bool isDefault;
  SubtitleStream({required this.index, this.codec = '', this.language = '', this.title = '', this.forced = false, this.isDefault = false});

  factory SubtitleStream.fromJson(Map<String, dynamic> json) => SubtitleStream(
        index: json['index'] as int, codec: json['codec'] as String? ?? '',
        language: json['language'] as String? ?? '', title: json['title'] as String? ?? '',
        forced: json['forced'] as bool? ?? false, isDefault: json['default'] as bool? ?? false,
      );
}

// ═══════════════════════════════════════════
// 转码配置
// ═══════════════════════════════════════════

class TranscodeConfig {
  String videoCodec, gpu, preset;
  int? crf;
  int? videoBitrate;       // null = keep original
  double? framerate;
  int? resolutionW, resolutionH;
  String audioCodec;
  int? audioBitrate;       // null = keep original
  int? audioChannels;
  bool subtitleEnabled;
  String subtitleSource;
  String? subtitleFile;
  int subtitleIndex;
  int? subtitleIndex2;     // 第二字幕轨道（可选）
  // 字幕样式
  String subtitleFontName;
  int subtitleFontSize;
  String subtitleFontColor;     // hex: #FFFFFF
  int subtitleOutlineWidth;
  String subtitleOutlineColor;  // hex: #000000
  String outputFormat, namingMode, namingValue;

  TranscodeConfig({
    this.videoCodec = 'h264', this.gpu = 'CPU', this.preset = 'medium', this.crf,
    this.videoBitrate, this.framerate, this.resolutionW, this.resolutionH,
    this.audioCodec = 'aac', this.audioBitrate = 128, this.audioChannels,
    this.subtitleEnabled = false, this.subtitleSource = 'external', this.subtitleFile,
    this.subtitleIndex = 0, this.subtitleIndex2,
    this.subtitleFontName = 'Arial', this.subtitleFontSize = 24,
    this.subtitleFontColor = '#FFFFFF', this.subtitleOutlineWidth = 2,
    this.subtitleOutlineColor = '#000000',
    this.outputFormat = 'keep', this.namingMode = 'keep',
    this.namingValue = '_processed',
  });

  Map<String, dynamic> toBackendOptions() {
    final opts = <String, dynamic>{
      'video_codec': videoCodec, 'gpu': gpu, 'preset': preset,
      'audio_codec': audioCodec, 'overwrite': true,
    };
    if (crf != null) {
      opts['crf'] = crf;
    } else if (videoBitrate != null) {
      opts['video_bitrate'] = videoBitrate;
    }
    if (framerate != null) opts['framerate'] = framerate;
    if (resolutionW != null && resolutionH != null) opts['resolution'] = [resolutionW, resolutionH];
    if (audioBitrate != null) opts['audio_bitrate'] = audioBitrate;
    if (audioChannels != null) opts['audio_channels'] = audioChannels;
    return opts;
  }
}

// ═══════════════════════════════════════════
// 任务状态
// ═══════════════════════════════════════════

enum TaskStatus { pending, processing, completed, failed, cancelled }

class TaskInfo {
  final String id, videoId, filename, inputPath, outputPath;
  final TaskStatus status;
  final double progress;
  final String elapsed, remaining, speed, fps, bitrate;
  final int frame;
  final String? error;
  final List<String> logLines;
  final TranscodeConfig config;
  final bool expanded;
  final int? outputSize;
  final double? duration;
  final List<String>? command;

  TaskInfo({
    required this.id, required this.videoId, required this.filename,
    required this.inputPath, required this.outputPath,
    this.status = TaskStatus.pending, this.progress = 0,
    this.elapsed = '', this.remaining = '', this.speed = '', this.fps = '', this.bitrate = '',
    this.frame = 0, this.error, this.logLines = const [],
    required this.config, this.expanded = false, this.outputSize, this.duration, this.command,
  });

  TaskInfo copyWith({
    TaskStatus? status, double? progress, String? elapsed, String? remaining,
    String? speed, String? fps, String? bitrate, int? frame, String? error,
    List<String>? logLines, bool? expanded, int? outputSize, double? duration, List<String>? command,
  }) => TaskInfo(
        id: id, videoId: videoId, filename: filename, inputPath: inputPath, outputPath: outputPath,
        status: status ?? this.status, progress: progress ?? this.progress,
        elapsed: elapsed ?? this.elapsed, remaining: remaining ?? this.remaining,
        speed: speed ?? this.speed, fps: fps ?? this.fps, bitrate: bitrate ?? this.bitrate,
        frame: frame ?? this.frame, error: error ?? this.error,
        logLines: logLines ?? this.logLines, config: config,
        expanded: expanded ?? this.expanded, outputSize: outputSize ?? this.outputSize,
        duration: duration ?? this.duration, command: command ?? this.command,
      );

  String get statusLabel {
    switch (status) {
      case TaskStatus.pending: return 'Pending';
      case TaskStatus.processing: return 'Processing';
      case TaskStatus.completed: return 'Done';
      case TaskStatus.failed: return 'Failed';
      case TaskStatus.cancelled: return 'Cancelled';
    }
  }

  String get outputSizeStr {
    if (outputSize == null) return '-';
    final mb = outputSize! / (1024 * 1024);
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(outputSize! / 1024).toStringAsFixed(0)} KB';
  }
}

// ═══════════════════════════════════════════
// 应用配置
// ═══════════════════════════════════════════

class AppConfig {
  String language, ffmpegPath, ffprobePath, defaultOutputDir, fontFamily;
  bool darkMode;
  int themeColor;
  double fontSize;
  int fontWeightIndex;
  bool glassEffect;
  String backgroundImage;
  double backgroundOpacity; // 0.0 ~ 1.0
  double cardOpacity;       // 0.0 ~ 1.0 (3D卡片透明度)
  bool debugMode;
  bool saveLogs;
  String logSavePath;
  // AI
  bool aiEnabled;
  String aiModel;
  String aiEndpoint;
  String aiKey;
  String aiPrompt;

  static const fontWeightValues = [300, 400, 500, 600, 700];
  static const fontWeightLabels = ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold'];
  int get fontWeightValue => fontWeightValues[fontWeightIndex.clamp(0, 4)];

  AppConfig({
    this.language = 'zh', this.ffmpegPath = '', this.ffprobePath = '',
    this.defaultOutputDir = '', this.darkMode = true, this.themeColor = 0xFF5E6AD2,
    this.fontFamily = 'Microsoft YaHei', this.fontSize = 17.0, this.fontWeightIndex = 1,
    this.glassEffect = false, this.backgroundImage = '', this.backgroundOpacity = 0.8, this.cardOpacity = 0.7,
    this.debugMode = false, this.saveLogs = false, this.logSavePath = '',
    this.aiEnabled = false, this.aiModel = 'deepseek-chat',
    this.aiEndpoint = 'https://api.deepseek.com', this.aiKey = '',
    this.aiPrompt = 'You are an FFmpeg expert. Generate ONLY the ffmpeg command, no explanation.\n\n'
        'Requirements:\n- Input: {input}\n- Output: {output}\n- Codec: {video_codec}\n'
        '- GPU: {gpu}\n- Resolution: {resolution}\n- Bitrate: {bitrate} kbps\n'
        '- Framerate: {framerate}\n- Audio: {audio_codec} at {audio_bitrate}k {audio_channels}ch\n'
        '- Subtitle: {subtitle}\n- Extra: {extra}\n\n'
        'Rules:\n1. Skip if "none" or empty.\n2. ONLY output the command, nothing else.\n'
        '3. Use correct GPU encoder names.\n4. Include -y flag.',
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        language: json['language'] as String? ?? 'zh',
        ffmpegPath: json['ffmpeg_path'] as String? ?? '',
        ffprobePath: json['ffprobe_path'] as String? ?? '',
        defaultOutputDir: json['default_output_dir'] as String? ?? '',
        darkMode: json['dark_mode'] as bool? ?? true,
        themeColor: json['theme_color'] as int? ?? 0xFF5E6AD2,
        fontFamily: json['font_family'] as String? ?? 'Microsoft YaHei',
        fontSize: (json['font_size'] as num?)?.toDouble() ?? 14.0,
        fontWeightIndex: json['font_weight'] as int? ?? 1,
        glassEffect: json['glass_effect'] as bool? ?? false,
        backgroundImage: json['background_image'] as String? ?? '',
        backgroundOpacity: (json['background_opacity'] as num?)?.toDouble() ?? 0.8,
        cardOpacity: (json['card_opacity'] as num?)?.toDouble() ?? 0.7,
        debugMode: json['debug_mode'] as bool? ?? false,
        saveLogs: json['save_logs'] as bool? ?? false,
        logSavePath: json['log_save_path'] as String? ?? '',
        aiEnabled: json['ai_enabled'] as bool? ?? false,
        aiModel: json['ai_model'] as String? ?? 'deepseek-chat',
        aiEndpoint: json['ai_endpoint'] as String? ?? 'https://api.deepseek.com',
        aiKey: json['ai_key'] as String? ?? '',
        aiPrompt: (json['ai_prompt'] as String?)?.isNotEmpty == true
            ? json['ai_prompt'] as String
            : 'You are an FFmpeg expert. Generate ONLY the ffmpeg command, no explanation.\n\n'
              'Requirements:\n- Input: {input}\n- Output: {output}\n- Codec: {video_codec}\n'
              '- GPU: {gpu}\n- Resolution: {resolution}\n- Bitrate: {bitrate} kbps\n'
              '- Framerate: {framerate}\n- Audio: {audio_codec} at {audio_bitrate}k {audio_channels}ch\n'
              '- Subtitle: {subtitle}\n- Extra: {extra}\n\n'
              'Rules:\n1. Skip if "none" or empty.\n2. ONLY output the command, nothing else.\n'
              '3. Use correct GPU encoder names.\n4. Include -y flag.',
      );

  Map<String, dynamic> toJson() => {
        'language': language, 'ffmpeg_path': ffmpegPath, 'ffprobe_path': ffprobePath,
        'default_output_dir': defaultOutputDir, 'dark_mode': darkMode,
        'theme_color': themeColor, 'font_family': fontFamily, 'font_size': fontSize,
        'font_weight': fontWeightIndex, 'glass_effect': glassEffect,
        'background_image': backgroundImage, 'background_opacity': backgroundOpacity,
        'card_opacity': cardOpacity,
        'debug_mode': debugMode,
        'save_logs': saveLogs, 'log_save_path': logSavePath,
        'ai_enabled': aiEnabled, 'ai_model': aiModel,
        'ai_endpoint': aiEndpoint, 'ai_key': aiKey, 'ai_prompt': aiPrompt,
      };
}

// ═══════════════════════════════════════════
// 日志条目
// ═══════════════════════════════════════════

class LogEntry {
  final DateTime timestamp;
  final String message;
  final String category; // 'info', 'ffmpeg', 'progress', 'error', 'general'

  LogEntry({required this.timestamp, required this.message, this.category = 'general'});
}
