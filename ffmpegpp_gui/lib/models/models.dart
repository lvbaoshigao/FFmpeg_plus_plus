import 'package:uuid/uuid.dart';

const _uuid = Uuid();

// ═══════════════════════════════════════════
// 媒体类型标签
// ═══════════════════════════════════════════

enum MediaType { video, image, audio }

// ═══════════════════════════════════════════
// 流水线步骤
// ═══════════════════════════════════════════

enum PipelineStepType {
  start,
  avProcess,
  subtitle,
  clip,
  frame,
  speed,
  imageConvert,
  audioConvert,
  extractAudio,
  imageCrop,
  output,
}

class PipelineStep {
  final String id;
  PipelineStepType type;
  Map<String, dynamic> params;

  PipelineStep({required this.id, required this.type, Map<String, dynamic>? params})
      : params = params ?? {};

  PipelineStep copy() => PipelineStep(id: _uuid.v4(), type: type, params: Map.of(params));

  String get label {
    switch (type) {
      case PipelineStepType.start: return '开始';
      case PipelineStepType.avProcess: return '音视频处理';
      case PipelineStepType.subtitle: return '字幕烧录';
      case PipelineStepType.clip: return '片段截取';
      case PipelineStepType.frame: return '帧提取';
      case PipelineStepType.speed: return '变速';
      case PipelineStepType.imageConvert: return '图片转换';
      case PipelineStepType.audioConvert: return '音频转换';
      case PipelineStepType.extractAudio: return '提取音频';
      case PipelineStepType.imageCrop: return '图片裁剪';
      case PipelineStepType.output: return '输出';
    }
  }

  String get labelEn {
    switch (type) {
      case PipelineStepType.start: return 'Start';
      case PipelineStepType.avProcess: return 'AV Process';
      case PipelineStepType.subtitle: return 'Subtitle';
      case PipelineStepType.clip: return 'Clip';
      case PipelineStepType.frame: return 'Frame';
      case PipelineStepType.speed: return 'Speed';
      case PipelineStepType.imageConvert: return 'Image Convert';
      case PipelineStepType.audioConvert: return 'Audio Convert';
      case PipelineStepType.extractAudio: return 'Extract Audio';
      case PipelineStepType.imageCrop: return 'Image Crop';
      case PipelineStepType.output: return 'Output';
    }
  }
}

class PipelineNode {
  final String id;
  PipelineStepType type;
  Map<String, dynamic> params;
  double x, y;

  PipelineNode({required this.id, required this.type, Map<String, dynamic>? params, this.x = 0, this.y = 0})
      : params = params ?? {};

  PipelineNode copy() => PipelineNode(id: _uuid.v4(), type: type, params: Map.of(params), x: x, y: y);

  Map<String, dynamic> toJson() => {
    'id': id, 'type': type.name, 'params': params, 'x': x, 'y': y,
  };

  factory PipelineNode.fromJson(Map<String, dynamic> json) => PipelineNode(
    id: json['id'] as String? ?? _uuid.v4(),
    type: PipelineStepType.values.firstWhere((t) => t.name == json['type'], orElse: () => PipelineStepType.start),
    params: (json['params'] as Map<String, dynamic>?) ?? {},
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
  );

  String get label {
    switch (type) {
      case PipelineStepType.start: return '源文件';
      case PipelineStepType.avProcess: return '音视频处理';
      case PipelineStepType.subtitle: return '字幕烧录';
      case PipelineStepType.clip: return '片段截取';
      case PipelineStepType.frame: return '帧提取';
      case PipelineStepType.speed: return '变速';
      case PipelineStepType.imageConvert: return '图片转换';
      case PipelineStepType.audioConvert: return '音频转换';
      case PipelineStepType.extractAudio: return '提取音频';
      case PipelineStepType.imageCrop: return '图片裁剪';
      case PipelineStepType.output: return '输出';
    }
  }

  String get labelEn {
    switch (type) {
      case PipelineStepType.start: return 'Source';
      case PipelineStepType.avProcess: return 'AV Process';
      case PipelineStepType.subtitle: return 'Subtitle';
      case PipelineStepType.clip: return 'Clip';
      case PipelineStepType.frame: return 'Frame';
      case PipelineStepType.speed: return 'Speed';
      case PipelineStepType.imageConvert: return 'Image Convert';
      case PipelineStepType.audioConvert: return 'Audio Convert';
      case PipelineStepType.extractAudio: return 'Extract Audio';
      case PipelineStepType.imageCrop: return 'Image Crop';
      case PipelineStepType.output: return 'Output';
    }
  }

  bool get hasInput => type != PipelineStepType.start;
  bool get hasOutput => type != PipelineStepType.output;

  Set<MediaType> get inputTypes => switch (type) {
    PipelineStepType.start => {},
    PipelineStepType.avProcess => {MediaType.video},
    PipelineStepType.subtitle => {MediaType.video},
    PipelineStepType.clip => {MediaType.video},
    PipelineStepType.frame => {MediaType.video},
    PipelineStepType.speed => {MediaType.video},
    PipelineStepType.imageConvert => {MediaType.image},
    PipelineStepType.audioConvert => {MediaType.audio},
    PipelineStepType.extractAudio => {MediaType.video},
    PipelineStepType.imageCrop => {MediaType.image},
    PipelineStepType.output => {MediaType.video, MediaType.image, MediaType.audio},
  };

  MediaType? get outputType => switch (type) {
    PipelineStepType.start => switch (params['file_media_type'] as String? ?? 'video') {
      'audio' => MediaType.audio, 'image' => MediaType.image, _ => MediaType.video,
    },
    PipelineStepType.avProcess => MediaType.video,
    PipelineStepType.subtitle => MediaType.video,
    PipelineStepType.clip => MediaType.video,
    PipelineStepType.frame => MediaType.image,
    PipelineStepType.speed => MediaType.video,
    PipelineStepType.imageConvert => MediaType.image,
    PipelineStepType.audioConvert => MediaType.audio,
    PipelineStepType.extractAudio => MediaType.audio,
    PipelineStepType.imageCrop => MediaType.image,
    PipelineStepType.output => null,
  };

  String get mediaTag {
    if (type == PipelineStepType.start) return 'In';
    if (type == PipelineStepType.output) return 'O';
    final inp = inputTypes;
    final out = outputType;
    if (inp.isEmpty && out != null) return out.name[0].toUpperCase();
    if (inp.isEmpty || out == null) return '';
    final i = inp.length == 1 ? inp.first.name[0].toUpperCase() : '*';
    return '$i→${out.name[0].toUpperCase()}';
  }
}

class PipelineConnection {
  final String id;
  final String fromNodeId;
  final String toNodeId;

  PipelineConnection({required this.id, required this.fromNodeId, required this.toNodeId});

  PipelineConnection copy() => PipelineConnection(id: _uuid.v4(), fromNodeId: fromNodeId, toNodeId: toNodeId);

  Map<String, dynamic> toJson() => {'id': id, 'from': fromNodeId, 'to': toNodeId};

  factory PipelineConnection.fromJson(Map<String, dynamic> json) => PipelineConnection(
    id: json['id'] as String? ?? _uuid.v4(),
    fromNodeId: json['from'] as String,
    toNodeId: json['to'] as String,
  );
}

class PipelineGraph {
  final List<PipelineNode> nodes;
  final List<PipelineConnection> connections;

  PipelineGraph({List<PipelineNode>? nodes, List<PipelineConnection>? connections})
      : nodes = nodes ?? [],
        connections = connections ?? [];

  PipelineGraph copy() {
    final idMap = <String, String>{};
    final newNodes = nodes.map((n) {
      final newId = _uuid.v4();
      idMap[n.id] = newId;
      return PipelineNode(id: newId, type: n.type, params: Map.of(n.params), x: n.x, y: n.y);
    }).toList();
    final newConns = connections.map((c) => PipelineConnection(
      id: _uuid.v4(),
      fromNodeId: idMap[c.fromNodeId] ?? c.fromNodeId,
      toNodeId: idMap[c.toNodeId] ?? c.toNodeId,
    )).toList();
    return PipelineGraph(nodes: newNodes, connections: newConns);
  }

  Map<String, dynamic> toJson() => {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'connections': connections.map((c) => c.toJson()).toList(),
  };

  factory PipelineGraph.fromJson(Map<String, dynamic> json) => PipelineGraph(
    nodes: (json['nodes'] as List?)?.map((n) => PipelineNode.fromJson(n as Map<String, dynamic>)).toList(),
    connections: (json['connections'] as List?)?.map((c) => PipelineConnection.fromJson(c as Map<String, dynamic>)).toList(),
  );
}

enum PipelineMode { merged, sequential }

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
        taskId: json['task_id'] as String? ?? '',
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        currentTime: json['current_time'] as String? ?? '00:00:00',
        totalTime: json['total_time'] as String? ?? '00:00:00',
        speed: json['speed'] as String? ?? 'N/A',
        fps: json['fps'] as String? ?? '0',
        bitrate: json['bitrate'] as String? ?? '0 kb/s',
        frame: (json['frame'] as num?)?.toInt() ?? 0,
        remaining: json['remaining'] as String? ?? 'N/A',
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
  final PipelineGraph pipelineGraph;
  final PipelineMode pipelineMode;
  final bool parsed;
  final MediaType fileMediaType;

  VideoFile({
    required this.id, this.filepath = '', this.filename = '',
    this.format = '', this.sizeMb = 0, this.duration = 0, this.durationStr = '',
    this.bitRateKbps = 0, this.codec = '', this.codecLongName = '',
    this.width = 0, this.height = 0, this.resolution = '', this.fps = 0,
    this.pixFmt = '', this.isHdr = false, this.audioCodec = '',
    this.audioChannels = 0, this.audioSampleRate = '',
    this.hasSubtitles = false, this.subtitleCount = 0, this.subtitles = const [],
    TranscodeConfig? config, PipelineGraph? pipelineGraph,
    this.pipelineMode = PipelineMode.merged, this.parsed = false,
    this.fileMediaType = MediaType.video,
  }) : config = config ?? TranscodeConfig(),
       pipelineGraph = pipelineGraph ?? PipelineGraph();

  VideoFile copyWith({
    String? filepath, String? filename, String? format, double? sizeMb,
    double? duration, String? durationStr, double? bitRateKbps,
    String? codec, String? codecLongName, int? width, int? height,
    String? resolution, double? fps, String? pixFmt, bool? isHdr,
    String? audioCodec, int? audioChannels, String? audioSampleRate,
    bool? hasSubtitles, int? subtitleCount, List<SubtitleStream>? subtitles,
    TranscodeConfig? config, PipelineGraph? pipelineGraph,
    PipelineMode? pipelineMode, bool? parsed, MediaType? fileMediaType,
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
        subtitles: subtitles ?? this.subtitles, config: config ?? this.config,
        pipelineGraph: pipelineGraph ?? this.pipelineGraph,
        pipelineMode: pipelineMode ?? this.pipelineMode, parsed: parsed ?? this.parsed,
        fileMediaType: fileMediaType ?? this.fileMediaType,
      );

  static MediaType _detectMediaType(String filepath) {
    final ext = filepath.split('.').last.toLowerCase();
    const imageExts = {'png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff', 'tif'};
    const audioExts = {'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'ac3'};
    if (imageExts.contains(ext)) return MediaType.image;
    if (audioExts.contains(ext)) return MediaType.audio;
    return MediaType.video;
  }

  factory VideoFile.fromFilepath(String filepath, {String? id}) => VideoFile(
        id: id ?? _uuid.v4(), filepath: filepath,
        filename: filepath.split('\\').last.split('/').last,
        fileMediaType: _detectMediaType(filepath),
      );

  factory VideoFile.fromProbeResult(String filepath, Map<String, dynamic> info, {String? id}) {
    id ??= _uuid.v4();
    final mt = switch (info['media_type'] as String? ?? '') {
      'audio' => MediaType.audio,
      'image' => MediaType.image,
      _ => _detectMediaType(filepath),
    };
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
      fileMediaType: mt,
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
  double? startTime, endTime;
  // ── 扩展处理选项 ──
  double? speed;                    // 变速倍率，null=不变速
  bool extractAudioEnabled;         // 是否提取音频
  String extractAudioCodec;         // 提取音频编码器
  String extractAudioFormat;        // 提取音频格式
  int? extractAudioBitrate;         // 提取音频码率
  String frameExtractMode;          // 'none'/'single'/'range'/'all'
  double? frameTime;                // 单帧时间
  double? frameRangeStart;
  double? frameRangeEnd;
  double? frameFps;
  String frameFormat;               // png/jpg...
  String? imageOutputFormat;        // 图片转换输出格式
  int imageQuality;                 // 图片质量
  int? cropX, cropY, cropW, cropH;  // 图片裁剪
  String? audioConvertCodec;        // 音频格式转换
  String? audioConvertFormat;
  int? audioConvertBitrate;
  String? audioConvertSampleRate;

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
    this.startTime, this.endTime,
    this.speed,
    this.extractAudioEnabled = false, this.extractAudioCodec = 'copy',
    this.extractAudioFormat = 'm4a', this.extractAudioBitrate,
    this.frameExtractMode = 'none', this.frameTime, this.frameRangeStart,
    this.frameRangeEnd, this.frameFps, this.frameFormat = 'png',
    this.imageOutputFormat, this.imageQuality = 95,
    this.cropX, this.cropY, this.cropW, this.cropH,
    this.audioConvertCodec, this.audioConvertFormat,
    this.audioConvertBitrate, this.audioConvertSampleRate,
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
    if (startTime != null) opts['start_time'] = startTime;
    if (endTime != null) opts['end_time'] = endTime;
    return opts;
  }
}

// ═══════════════════════════════════════════
// 任务状态
// ═══════════════════════════════════════════

enum TaskStatus { pending, processing, completed, failed, cancelled }

class BackendCall {
  final String action;
  final Map<String, dynamic> params;
  BackendCall({required this.action, required this.params});
}

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
  final List<BackendCall>? pipelineCalls;
  final int currentCallIndex;

  TaskInfo({
    required this.id, required this.videoId, required this.filename,
    required this.inputPath, required this.outputPath,
    this.status = TaskStatus.pending, this.progress = 0,
    this.elapsed = '', this.remaining = '', this.speed = '', this.fps = '', this.bitrate = '',
    this.frame = 0, this.error, this.logLines = const [],
    required this.config, this.expanded = false, this.outputSize, this.duration, this.command,
    this.pipelineCalls, this.currentCallIndex = 0,
  });

  TaskInfo copyWith({
    TaskStatus? status, double? progress, String? elapsed, String? remaining,
    String? speed, String? fps, String? bitrate, int? frame, String? error,
    List<String>? logLines, bool? expanded, int? outputSize, double? duration, List<String>? command,
    int? currentCallIndex,
  }) => TaskInfo(
        id: id, videoId: videoId, filename: filename, inputPath: inputPath, outputPath: outputPath,
        status: status ?? this.status, progress: progress ?? this.progress,
        elapsed: elapsed ?? this.elapsed, remaining: remaining ?? this.remaining,
        speed: speed ?? this.speed, fps: fps ?? this.fps, bitrate: bitrate ?? this.bitrate,
        frame: frame ?? this.frame, error: error ?? this.error,
        logLines: logLines ?? this.logLines, config: config,
        expanded: expanded ?? this.expanded, outputSize: outputSize ?? this.outputSize,
        duration: duration ?? this.duration, command: command ?? this.command,
        pipelineCalls: pipelineCalls, currentCallIndex: currentCallIndex ?? this.currentCallIndex,
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
  String language, ffmpegPath, ffprobePath, defaultOutputDir, intermediateDir, fontFamily;
  bool darkMode;
  int themeColor;
  double fontSize;
  int fontWeightIndex;
  String backgroundImage;
  double backgroundOpacity;
  double cardOpacity;
  bool debugMode;
  bool saveLogs;
  bool enableSystemNotification;
  String logSavePath;
  bool useNodeEditor;
  Map<String, int> nodeUsageCount;
  int maxConcurrentTasks;
  Map<String, List<String>> keyBindings;

  static const fontWeightValues = [300, 400, 500, 600, 700];
  static const fontWeightLabels = ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold'];
  int get fontWeightValue => fontWeightValues[fontWeightIndex.clamp(0, 4)];

  static const defaultKeyBindings = <String, List<String>>{
    'canvas_select_all': ['Control', 'A'],
    'canvas_delete_selected': ['Delete'],
    'project_select_all': ['Control', 'A'],
    'queue_add_all': ['Control', 'Shift', 'A'],
    'queue_start_all': ['Control', 'Shift', 'S'],
    'project_clear_all': ['Control', 'Shift', 'Delete'],
    'queue_stop_all': ['Control', 'Shift', 'X'],
    'canvas_pan_button': ['right'],
    'canvas_select_button': ['left'],
  };

  AppConfig({
    this.language = 'zh', this.ffmpegPath = '', this.ffprobePath = '',
    this.defaultOutputDir = '', this.intermediateDir = '', this.darkMode = true, this.themeColor = 0xFF5E6AD2,
    this.fontFamily = 'Microsoft YaHei', this.fontSize = 17.0, this.fontWeightIndex = 1,
    this.backgroundImage = '', this.backgroundOpacity = 0.8, this.cardOpacity = 0.7,
    this.debugMode = false, this.saveLogs = false, this.enableSystemNotification = false, this.logSavePath = '',
    this.useNodeEditor = true,
    this.maxConcurrentTasks = 1,
    Map<String, int>? nodeUsageCount,
    Map<String, List<String>>? keyBindings,
  }) : nodeUsageCount = nodeUsageCount ?? {},
       keyBindings = keyBindings ?? Map.from(defaultKeyBindings);

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        language: json['language'] as String? ?? 'zh',
        ffmpegPath: json['ffmpeg_path'] as String? ?? '',
        ffprobePath: json['ffprobe_path'] as String? ?? '',
        defaultOutputDir: json['default_output_dir'] as String? ?? '',
        intermediateDir: json['intermediate_dir'] as String? ?? '',
        darkMode: json['dark_mode'] as bool? ?? true,
        themeColor: json['theme_color'] as int? ?? 0xFF5E6AD2,
        fontFamily: json['font_family'] as String? ?? 'Microsoft YaHei',
        fontSize: (json['font_size'] as num?)?.toDouble() ?? 17.0,
        fontWeightIndex: json['font_weight'] as int? ?? 1,
        backgroundImage: json['background_image'] as String? ?? '',
        backgroundOpacity: (json['background_opacity'] as num?)?.toDouble() ?? 0.8,
        cardOpacity: (json['card_opacity'] as num?)?.toDouble() ?? 0.7,
        debugMode: json['debug_mode'] as bool? ?? false,
        saveLogs: json['save_logs'] as bool? ?? false,
        enableSystemNotification: json['enable_system_notification'] as bool? ?? false,
        logSavePath: json['log_save_path'] as String? ?? '',
        useNodeEditor: json['use_node_editor'] as bool? ?? true,
        maxConcurrentTasks: json['max_concurrent_tasks'] as int? ?? 1,
        nodeUsageCount: (json['node_usage_count'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, (v as num).toInt())) ?? {},
        keyBindings: (json['key_bindings'] as Map<String, dynamic>?)?.map((k, v) =>
            MapEntry(k, (v as List<dynamic>).map((e) => e as String).toList())) ?? Map.from(defaultKeyBindings),
      );

  Map<String, dynamic> toJson() => {
        'language': language, 'ffmpeg_path': ffmpegPath, 'ffprobe_path': ffprobePath,
        'default_output_dir': defaultOutputDir, 'intermediate_dir': intermediateDir, 'dark_mode': darkMode,
        'theme_color': themeColor, 'font_family': fontFamily, 'font_size': fontSize,
        'font_weight': fontWeightIndex,
        'background_image': backgroundImage, 'background_opacity': backgroundOpacity,
        'card_opacity': cardOpacity,
        'debug_mode': debugMode,
        'save_logs': saveLogs, 'enable_system_notification': enableSystemNotification, 'log_save_path': logSavePath,
        'use_node_editor': useNodeEditor,
        'max_concurrent_tasks': maxConcurrentTasks,
        'node_usage_count': nodeUsageCount,
        'key_bindings': keyBindings,
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
