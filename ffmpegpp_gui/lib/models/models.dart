import 'dart:io' show Platform;
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

final String _defaultFontFamily = Platform.isWindows ? 'Microsoft YaHei'
    : Platform.isMacOS ? 'PingFang SC'
    : 'Noto Sans CJK SC';

// ═══════════════════════════════════════════
// 媒体类型标签
// ═══════════════════════════════════════════

enum MediaType { video, image, audio }

const kImageExts = {'png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff', 'tif'};

String formatFileSize(double sizeMb) {
  if (sizeMb >= 1000) return '${(sizeMb / 1024).toStringAsFixed(2)} GB';
  if (sizeMb >= 0.1) return '${sizeMb.toStringAsFixed(1)} MB';
  final kb = sizeMb * 1024;
  if (kb >= 0.1) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb * 1024).toStringAsFixed(0)} B';
}

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
  audioQuality,
  audioSpeed,
  audioVolume,
  audioCompressor,
  audioMetadata,
  extractAudio,
  concatMedia,
  imageToVideo,
  imageCrop,
  imageRotate,
  imageScale,
  imageBrightness,
  imageNoise,
  imageSharpen,
  imageDenoise,
  imageChannelExtract,
  videoCrop,
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
      case PipelineStepType.audioQuality: return '音质调整';
      case PipelineStepType.audioSpeed: return '调整速度';
      case PipelineStepType.audioVolume: return '调整音量';
      case PipelineStepType.audioCompressor: return '压缩动态范围';
      case PipelineStepType.audioMetadata: return '元信息编辑';
      case PipelineStepType.extractAudio: return '提取音频';
      case PipelineStepType.concatMedia: return '合并媒体';
      case PipelineStepType.imageToVideo: return '图片合成视频';
      case PipelineStepType.imageCrop: return '图片裁剪';
      case PipelineStepType.imageRotate: return '图片旋转';
      case PipelineStepType.imageScale: return '图片缩放';
      case PipelineStepType.imageBrightness: return '亮度调节';
      case PipelineStepType.imageNoise: return '添加噪点';
      case PipelineStepType.imageSharpen: return '图片锐化';
      case PipelineStepType.imageDenoise: return '图片降噪';
      case PipelineStepType.imageChannelExtract: return '通道提取';
      case PipelineStepType.videoCrop: return '视频裁剪';
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
      case PipelineStepType.audioQuality: return 'Audio Quality';
      case PipelineStepType.audioSpeed: return 'Audio Speed';
      case PipelineStepType.audioVolume: return 'Audio Volume';
      case PipelineStepType.audioCompressor: return 'Dynamic Range';
      case PipelineStepType.audioMetadata: return 'Metadata';
      case PipelineStepType.extractAudio: return 'Extract Audio';
      case PipelineStepType.concatMedia: return 'Concat Media';
      case PipelineStepType.imageToVideo: return 'Image to Video';
      case PipelineStepType.imageCrop: return 'Image Crop';
      case PipelineStepType.imageRotate: return 'Image Rotate';
      case PipelineStepType.imageScale: return 'Image Scale';
      case PipelineStepType.imageBrightness: return 'Brightness';
      case PipelineStepType.imageNoise: return 'Add Noise';
      case PipelineStepType.imageSharpen: return 'Sharpen';
      case PipelineStepType.imageDenoise: return 'Denoise';
      case PipelineStepType.imageChannelExtract: return 'Channel Extract';
      case PipelineStepType.videoCrop: return 'Video Crop';
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
      case PipelineStepType.audioQuality: return '音质调整';
      case PipelineStepType.audioSpeed: return '调整速度';
      case PipelineStepType.audioVolume: return '调整音量';
      case PipelineStepType.audioCompressor: return '压缩动态范围';
      case PipelineStepType.audioMetadata: return '元信息编辑';
      case PipelineStepType.extractAudio: return '提取音频';
      case PipelineStepType.concatMedia: return '合并媒体';
      case PipelineStepType.imageToVideo: return '图片合成视频';
      case PipelineStepType.imageCrop: return '图片裁剪';
      case PipelineStepType.imageRotate: return '图片旋转';
      case PipelineStepType.imageScale: return '图片缩放';
      case PipelineStepType.imageBrightness: return '亮度调节';
      case PipelineStepType.imageNoise: return '添加噪点';
      case PipelineStepType.imageSharpen: return '图片锐化';
      case PipelineStepType.imageDenoise: return '图片降噪';
      case PipelineStepType.imageChannelExtract: return '通道提取';
      case PipelineStepType.videoCrop: return '视频裁剪';
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
      case PipelineStepType.audioQuality: return 'Audio Quality';
      case PipelineStepType.audioSpeed: return 'Audio Speed';
      case PipelineStepType.audioVolume: return 'Audio Volume';
      case PipelineStepType.audioCompressor: return 'Dynamic Range';
      case PipelineStepType.audioMetadata: return 'Metadata';
      case PipelineStepType.extractAudio: return 'Extract Audio';
      case PipelineStepType.concatMedia: return 'Concat Media';
      case PipelineStepType.imageToVideo: return 'Image to Video';
      case PipelineStepType.imageCrop: return 'Image Crop';
      case PipelineStepType.imageRotate: return 'Image Rotate';
      case PipelineStepType.imageScale: return 'Image Scale';
      case PipelineStepType.imageBrightness: return 'Brightness';
      case PipelineStepType.imageNoise: return 'Add Noise';
      case PipelineStepType.imageSharpen: return 'Sharpen';
      case PipelineStepType.imageDenoise: return 'Denoise';
      case PipelineStepType.imageChannelExtract: return 'Channel Extract';
      case PipelineStepType.videoCrop: return 'Video Crop';
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
    PipelineStepType.audioQuality => {MediaType.audio},
    PipelineStepType.audioSpeed => {MediaType.audio},
    PipelineStepType.audioVolume => {MediaType.audio},
    PipelineStepType.audioCompressor => {MediaType.audio},
    PipelineStepType.audioMetadata => {MediaType.audio},
    PipelineStepType.extractAudio => {MediaType.video},
    PipelineStepType.concatMedia => {MediaType.video, MediaType.audio},
    PipelineStepType.imageToVideo => {MediaType.image},
    PipelineStepType.imageCrop => {MediaType.image},
    PipelineStepType.imageRotate => {MediaType.image},
    PipelineStepType.imageScale => {MediaType.image},
    PipelineStepType.imageBrightness => {MediaType.image},
    PipelineStepType.imageNoise => {MediaType.image},
    PipelineStepType.imageSharpen => {MediaType.image},
    PipelineStepType.imageDenoise => {MediaType.image},
    PipelineStepType.imageChannelExtract => {MediaType.image},
    PipelineStepType.videoCrop => {MediaType.video},
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
    PipelineStepType.audioQuality => MediaType.audio,
    PipelineStepType.audioSpeed => MediaType.audio,
    PipelineStepType.audioVolume => MediaType.audio,
    PipelineStepType.audioCompressor => MediaType.audio,
    PipelineStepType.audioMetadata => MediaType.audio,
    PipelineStepType.extractAudio => MediaType.audio,
    PipelineStepType.concatMedia => MediaType.video,
    PipelineStepType.imageToVideo => MediaType.video,
    PipelineStepType.imageCrop => MediaType.image,
    PipelineStepType.imageRotate => MediaType.image,
    PipelineStepType.imageScale => MediaType.image,
    PipelineStepType.imageBrightness => MediaType.image,
    PipelineStepType.imageNoise => MediaType.image,
    PipelineStepType.imageSharpen => MediaType.image,
    PipelineStepType.imageDenoise => MediaType.image,
    PipelineStepType.imageChannelExtract => MediaType.image,
    PipelineStepType.videoCrop => MediaType.video,
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

// ═══════════════════════════════════════════
// 逻辑块
// ═══════════════════════════════════════════

enum LogicBlockType { loop, selectiveLoop }

class LogicBlock {
  final String id;
  LogicBlockType type;
  String name;
  List<String> childNodeIds;
  Map<String, dynamic> params;
  double x, y, width, height;

  LogicBlock({
    required this.id, required this.type, this.name = '',
    List<String>? childNodeIds, Map<String, dynamic>? params,
    this.x = 0, this.y = 0, this.width = 200, this.height = 100,
  }) : childNodeIds = childNodeIds ?? [],
       params = params ?? {};

  LogicBlock copy() => LogicBlock(
    id: _uuid.v4(), type: type, name: name,
    childNodeIds: List.of(childNodeIds),
    params: Map.of(params),
    x: x, y: y, width: width, height: height,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'type': type.name, 'name': name,
    'childNodeIds': childNodeIds,
    'params': params,
    'x': x, 'y': y, 'width': width, 'height': height,
  };

  factory LogicBlock.fromJson(Map<String, dynamic> json) => LogicBlock(
    id: json['id'] as String? ?? _uuid.v4(),
    type: LogicBlockType.values.firstWhere(
      (t) => t.name == json['type'], orElse: () => LogicBlockType.loop),
    name: json['name'] as String? ?? '',
    childNodeIds: (json['childNodeIds'] as List?)?.cast<String>() ?? [],
    params: (json['params'] as Map<String, dynamic>?) ?? {},
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
    width: (json['width'] as num?)?.toDouble() ?? 200,
    height: (json['height'] as num?)?.toDouble() ?? 100,
  );

  String label(bool isZh) {
    final typeName = switch (type) {
      LogicBlockType.loop => isZh ? '循环' : 'Loop',
      LogicBlockType.selectiveLoop => isZh ? '选择性循环' : 'Sel.Loop',
    };
    final nameStr = name.isNotEmpty ? ' · $name' : '';
    return '$typeName x${params['count'] ?? 1}$nameStr';
  }
}

class PipelineGraph {
  final List<PipelineNode> nodes;
  final List<PipelineConnection> connections;
  final List<LogicBlock> logicBlocks;

  PipelineGraph({List<PipelineNode>? nodes, List<PipelineConnection>? connections, List<LogicBlock>? logicBlocks})
      : nodes = nodes ?? [],
        connections = connections ?? [],
        logicBlocks = logicBlocks ?? [];

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
    final newBlocks = logicBlocks.map((b) {
      final nb = b.copy();
      nb.childNodeIds = b.childNodeIds.map((cid) => idMap[cid] ?? cid).toList();
      return nb;
    }).toList();
    return PipelineGraph(nodes: newNodes, connections: newConns, logicBlocks: newBlocks);
  }

  Map<String, dynamic> toJson() => {
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'connections': connections.map((c) => c.toJson()).toList(),
    if (logicBlocks.isNotEmpty) 'logicBlocks': logicBlocks.map((b) => b.toJson()).toList(),
  };

  factory PipelineGraph.fromJson(Map<String, dynamic> json) => PipelineGraph(
    nodes: (json['nodes'] as List?)?.map((n) => PipelineNode.fromJson(n as Map<String, dynamic>)).toList(),
    connections: (json['connections'] as List?)?.map((c) => PipelineConnection.fromJson(c as Map<String, dynamic>)).toList(),
    logicBlocks: (json['logicBlocks'] as List?)?.map((b) => LogicBlock.fromJson(b as Map<String, dynamic>)).toList(),
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
    const audioExts = {'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'ac3'};
    if (kImageExts.contains(ext)) return MediaType.image;
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
  int loopCount;
  String? loopMode;
  BackendCall({required this.action, required this.params, this.loopCount = 1, this.loopMode});
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
  int probeThreads;
  Map<String, List<String>> keyBindings;
  bool autoCheckUpdate;
  bool mcpEnabled;
  int mcpPort;
  String aiProvider; // 'openai' or 'anthropic'
  String aiApiKey;
  String aiApiUrl;
  String aiModel;
  bool aiEnabled;
  bool aiReadAccess;
  bool aiWriteAccess;
  bool aiAutoExecute;
  String aiGraphMode;

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
    String? fontFamily, this.fontSize = 17.0, this.fontWeightIndex = 1,
    this.backgroundImage = '', this.backgroundOpacity = 0.8, this.cardOpacity = 0.7,
    this.debugMode = false, this.saveLogs = false, this.enableSystemNotification = false, this.logSavePath = '',
    this.useNodeEditor = true,
    this.maxConcurrentTasks = 1,
    this.probeThreads = 1,
    Map<String, int>? nodeUsageCount,
    Map<String, List<String>>? keyBindings,
    this.autoCheckUpdate = true,
    this.mcpEnabled = false,
    this.mcpPort = 3000,
    this.aiProvider = 'openai',
    this.aiApiKey = '',
    this.aiApiUrl = 'https://api.openai.com/v1/chat/completions',
    this.aiModel = 'gpt-4o',
    this.aiEnabled = true,
    this.aiReadAccess = false,
    this.aiWriteAccess = false,
    this.aiAutoExecute = false,
    this.aiGraphMode = 'redo',
  }) : fontFamily = fontFamily ?? _defaultFontFamily,
       nodeUsageCount = nodeUsageCount ?? {},
       keyBindings = keyBindings ?? Map.from(defaultKeyBindings);

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        language: json['language'] as String? ?? 'zh',
        ffmpegPath: json['ffmpeg_path'] as String? ?? '',
        ffprobePath: json['ffprobe_path'] as String? ?? '',
        defaultOutputDir: json['default_output_dir'] as String? ?? '',
        intermediateDir: json['intermediate_dir'] as String? ?? '',
        darkMode: json['dark_mode'] as bool? ?? true,
        themeColor: json['theme_color'] as int? ?? 0xFF5E6AD2,
        fontFamily: json['font_family'] as String? ?? _defaultFontFamily,
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
        probeThreads: json['probe_threads'] as int? ?? 1,
        nodeUsageCount: (json['node_usage_count'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, (v as num).toInt())) ?? {},
        keyBindings: (json['key_bindings'] as Map<String, dynamic>?)?.map((k, v) =>
            MapEntry(k, (v as List<dynamic>).map((e) => e as String).toList())) ?? Map.from(defaultKeyBindings),
        autoCheckUpdate: json['auto_check_update'] as bool? ?? true,
        mcpEnabled: json['mcp_enabled'] as bool? ?? false,
        mcpPort: json['mcp_port'] as int? ?? 3000,
        aiProvider: json['ai_provider'] as String? ?? 'openai',
        aiApiKey: json['ai_api_key'] as String? ?? '',
        aiApiUrl: json['ai_api_url'] as String? ?? 'https://api.openai.com/v1/chat/completions',
        aiModel: json['ai_model'] as String? ?? 'gpt-4o',
        aiEnabled: json['ai_enabled'] as bool? ?? true,
        aiReadAccess: json['ai_read_access'] as bool? ?? json['ai_auto_apply'] as bool? ?? false,
        aiWriteAccess: json['ai_write_access'] as bool? ?? false,
        aiAutoExecute: json['ai_auto_execute'] as bool? ?? json['ai_auto_apply'] as bool? ?? false,
        aiGraphMode: json['ai_graph_mode'] as String? ?? 'redo',
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
        'probe_threads': probeThreads,
        'node_usage_count': nodeUsageCount,
        'key_bindings': keyBindings,
        'auto_check_update': autoCheckUpdate,
        'mcp_enabled': mcpEnabled,
        'mcp_port': mcpPort,
        'ai_provider': aiProvider,
        'ai_api_key': aiApiKey,
        'ai_api_url': aiApiUrl,
        'ai_model': aiModel,
        'ai_enabled': aiEnabled,
        'ai_read_access': aiReadAccess,
        'ai_write_access': aiWriteAccess,
        'ai_auto_execute': aiAutoExecute,
        'ai_graph_mode': aiGraphMode,
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

// ═══════════════════════════════════════════
// 容器 (Container)
// ═══════════════════════════════════════════

enum ContainerSortMode { name, size, duration, custom }

class ContainerItem {
  final String fileId;
  int index;
  ContainerItem({required this.fileId, required this.index});

  Map<String, dynamic> toJson() => {'fileId': fileId, 'index': index};
  factory ContainerItem.fromJson(Map<String, dynamic> json) =>
      ContainerItem(fileId: json['fileId'] as String, index: json['index'] as int? ?? 0);
}

class FileContainer {
  final String id;
  String name;
  List<ContainerItem> items;
  PipelineGraph pipelineGraph;
  bool expanded;

  FileContainer({
    required this.id,
    required this.name,
    List<ContainerItem>? items,
    PipelineGraph? pipelineGraph,
    this.expanded = false,
  }) : items = items ?? [],
       pipelineGraph = pipelineGraph ?? PipelineGraph();

  int get fileCount => items.length;

  List<ContainerItem> get sortedItems {
    final sorted = List<ContainerItem>.from(items);
    sorted.sort((a, b) => a.index.compareTo(b.index));
    return sorted;
  }

  void reindex() {
    items.sort((a, b) => a.index.compareTo(b.index));
    for (var i = 0; i < items.length; i++) {
      items[i].index = i + 1;
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name,
    'items': items.map((i) => i.toJson()).toList(),
    'pipelineGraph': pipelineGraph.toJson(),
  };

  factory FileContainer.fromJson(Map<String, dynamic> json) => FileContainer(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    items: (json['items'] as List?)?.map((i) => ContainerItem.fromJson(i)).toList(),
    pipelineGraph: json['pipelineGraph'] != null ? PipelineGraph.fromJson(json['pipelineGraph']) : null,
  );
}
