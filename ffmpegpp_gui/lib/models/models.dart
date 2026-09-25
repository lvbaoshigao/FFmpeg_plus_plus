import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:uuid/uuid.dart';
import '../services/secure_key_store.dart';

export 'quick_config.dart';

const _uuid = Uuid();

/// 默认字体族。
///
/// 桌面端给出各自的系统中文字体族名（theme 里 `fontFamily.isNotEmpty` 才应用它）。
/// **Android 返回空串**：空串才是「系统字体（默认）」在 UI 与主题层统一的表示——
///   * 设置页移动端分支用 `fontFamily.isEmpty` 判断「系统字体 / 导入字体」哪一行
///     打勾；给一个非空族名会让「导入字体」被误标为已选中；
///   * AppTheme 对空串走 `fontFamilyFallback`（其中第一个就是 'Noto Sans CJK SC'），
///     效果与直接写 'Noto Sans CJK SC' 相同，但不会去应用一个安卓上并不存在的
///     字体族名（安卓系统字体的族名由 fonts.xml 决定，SDK 版本间并不统一）。
final String _defaultFontFamily = Platform.isWindows ? 'Microsoft YaHei'
    : Platform.isMacOS ? 'PingFang SC'
    : '';

/// Android 上早期的默认字体族（见 [_defaultFontFamily] 的说明）。
/// 老配置里存的这个值在安卓上不可解析，等同「系统字体」，加载时归一化为空串。
const String _legacyAndroidFontFamily = 'Noto Sans CJK SC';

/// 字体族容错解析：缺失回退默认值，并把安卓上的历史默认值归一化为空串。
String _parseFontFamily(dynamic raw) {
  if (raw is! String) return _defaultFontFamily;
  if (Platform.isAndroid && raw == _legacyAndroidFontFamily) return '';
  return raw;
}

// ═══════════════════════════════════════════
// 媒体类型标签
// ═══════════════════════════════════════════

enum MediaType { video, image, audio }

const kImageExts = {'png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff', 'tif'};

const kAudioExts = {'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'ac3'};

MediaType detectMediaType(String filepath) {
  final ext = filepath.split('.').last.toLowerCase();
  if (kImageExts.contains(ext)) return MediaType.image;
  if (kAudioExts.contains(ext)) return MediaType.audio;
  return MediaType.video;
}

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
  // ── 扩展节点（对应后端 node_registry ID 0x19 起）──
  videoFilter,
  videoGeometry,
  videoOverlay,
  audioFade,
  imageAdjust,
  output,
  /// 新版 .fppx 强制导入的未知类型节点：真实类型 ID 存 [PipelineNode.unknownTypeId]，
  /// 仅可编辑/保存/原样导出，不参与转码执行。
  unknown,
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
      case PipelineStepType.videoFilter: return '视频滤镜';
      case PipelineStepType.videoGeometry: return '画面变换';
      case PipelineStepType.videoOverlay: return '画面叠加';
      case PipelineStepType.audioFade: return '音频淡入淡出';
      case PipelineStepType.imageAdjust: return '图片调整';
      case PipelineStepType.output: return '输出';
      case PipelineStepType.unknown: return '未知节点';
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
      case PipelineStepType.videoFilter: return 'Video Filter';
      case PipelineStepType.videoGeometry: return 'Geometry';
      case PipelineStepType.videoOverlay: return 'Overlay';
      case PipelineStepType.audioFade: return 'Audio Fade';
      case PipelineStepType.imageAdjust: return 'Image Adjust';
      case PipelineStepType.output: return 'Output';
      case PipelineStepType.unknown: return 'Unknown';
    }
  }
}

// ═══════════════════════════════════════════
// 逻辑门（控制流）节点类型
// 数据流与控制流分离：逻辑门只产生/消费控制信号(0/1)，
// 通过"使能端/状态端"控制处理节点的执行，不参与媒体数据流。
// ═══════════════════════════════════════════

enum LogicGateType {
  and,    // 与门：所有输入为 1 时输出 1
  or,     // 或门：任一输入为 1 时输出 1
  not,    // 非门：单输入取反
  nand,   // 与非门：与门的非
  nor,    // 或非门：或门的非
  xor,    // 异或门：输入不同时输出 1
  xnor,   // 同或门：输入相同时输出 1
  const1, // 恒 1：恒定输出 1（无输入）
  const0, // 恒 0：恒定输出 0（无输入）
  timeTrigger; // 时间触发器：系统时间匹配时输出 1，否则 0（无输入，需配置时间/日期）

  /// 该逻辑门的常规输入数（恒1/恒0/时间触发器 为 0，非门为 1，其余为 2）
  int get inputCount => switch (this) {
    LogicGateType.not => 1,
    LogicGateType.const1 || LogicGateType.const0 || LogicGateType.timeTrigger => 0,
    _ => 2,
  };

  bool get isConstant => this == LogicGateType.const1 || this == LogicGateType.const0;

  /// ANSI/IEEE 标准符号文本（无输入端的恒1/恒0 直接用数字）
  String symbol(bool isZh) => switch (this) {
    LogicGateType.and => isZh ? '与' : 'AND',
    LogicGateType.or => isZh ? '或' : 'OR',
    LogicGateType.not => isZh ? '非' : 'NOT',
    LogicGateType.nand => isZh ? '与非' : 'NAND',
    LogicGateType.nor => isZh ? '或非' : 'NOR',
    LogicGateType.xor => isZh ? '异或' : 'XOR',
    LogicGateType.xnor => isZh ? '同或' : 'XNOR',
    LogicGateType.const1 => '1',
    LogicGateType.const0 => '0',
    LogicGateType.timeTrigger => isZh ? '时间' : 'Time',
  };
}

class PipelineNode {
  final String id;
  PipelineStepType type;
  Map<String, dynamic> params;
  double x, y;
  /// 逻辑门类型名（null 表示普通媒体处理节点）。逻辑门是控制流节点，
  /// 只通过控制连线连接"使能端/状态端"，不参与媒体数据流。
  String? gateType;
  /// 新版 .fppx 强制导入时保留的原始 16B 节点类型 ID（十进制）。
  /// 仅 [PipelineStepType.unknown] 节点携带；原样导出以保住往返。
  int? unknownTypeId;

  PipelineNode({
    required this.id, required this.type, Map<String, dynamic>? params,
    this.x = 0, this.y = 0, this.gateType, this.unknownTypeId,
  }) : params = params ?? {};

  PipelineNode copy() => PipelineNode(
    id: _uuid.v4(), type: type, params: Map.of(params),
    x: x, y: y, gateType: gateType, unknownTypeId: unknownTypeId,
  );

  /// 保留 id 的深拷贝，用于 undo/redo 快照。
  /// params 递归复制，确保快照不被后续参数编辑回溯改写；
  /// 相比 jsonEncode→jsonDecode 往返，省去字符串编解码与类型转换开销。
  PipelineNode deepCopy() => PipelineNode(
    id: id, type: type, params: deepCopyMap(params),
    x: x, y: y, gateType: gateType, unknownTypeId: unknownTypeId,
  );

  /// 递归深拷贝一个 params Map（供 PipelineNode / LogicBlock 快照共用）。
  static Map<String, dynamic> deepCopyMap(Map<String, dynamic> src) {
    final out = <String, dynamic>{};
    src.forEach((k, v) => out[k] = _deepCopyValue(v));
    return out;
  }

  static dynamic _deepCopyValue(dynamic v) {
    if (v is Map) return deepCopyMap(v.cast<String, dynamic>());
    if (v is List) return v.map(_deepCopyValue).toList();
    return v; // 标量（num/String/bool/null）不可变，直接共享
  }

  /// 是否为逻辑门节点（控制流节点）
  bool get isGate => gateType != null;

  LogicGateType? get gate =>
      gateType == null ? null : LogicGateType.values.asNameMap()[gateType];

  /// 逻辑门是否可输入（恒1/恒0 无输入）
  bool get hasGateInput => isGate && gate != null && !gate!.isConstant;
  /// 逻辑门是否可输出（所有逻辑门都有输出）
  bool get hasGateOutput => isGate;

  Map<String, dynamic> toJson() => {
    'id': id, 'type': type.name, 'params': params, 'x': x, 'y': y,
    if (gateType != null) 'gate': gateType,
    if (unknownTypeId != null) 'type_id': unknownTypeId,
  };

  factory PipelineNode.fromJson(Map<String, dynamic> json) => PipelineNode(
    id: json['id'] as String? ?? _uuid.v4(),
    type: PipelineStepType.values.firstWhere((t) => t.name == json['type'], orElse: () => PipelineStepType.unknown),
    params: (json['params'] as Map<String, dynamic>?) ?? {},
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
    gateType: (json['gate'] as String?) ?? (json['gateType'] as String?),
    unknownTypeId: (json['type_id'] as num?)?.toInt(),
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
      case PipelineStepType.videoFilter: return '视频滤镜';
      case PipelineStepType.videoGeometry: return '画面变换';
      case PipelineStepType.videoOverlay: return '画面叠加';
      case PipelineStepType.audioFade: return '音频淡入淡出';
      case PipelineStepType.imageAdjust: return '图片调整';
      case PipelineStepType.output: return '输出';
      case PipelineStepType.unknown:
        return '未知节点${unknownTypeId == null ? '' : ' $unknownTypeId'}';
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
      case PipelineStepType.videoFilter: return 'Video Filter';
      case PipelineStepType.videoGeometry: return 'Geometry';
      case PipelineStepType.videoOverlay: return 'Overlay';
      case PipelineStepType.audioFade: return 'Audio Fade';
      case PipelineStepType.imageAdjust: return 'Image Adjust';
      case PipelineStepType.output: return 'Output';
      case PipelineStepType.unknown: return 'Unknown';
    }
  }

  bool get hasInput => type != PipelineStepType.start;
  bool get hasOutput => !isGate && type != PipelineStepType.output;

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
    PipelineStepType.videoFilter => {MediaType.video},
    PipelineStepType.videoGeometry => {MediaType.video},
    PipelineStepType.videoOverlay => {MediaType.video},
    PipelineStepType.audioFade => {MediaType.audio},
    PipelineStepType.imageAdjust => {MediaType.image},
    PipelineStepType.output => {MediaType.video, MediaType.image, MediaType.audio},
    PipelineStepType.unknown => {},
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
    PipelineStepType.videoFilter => MediaType.video,
    PipelineStepType.videoGeometry => MediaType.video,
    PipelineStepType.videoOverlay => MediaType.video,
    PipelineStepType.audioFade => MediaType.audio,
    PipelineStepType.imageAdjust => MediaType.image,
    PipelineStepType.output => null,
    PipelineStepType.unknown => null,
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
  /// 连线类型：'data' 数据流（媒体载荷） / 'control' 控制流（使能/状态/逻辑信号）
  String kind;

  PipelineConnection({required this.id, required this.fromNodeId, required this.toNodeId, this.kind = 'data'});

  PipelineConnection copy() => PipelineConnection(id: _uuid.v4(), fromNodeId: fromNodeId, toNodeId: toNodeId, kind: kind);

  /// 保留 id 的拷贝（字段全为不可变标量，无需递归深拷贝），用于 undo/redo 快照。
  PipelineConnection deepCopy() => PipelineConnection(id: id, fromNodeId: fromNodeId, toNodeId: toNodeId, kind: kind);

  Map<String, dynamic> toJson() => {'id': id, 'from': fromNodeId, 'to': toNodeId, if (kind != 'data') 'kind': kind};

  factory PipelineConnection.fromJson(Map<String, dynamic> json) => PipelineConnection(
    id: json['id'] as String? ?? _uuid.v4(),
    fromNodeId: json['from'] as String? ?? '',
    toNodeId: json['to'] as String? ?? '',
    kind: (json['kind'] as String?) ?? 'data',
  );
}

// ═══════════════════════════════════════════
// 逻辑块
// ═══════════════════════════════════════════

/// 逻辑块类型。
///
/// 逻辑块的执行**全部在 Dart 端展平**（[GraphExecutor] 把块信息打到
/// `ExecutionStep` 上 → `AppState._expandLoopCalls` 复制迭代 / 生成条件跳过），
/// 因此新增类型不需要后端配合 —— 只要最终能表达成「对某组节点重复执行 N 次」
/// 或「跳过某组节点」即可。
enum LogicBlockType {
  /// 对框内节点整体重复执行 N 次（每轮产出各自独立的输出）
  loop,

  /// 每次迭代按模式（随机 / 全部 / 手动勾选）决定执行框内哪些节点
  selectiveLoop,

  /// 纯组织容器：把相关节点归拢进一个可整体拖动 / 折叠的框，**不重复执行**
  group,

  /// 条件执行：按输入文件的属性（扩展名 / 文件名 / 大小 / 路径）决定是否执行框内节点
  condition,
}

/// 条件块的判断字段。全部是**无需解码媒体**就能拿到的元数据 ——
/// 宽高时长要起 ffprobe 子进程，放在展平阶段（同步）不可行。
enum LogicConditionField { extension, filename, fileSize, inputPath, parentDir }

/// 条件块的比较方式。
enum LogicConditionOp { eq, ne, contains, startsWith, endsWith, gt, lt, ge, le }

/// 逻辑块类型的纯名称（不含后缀），工具箱 / 属性面板标题共用同一份文案。
String logicBlockTypeLabel(LogicBlockType t, bool zh) => switch (t) {
  LogicBlockType.loop => zh ? '循环' : 'Loop',
  LogicBlockType.selectiveLoop => zh ? '选择性循环' : 'Sel.Loop',
  LogicBlockType.group => zh ? '分组' : 'Group',
  LogicBlockType.condition => zh ? '条件' : 'Condition',
};

/// 逻辑块类型的一句话说明，用于工具箱预览与属性面板副标题。
String logicBlockTypeHint(LogicBlockType t, bool zh) => switch (t) {
  LogicBlockType.loop => zh ? '框内节点整体重复执行 N 次' : 'Repeat the boxed nodes N times',
  LogicBlockType.selectiveLoop =>
    zh ? '每轮按模式决定执行框内哪些节点' : 'Pick which boxed nodes run each round',
  LogicBlockType.group => zh ? '纯组织容器，不改变执行次数' : 'Organizational container only',
  LogicBlockType.condition =>
    zh ? '按输入文件属性决定是否执行' : 'Run only when the input matches',
};

String logicConditionFieldLabel(LogicConditionField f, bool zh) => switch (f) {
  LogicConditionField.extension => zh ? '扩展名' : 'Extension',
  LogicConditionField.filename => zh ? '文件名' : 'File name',
  LogicConditionField.fileSize => zh ? '文件大小' : 'File size',
  LogicConditionField.inputPath => zh ? '完整路径' : 'Full path',
  LogicConditionField.parentDir => zh ? '所在目录' : 'Parent dir',
};

String logicConditionOpLabel(LogicConditionOp op, bool zh) => switch (op) {
  LogicConditionOp.eq => zh ? '等于' : '=',
  LogicConditionOp.ne => zh ? '不等于' : '≠',
  LogicConditionOp.contains => zh ? '包含' : 'contains',
  LogicConditionOp.startsWith => zh ? '以…开头' : 'starts with',
  LogicConditionOp.endsWith => zh ? '以…结尾' : 'ends with',
  LogicConditionOp.gt => zh ? '大于' : '>',
  LogicConditionOp.lt => zh ? '小于' : '<',
  LogicConditionOp.ge => zh ? '不小于' : '≥',
  LogicConditionOp.le => zh ? '不大于' : '≤',
};

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

  /// 保留 id 的深拷贝，用于 undo/redo 快照（params 递归复制、childNodeIds 复制）。
  LogicBlock deepCopy() => LogicBlock(
    id: id, type: type, name: name,
    childNodeIds: List.of(childNodeIds),
    params: PipelineNode.deepCopyMap(params),
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

  // ── 执行语义（编辑器与 GraphExecutor / AppState 共用同一份解析）──

  /// 是否会重复执行（决定 `params['count']` 是否有意义）。
  bool get isRepeating =>
      type == LogicBlockType.loop || type == LogicBlockType.selectiveLoop;

  /// 迭代次数。
  ///
  /// - 非重复类型恒为 1；
  /// - `countMode == 'range'` 时按 `from / to / step` 折算（含首尾，例如
  ///   3→10 step2 = 4 轮：3,5,7,9）；
  /// - 其余情况取 `count`。
  ///
  /// 上限 10000 与编辑器输入校验一致：展开后每一轮都要真跑一遍，
  /// 再大就是误操作。
  int get effectiveCount {
    if (!isRepeating) return 1;
    if (params['countMode'] == 'range') {
      final from = (params['from'] as num?)?.toInt() ?? 1;
      final to = (params['to'] as num?)?.toInt() ?? 10;
      final step = math.max(1, (params['step'] as num?)?.toInt() ?? 1);
      if (to < from) return 1;
      return ((to - from) ~/ step + 1).clamp(1, 10000);
    }
    return ((params['count'] as num?)?.toInt() ?? 10).clamp(1, 10000);
  }

  /// 迭代序号的首值：固定模式恒为 1，区间模式为 `from`。
  int get iterationBase =>
      params['countMode'] == 'range' ? ((params['from'] as num?)?.toInt() ?? 1) : 1;

  /// 迭代序号的步长：固定模式恒为 1，区间模式为 `step`。
  int get iterationStep =>
      params['countMode'] == 'range' ? math.max(1, (params['step'] as num?)?.toInt() ?? 1) : 1;

  /// 第 [index]（0-based）轮迭代对应的**迭代序号**，供 `{i}` 占位符替换使用。
  int iterationNumber(int index) => iterationBase + index * iterationStep;

  /// 链式累积：每轮迭代的输入承接上一轮输出（默认每轮都从原始输入开始）。
  bool get accumulate => params['accumulate'] == true;

  /// 某轮失败时的策略：`'stop'`（默认，立即中止整个任务）/ `'continue'`（跳过继续）。
  String get errorPolicy => (params['onError'] as String?) ?? 'stop';

  /// 单轮失败重试次数（0 = 不重试），上限 10。
  int get retries => ((params['retries'] as num?)?.toInt() ?? 0).clamp(0, 10);

  LogicConditionField get conditionField => LogicConditionField.values.firstWhere(
        (f) => f.name == (params['condField'] as String?),
        orElse: () => LogicConditionField.extension,
      );

  LogicConditionOp get conditionOp => LogicConditionOp.values.firstWhere(
        (o) => o.name == (params['condOp'] as String?),
        orElse: () => LogicConditionOp.eq,
      );

  String get conditionValue => (params['condValue'] as String?) ?? '';

  /// 条件不满足时：true = 跳过框内节点继续后续步骤；false = 直接中止任务。
  bool get conditionSkipWhenFalse => params['condElse'] != 'stop';

  /// 一行式条件描述（「扩展名 等于 mp4」），供画布标签与属性面板标题使用。
  String conditionSummary(bool zh) {
    final v = conditionValue.trim();
    return '${logicConditionFieldLabel(conditionField, zh)} '
        '${logicConditionOpLabel(conditionOp, zh)} '
        '${v.isEmpty ? (zh ? '（空）' : '(empty)') : v}';
  }

  String label(bool isZh) {
    final typeName = logicBlockTypeLabel(type, isZh);
    final suffix = switch (type) {
      LogicBlockType.loop || LogicBlockType.selectiveLoop => ' x$effectiveCount',
      LogicBlockType.condition => ' · ${conditionSummary(isZh)}',
      LogicBlockType.group => ' · ${childNodeIds.length}${isZh ? ' 项' : ' items'}',
    };
    final nameStr = name.isNotEmpty ? ' · $name' : '';
    return '$typeName$suffix$nameStr';
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
      // unknownTypeId 必须一并复制：含未知节点的图被复制（撤销/重做、模板复用、
      // 容器复制）后若丢失该字段，再次导出时 type_id 变为 null，
      // 原本「原样保留、可重新导入」的未知节点会破坏 .fppx 往返契约（M-2）。
      return PipelineNode(id: newId, type: n.type, params: Map.of(n.params),
          x: n.x, y: n.y, gateType: n.gateType, unknownTypeId: n.unknownTypeId);
    }).toList();
    final newConns = connections.map((c) => PipelineConnection(
      id: _uuid.v4(),
      fromNodeId: idMap[c.fromNodeId] ?? c.fromNodeId,
      toNodeId: idMap[c.toNodeId] ?? c.toNodeId,
      kind: c.kind,
    )).toList();
    final newBlocks = logicBlocks.map((b) {
      final nb = b.copy();
      nb.childNodeIds = b.childNodeIds.map((cid) => idMap[cid] ?? cid).toList();
      return nb;
    }).toList();
    return PipelineGraph(nodes: newNodes, connections: newConns, logicBlocks: newBlocks);
  }

  /// 保留 id 的整体深拷贝，用于 undo/redo 快照与节点复制以外的场景。
  /// 相比 jsonEncode→jsonDecode 往返，省去字符串编解码、字段名查找与类型转换开销。
  PipelineGraph deepCopy() => PipelineGraph(
    nodes: nodes.map((n) => n.deepCopy()).toList(),
    connections: connections.map((c) => c.deepCopy()).toList(),
    logicBlocks: logicBlocks.map((b) => b.deepCopy()).toList(),
  );

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

  static MediaType _detectMediaType(String filepath) => detectMediaType(filepath);

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
      width: AppConfig._asInt(info['width'], 0), height: AppConfig._asInt(info['height'], 0), // [FIX M-7]
      resolution: info['resolution'] as String? ?? '',
      fps: (info['fps'] as num?)?.toDouble() ?? 0,
      pixFmt: info['pix_fmt'] as String? ?? '',
      isHdr: info['is_hdr'] as bool? ?? false,
      audioCodec: info['audio_codec'] as String? ?? '',
      audioChannels: AppConfig._asInt(info['audio_channels'], 0), // [FIX M-7]
      audioSampleRate: '${info['audio_sample_rate'] ?? 'N/A'}',
      hasSubtitles: info['has_subtitles'] as bool? ?? false,
      subtitleCount: AppConfig._asInt(info['subtitle_count'], 0), // [FIX M-7]
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
        index: (json['index'] as num?)?.toInt() ?? 0, codec: json['codec'] as String? ?? '',
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

  /// 链式累积：该轮迭代的输入承接上一轮输出（默认每轮都从原始输入开始）。
  bool accumulate;

  /// 某轮失败时的策略：`'stop'`（默认，立即中止整个任务）/ `'continue'`（跳过该轮继续）。
  String errorPolicy;

  /// 单轮失败重试次数（0 = 不重试）。
  int retries;

  /// 迭代变量占位符替换（`{i}` / `{i0}` / `{n}`）。
  /// 默认开启 —— 参数里不出现占位符时自然什么都不变。
  bool useVars;

  /// 迭代序号的首值与步长：第 k 轮（0-based）的序号 = [loopIndexBase] + k × [loopIndexStep]。
  /// 由 [LogicBlock.iterationBase] / [LogicBlock.iterationStep] 决定 ——
  /// 固定模式是 (1, 1)，区间模式是 (from, step)。展平阶段据此替换 `{i}` 占位符。
  int loopIndexBase;
  int loopIndexStep;

  BackendCall({
    required this.action,
    required this.params,
    this.loopCount = 1,
    this.loopMode,
    this.accumulate = false,
    this.errorPolicy = 'stop',
    this.retries = 0,
    this.useVars = true,
    this.loopIndexBase = 1,
    this.loopIndexStep = 1,
  });

  Map<String, dynamic> toJson() => {
    'action': action,
    'params': params,
    if (loopCount != 1) 'loop_count': loopCount,
    if (loopMode != null) 'loop_mode': loopMode,
    if (accumulate) 'accumulate': true,
    if (errorPolicy != 'stop') 'error_policy': errorPolicy,
    if (retries > 0) 'retries': retries,
  };

  factory BackendCall.fromJson(Map<String, dynamic> json) => BackendCall(
    action: json['action'] as String? ?? '',
    params: (json['params'] as Map?)?.cast<String, dynamic>() ?? {},
    loopCount: (json['loop_count'] as num?)?.toInt() ?? 1,
    loopMode: json['loop_mode'] as String?,
    accumulate: json['accumulate'] == true,
    errorPolicy: json['error_policy'] as String? ?? 'stop',
    retries: (json['retries'] as num?)?.toInt() ?? 0,
  );
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
  final List<double> callProgresses;

  TaskInfo({
    required this.id, required this.videoId, required this.filename,
    required this.inputPath, required this.outputPath,
    this.status = TaskStatus.pending, this.progress = 0,
    this.elapsed = '', this.remaining = '', this.speed = '', this.fps = '', this.bitrate = '',
    this.frame = 0, this.error, this.logLines = const [],
    required this.config, this.expanded = false, this.outputSize, this.duration, this.command,
    this.pipelineCalls, this.currentCallIndex = 0, this.callProgresses = const [],
  });

  // [FIX S-3] copyWith 为所有「语义上可清空」的可空字段增加显式清除开关（clearXxx）。
  // 现有调用点全部使用命名参数，且新参数均有默认值，向后兼容、编译不受影响。
  TaskInfo copyWith({
    TaskStatus? status, double? progress, String? elapsed, String? remaining,
    String? speed, String? fps, String? bitrate, int? frame, String? error,
    bool clearError = false,
    List<String>? logLines, bool? expanded, int? outputSize,
    bool clearOutputSize = false,
    double? duration, bool clearDuration = false,
    List<String>? command, bool clearCommand = false,
    List<BackendCall>? pipelineCalls, bool clearPipelineCalls = false,
    int? currentCallIndex, List<double>? callProgresses,
    bool clearCallProgresses = false,
  }) => TaskInfo(
        id: id, videoId: videoId, filename: filename, inputPath: inputPath, outputPath: outputPath,
        status: status ?? this.status, progress: progress ?? this.progress,
        elapsed: elapsed ?? this.elapsed, remaining: remaining ?? this.remaining,
        speed: speed ?? this.speed, fps: fps ?? this.fps, bitrate: bitrate ?? this.bitrate,
        frame: frame ?? this.frame,
        // [FIX S-3] clearError 优先：失败→重跑时先清掉旧错误，避免「处理中」与旧错误横幅并存
        error: clearError ? null : (error ?? this.error),
        logLines: logLines ?? this.logLines, config: config,
        expanded: expanded ?? this.expanded,
        outputSize: clearOutputSize ? null : (outputSize ?? this.outputSize),
        duration: clearDuration ? null : (duration ?? this.duration),
        command: clearCommand ? null : (command ?? this.command),
        pipelineCalls: clearPipelineCalls ? null : (pipelineCalls ?? this.pipelineCalls),
        currentCallIndex: currentCallIndex ?? this.currentCallIndex,
        callProgresses: clearCallProgresses ? const [] : (callProgresses ?? this.callProgresses),
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

  /// 序列化用于「处理队列结果持久化」：下次启动时恢复展示。
  /// 易变的实时字段（elapsed/speed 等进度心跳）不持久化；
  /// logLines 只保留最后 50 条，避免历史文件无限膨胀。
  Map<String, dynamic> toJson() => {
    'id': id, 'video_id': videoId, 'filename': filename,
    'input_path': inputPath, 'output_path': outputPath,
    'status': status.index, 'progress': progress,
    if (error != null) 'error': error,
    if (logLines.isNotEmpty)
      'log_lines': logLines.length > 50 ? logLines.sublist(logLines.length - 50) : logLines,
    if (outputSize != null) 'output_size': outputSize,
    if (duration != null) 'duration': duration,
    if (command != null) 'command': command,
    if (pipelineCalls != null)
      'pipeline_calls': pipelineCalls!.map((c) => c.toJson()).toList(),
    'call_progresses': callProgresses,
    'current_call_index': currentCallIndex,
  };

  factory TaskInfo.fromJson(Map<String, dynamic> json) => TaskInfo(
    id: json['id'] as String? ?? '',
    videoId: json['video_id'] as String? ?? '',
    filename: json['filename'] as String? ?? '',
    inputPath: json['input_path'] as String? ?? '',
    outputPath: json['output_path'] as String? ?? '',
    status: TaskStatus.values[
        ((json['status'] as num?)?.toInt() ?? 0).clamp(0, TaskStatus.values.length - 1)],
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    error: json['error'] as String?,
    logLines: (json['log_lines'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    config: TranscodeConfig(),
    outputSize: (json['output_size'] as num?)?.toInt(),
    duration: (json['duration'] as num?)?.toDouble(),
    command: (json['command'] as List?)?.map((e) => e.toString()).toList(),
    pipelineCalls: (json['pipeline_calls'] as List?)
        ?.whereType<Map>()
        .map((e) => BackendCall.fromJson(e.cast<String, dynamic>()))
        .toList(),
    currentCallIndex: (json['current_call_index'] as num?)?.toInt() ?? 0,
    // [FIX M-8] 逐元素容错：单个元素为 null/字符串/非数字时不再抛错，
    // 避免整条任务记录被外层 catch 静默丢弃。
    callProgresses: (json['call_progresses'] as List?)
        ?.map((e) =>
            e is num ? e.toDouble() : (e is String ? double.tryParse(e) ?? 0.0 : 0.0))
        .toList() ??
        const [],
  );

  String get outputSizeStr {
    if (outputSize == null) return '-';
    final mb = outputSize! / (1024 * 1024);
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(outputSize! / 1024).toStringAsFixed(0)} KB';
  }
}

// ═══════════════════════════════════════════
// 应用配置
// ═══════════════════════════════════════════

/// 单个模型的能力标记（用于提供商设置页的「模型」列表展示与筛选）。
///
/// 与常见 API 聚合面板的语义对齐：
/// - [chat]      对话补全（/chat/completions）
/// - [vision]    支持图片输入（多模态 T+I → T）
/// - [tools]     支持函数调用 / 工具使用
/// - [embedding] 向量嵌入模型
/// - [reasoning] 推理型模型（thinking / reasoning_effort）
class AiModelCapability {
  static const String chat = 'chat';
  static const String vision = 'vision';
  static const String tools = 'tools';
  static const String embedding = 'embedding';
  static const String reasoning = 'reasoning';

  static const List<String> all = [chat, vision, tools, embedding, reasoning];
}

/// 提供商下的一个模型条目：模型 id + 能力标记 + 每模型生成参数。
class AiModelEntry {
  String id;
  List<String> capabilities;

  /// 每模型生成参数（null = 继承提供商级别的默认值）。
  int? contextWindow;
  int? maxTokens;
  double? temperature;

  AiModelEntry({
    required this.id,
    List<String>? capabilities,
    this.contextWindow,
    this.maxTokens,
    this.temperature,
  }) : capabilities = capabilities ?? [AiModelCapability.chat];

  factory AiModelEntry.fromJson(Map<String, dynamic> json) => AiModelEntry(
        id: json['id'] as String? ?? '',
        capabilities: (json['capabilities'] as List?)
                ?.whereType<String>()
                .where(AiModelCapability.all.contains)
                .toList() ??
            [AiModelCapability.chat],
        contextWindow: (json['context_window'] as num?)?.toInt(),
        maxTokens: (json['max_tokens'] as num?)?.toInt(),
        temperature: (json['temperature'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'capabilities': capabilities,
        if (contextWindow != null) 'context_window': contextWindow,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (temperature != null) 'temperature': temperature,
      };

  AiModelEntry copy() => AiModelEntry(
        id: id,
        capabilities: [...capabilities],
        contextWindow: contextWindow,
        maxTokens: maxTokens,
        temperature: temperature,
      );
}

/// AI 供应商配置项：一组可复用的 API 配置（配置名/Key/BaseURL/请求方式/模型等）。
/// 画布 AI 面板可一键切换；配置可在设置里新建、编辑、启用、删除。
class AiProfile {
  String id;          // 唯一标识（uuid）
  String name;        // 配置名（显示用）
  bool enabled;       // 是否启用（停用后不可在面板选择）
  String provider;    // 'openai' | 'anthropic'（请求协议）
  String apiKey;
  String apiUrl;
  String model;
  int contextWindow;
  int maxTokens;
  double temperature;

  // ── 扩展字段（v5.3+；旧配置读取时全部有安全默认值，向后兼容） ──

  /// 分组名（用于在提供商列表里归类，如「白嫖」「生产」）。空 = 未分组。
  String group;

  /// 多 Key 模式：开启后按 [apiKeys] 轮换发起请求，规避单 Key 限流。
  bool multiKeyEnabled;

  /// 多 Key 列表（multiKeyEnabled 为 true 时生效；单 Key 模式仍用 apiKey）。
  List<String> apiKeys;

  /// 使用 OpenAI Responses API（/responses）而非 /chat/completions。
  bool useResponsesApi;

  /// 请求路径。与 apiUrl（Base URL）分离，便于同一 Base 切换不同端点。
  /// 例：Base = https://api.moonshot.cn/v1，路径 = /chat/completions。
  String apiPath;

  /// HTTP(S) 代理地址（空 = 直连）。例：http://127.0.0.1:7890
  String proxyUrl;

  /// 自定义请求头（会合并进请求，同名覆盖内置头）。
  Map<String, String> customHeaders;

  /// 该提供商下的模型清单（含能力标记）。空 = 仅使用 [model] 单一模型。
  List<AiModelEntry> models;

  AiProfile({
    String? id,
    this.name = 'New Profile',
    this.enabled = true,
    this.provider = 'openai',
    this.apiKey = '',
    this.apiUrl = 'https://api.openai.com/v1/chat/completions',
    this.model = 'gpt-4o',
    this.contextWindow = 128000,
    this.maxTokens = 4096,
    this.temperature = 0.3,
    this.group = '',
    this.multiKeyEnabled = false,
    List<String>? apiKeys,
    this.useResponsesApi = false,
    this.apiPath = '',
    this.proxyUrl = '',
    Map<String, String>? customHeaders,
    List<AiModelEntry>? models,
  })  : id = id ?? _uuid.v4(),
        apiKeys = apiKeys ?? <String>[],
        customHeaders = customHeaders ?? <String, String>{},
        models = models ?? <AiModelEntry>[];

  factory AiProfile.fromJson(Map<String, dynamic> json) => AiProfile(
        id: json['id'] as String?,
        name: json['name'] as String? ?? 'New Profile',
        enabled: json['enabled'] as bool? ?? true,
        provider: json['provider'] as String? ?? 'openai',
        apiKey: SecureKeyStore.decrypt(json['api_key'] as String? ?? ''),
        apiUrl: json['api_url'] as String? ?? 'https://api.openai.com/v1/chat/completions',
        model: json['model'] as String? ?? 'gpt-4o',
        contextWindow: AppConfig._asInt(json['context_window'], 128000), // [FIX M-7]
        maxTokens: AppConfig._asInt(json['max_tokens'], 4096), // [FIX M-7]
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.3,
        group: json['group'] as String? ?? '',
        multiKeyEnabled: json['multi_key_enabled'] as bool? ?? false,
        // 多 Key 与主 Key 同样加密存储
        apiKeys: (json['api_keys'] as List?)
                ?.whereType<String>()
                .map(SecureKeyStore.decrypt)
                .where((k) => k.isNotEmpty)
                .toList() ??
            <String>[],
        useResponsesApi: json['use_responses_api'] as bool? ?? false,
        apiPath: json['api_path'] as String? ?? '',
        proxyUrl: json['proxy_url'] as String? ?? '',
        customHeaders: (json['custom_headers'] as Map?)?.map(
              (k, v) => MapEntry('$k', '$v'),
            ) ??
            <String, String>{},
        models: (json['models'] as List?)
                ?.whereType<Map>()
                .map((m) => AiModelEntry.fromJson(m.cast<String, dynamic>()))
                .where((m) => m.id.isNotEmpty)
                .toList() ??
            <AiModelEntry>[],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'provider': provider,
        'api_key': SecureKeyStore.encrypt(apiKey),
        'api_url': apiUrl,
        'model': model,
        'context_window': contextWindow,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'group': group,
        'multi_key_enabled': multiKeyEnabled,
        'api_keys': apiKeys.map(SecureKeyStore.encrypt).toList(),
        'use_responses_api': useResponsesApi,
        'api_path': apiPath,
        'proxy_url': proxyUrl,
        'custom_headers': customHeaders,
        'models': models.map((m) => m.toJson()).toList(),
      };

  /// 生效的请求 URL：apiPath 非空时由 Base URL + 路径拼接，否则用 apiUrl 原值。
  /// 兼容旧配置（apiUrl 里已含完整路径、apiPath 为空）。
  String get effectiveUrl {
    if (apiPath.trim().isEmpty) return apiUrl;
    final base = apiUrl.endsWith('/')
        ? apiUrl.substring(0, apiUrl.length - 1)
        : apiUrl;
    final path = apiPath.startsWith('/') ? apiPath : '/$apiPath';
    return '$base$path';
  }

  /// 当前应使用的 Key 列表（多 Key 模式返回全部非空 Key，否则单 Key）。
  List<String> get effectiveKeys {
    if (multiKeyEnabled) {
      final keys = apiKeys.where((k) => k.trim().isNotEmpty).toList();
      if (keys.isNotEmpty) return keys;
    }
    return apiKey.trim().isEmpty ? const [] : [apiKey];
  }

  AiProfile copyWith({
    String? name,
    bool? enabled,
    String? provider,
    String? apiKey,
    String? apiUrl,
    String? model,
    int? contextWindow,
    int? maxTokens,
    double? temperature,
    String? group,
    bool? multiKeyEnabled,
    List<String>? apiKeys,
    bool? useResponsesApi,
    String? apiPath,
    String? proxyUrl,
    Map<String, String>? customHeaders,
    List<AiModelEntry>? models,
  }) =>
      AiProfile(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        provider: provider ?? this.provider,
        apiKey: apiKey ?? this.apiKey,
        apiUrl: apiUrl ?? this.apiUrl,
        model: model ?? this.model,
        contextWindow: contextWindow ?? this.contextWindow,
        maxTokens: maxTokens ?? this.maxTokens,
        temperature: temperature ?? this.temperature,
        group: group ?? this.group,
        multiKeyEnabled: multiKeyEnabled ?? this.multiKeyEnabled,
        apiKeys: apiKeys ?? [...this.apiKeys],
        useResponsesApi: useResponsesApi ?? this.useResponsesApi,
        apiPath: apiPath ?? this.apiPath,
        proxyUrl: proxyUrl ?? this.proxyUrl,
        customHeaders: customHeaders ?? {...this.customHeaders},
        models: models ?? this.models.map((m) => m.copy()).toList(),
      );
}

class AppConfig {
  String language, ffmpegPath, ffprobePath, defaultOutputDir, intermediateDir, fontFamily;
  bool darkMode;
  int themeColor;
  /// 渐变主题终点色（ARGB int）。为空＝纯色主题；非空＝主题色在
  /// themeColor → themeColor2 之间渐变（作用于跟随主题色的玻璃/卡片）。
  int themeColor2;
  double fontSize;
  int fontWeightIndex;
  String backgroundImage;
  double backgroundOpacity;
  double cardOpacity;
  // 画布背景：'global' 跟随全局玻璃效果 / 'gray' 灰色 / 'black' 黑色 / 'white' 白色
  String canvasBg;
  // 玻璃效果：'liquid' 液态玻璃 / 'blur' 模糊 / 'none' 无效果
  // （遗留字段：仅供 GlassPanel 系「非卡片」表面——桌面顶栏/侧边栏/弹窗菜单等——使用）
  String glassEffect;
  // 卡片样式（接管 设置/项目/处理队列/配置库 的卡片）：
  // 'theme' 跟随主题色(纯色) / 'liquid' 液态玻璃 / 'blur' 模糊 / 'gray' 灰色(纯色)
  String cardStyle;
  // 移动端底部菜单栏样式：与 cardStyle 同四值
  String navStyle;
  // 滑动时自动收起底部菜单栏：内容上滑（元素向上移动）收起、下滑展开。
  // 仅移动端「底部」形态生效；侧边导轨形态与桌面端不受影响。
  bool navAutoHide;
  // 移动端顶部药丸样式：与 cardStyle 同四值
  String pillStyle;
  // 桌面端菜单样式（左侧菜单栏 + 各页顶部菜单栏）：与 cardStyle 同四值。
  // 仅桌面端生效；移动端没有侧边栏/玻璃顶栏。
  String menuStyle;
  /// 软件渲染自动降级已执行过一次的标记（由 main.dart 的 _autoTuneGlass 写入）。
  ///
  /// 语义：自动降级对每个安装只**主动**执行一次。之后用户若在设置里手动把
  /// 玻璃样式重新开启，重启后不再被静默降级 —— 修复「注释承诺可在设置中
  /// 重新开启，但每次启动都重新降级回去」的矛盾（用户体感：设置不生效、
  /// 玻璃背景几秒后自己消失）。
  bool glassAutoTuned;
  // 遵循主题色：true 时玻璃/卡片底色使用主题色而非 surface 灰
  bool glassFollowTheme;
  /// 设置项以毛玻璃展示（仅「液态玻璃」生效时可开启，提升列表可读性）。
  ///
  /// 兼容视图：历史上这是与 [noCardGlass] 互相冲突的两个独立开关，
  /// 设置页同时呈现两项，语义重复（用户反馈「下面选项有重复项」）。
  /// 现在唯一的数据源是 [settingsGlassMode]，这里降级为派生属性，
  /// 所有既有读取点（GlassPanel / AppCard / AppSlider）无需改动。
  bool get settingsFrostedGlass => settingsGlassMode == 'frosted';
  /// 设置项不使用卡片玻璃效果：设置卡片跳过液态玻璃渲染，退回主题色样式。
  /// 同样是 [settingsGlassMode] 的派生视图（见上）。
  bool get noCardGlass => settingsGlassMode == 'solid';
  /// 拖动滑块时的粒子特效（默认开）。
  ///
  /// 2026-09-14 由「星点」改为「粒子」（用户要求）：粒子从填充段最右端（把手）
  /// 发射后向左散开，亮度由暗逐渐变亮，整条粒子带不超过轨道总长的 15%，
  /// 每颗粒子的消亡距离在 8%~15% 之间随机。
  ///
  /// 关闭后粒子层完全不建 Ticker / 绘制层，低配设备用来换帧率
  /// （见 widgets/app_slider.dart 的性能约定）。
  bool sliderParticles;

  // ═══ 玻璃细节参数（设置 → 样式 → 玻璃细节）═══
  //
  // 用户要求：玻璃效果要能逐项调节（模糊度 / 通透度 / 高光强度与位置 / 边缘光），
  // 而不是只给一个「有 / 无」的总开关。五项统一由 widgets/liquid_glass_fallback.dart
  // 的 GlassTuning 打包，所有玻璃渲染路径（AppCard / MobileGlassPill /
  // MobileBottomNav / LiquidGlassBackdrop / GlassPanel）都读同一份，避免各画各的。
  //
  // 默认值刻意取「与引入本项之前的像素观感一致」：
  // * glassBlur 16 = 各调用点此前的固定基准 σ（Windows 由 effectiveGlassSigma 钳到 12）；
  // * glassClarity 0.45 → tint alpha ≈ 140（原卡片 130、药丸/底栏 178，取中间值统一）；
  // * glassHighlight/glassLightPos/glassEdge 的默认值＝「不做任何改变」。
  /// 玻璃高斯模糊 σ（0~30）。0 = 完全不模糊；液态玻璃（GPU）路径只额外模糊
  /// 超过基准 16 的那部分（见 widgets/liquid_glass_fallback.dart）。
  double glassBlur;

  /// 玻璃通透度（0~1）。越大越通透（底色越淡、越接近纯模糊）。
  /// 换算：tint alpha = 255 × (1 − clarity) × cardOpacity。
  double glassClarity;

  /// 高光（镜面反射）强度（0~1.6）。1.0 = 基准。
  double glassHighlight;

  /// 高光位置（0~1）。0 = 左上角受光（基准），1 = 右下角受光。
  double glassLightPos;

  /// 边缘光强度（0~2）。作用于玻璃四周的亮边 / 倒角棱线。1.0 = 基准。
  double glassEdge;

  /// 主题色协调度（0~0.8）。「跟随主题色」的卡片与玻璃底色会用
  /// `Color.lerp(主题色, 表面色, themeTone)` —— 直接用 scheme.primary 在暗色
  /// 主题下是 tone 80 的高亮色，大面积铺开非常刺眼（用户反馈「过于明亮」）。
  /// 0 = 完全用原主题色；0.8 = 几乎并入表面色。
  double themeTone;

  /// 设置卡片（设置页卡片）的玻璃模式：
  /// 'follow' 跟随「卡片样式」/ 'frosted' 扁平毛玻璃 / 'solid' 主题色实心。
  /// 取代历史上互斥且语义重复的两个开关（settingsFrostedGlass / noCardGlass），
  /// 旧配置在 [_migrateSettingsGlass] 里自动迁移进来。
  String settingsGlassMode;
  /// 逻辑门符号标准：'ansi' ANSI/IEEE 标准 / 'iec' IEC 标准
  String gateStd;
  /// 节点编辑器右下角的小地图：显示全图节点分布与当前视口框，点击可跳转。
  /// 默认开启（大图定位神器）；它压在画布右下角，嫌挡视线可在此关闭。
  bool nodeMiniMap;
  /// 拖动节点时对齐到网格（吸附）。默认开启 —— 手工挪到「差不多对齐」的
  /// 位置在整理大图时很费神；需要像素级精确摆放时可以关掉。
  bool nodeSnap;
  /// 工具箱里被收藏（置顶）的节点类型名。存 `PipelineStepType.name`，
  /// 这样枚举改名后旧配置只会失效一条，不会反序列化失败。
  List<String> favoriteNodeTypes;
  /// 最近使用过的节点类型名，最新在前，最多保留 [_kRecentNodeLimit] 条 ——
  /// 大图编辑时 90% 的操作都集中在少数几种节点上，翻分类太慢。
  List<String> recentNodeTypes;
  /// 「最近使用」保留条数（与整份配置一起落盘，不宜过大）。
  static const int recentNodeLimit = 6;
  bool debugMode;
  bool saveLogs;
  bool enableSystemNotification;
  String logSavePath;
  /// 默认编辑方式：0 = 节点编辑器，1 = 快速模式。
  /// （传统表单模式已彻底移除；旧配置中的 2 在 fromJson 迁移为 0）
  int editMode = 0;
  /// 移动端节点编辑器默认横屏（竖屏 = false，横屏 = true）
  bool useNodeEditorLandscape;
  /// 移动端画布编辑器：顶部菜单栏(药丸)缩放系数（0.7~1.6，默认 1.0）
  double editorToolbarScale;
  /// 移动端画布编辑器：左下放大镜(缩放药丸)缩放系数（0.7~1.6，默认 1.0）
  double editorZoomScale;
  Map<String, int> nodeUsageCount;
  int maxConcurrentTasks;
  int probeThreads;
  Map<String, List<String>> keyBindings;
  bool autosaveEnabled;        // 节点编辑器自动保存草稿开关（默认开）
  int autosaveIntervalSec;     // 自动保存间隔（秒，默认 30）
  bool autoCheckUpdate;
  bool mcpEnabled;
  int mcpPort;
  String mcpHost;          // MCP 绑定地址（默认 127.0.0.1）
  bool mcpAllowWrite; // MCP 是否允许写操作（默认只读）
  bool mcpAllowFsAccess; // MCP 是否允许 list_directory/read_file_info/probe_video 访问文件系统（默认允许）
  String aiProvider; // 'openai' or 'anthropic' or 'custom'
  String aiApiKey;
  String aiApiUrl;
  String aiModel;
  bool aiEnabled;
  bool aiReadAccess;
  bool aiWriteAccess;
  bool aiAutoExecute;
  bool aiAllowAsk; // 是否允许 AI 主动向用户提问（ask_user 工具）
  bool aiShowThinking; // 是否显示模型思考过程
  bool aiAutoTitle;    // 对话后自动总结生成会话标题
  String aiTitlePrompt; // 标题生成的系统提示词（内置，可改写）
  String aiGraphMode;
  String aiSystemPrompt;
  double aiTemperature;
  int aiMaxTokens;
  int aiContextWindow; // 模型上下文窗口（token）
  String aiApproveMode; // 'auto' = 自动批准图应用; 'ask' = 每次询问
  List<String> aiAskSkipTools; // 询问模式下无需确认的操作白名单（如 'clear_all','undo','save'）
  List<AiProfile> aiProfiles; // 可复用的 AI 配置项（配置管理）
  String activeAiProfileId;   // 当前选中的配置 id（空 = 使用下方默认字段）
  // Android Monet 动态取色（跟随系统壁纸；桌面端始终关闭）
  bool useDynamicColor;
  // Android 预测式返回手势（Android 14+；仅安卓端生效，桌面/iOS 忽略）
  bool predictiveBack;
  // 关闭预加载：启动时仅构建/绘制当前页面（如项目页），其余页面
  // （处理队列、设置等）切换到时才构建。代价是首次切换页面有构建耗时
  // （可能瞬间增加 CPU 占用），收益是启动更快、启动内存更低。
  bool noPreload;
  /// PC 端是否启用 GPU 液态玻璃（oc_liquid_glass shader 折射）。
  /// 默认关闭：桌面端 ImageFilter.shader 作为 backdrop 时，纹理/坐标取向在
  /// 不同后端（Skia / Impeller-GLES / Metal / D3D）并不一致——用户反馈 PC 上
  /// 「玻璃背景倒置且不是壁纸」。关闭后桌面端走 LiquidGlassBackdrop
  /// （高斯模糊 + 倒角高光），背景即真实壁纸；想要 shader 玻璃可在
  /// 设置→外观→液态玻璃效果里手动开启。
  bool glassGpuOnDesktop;
  /// 移动端主导航位置：'auto' / 'bottom' / 'left' / 'right'（默认 'auto'）。
  ///
  /// 'auto' 按屏幕横纵比自动判定 —— 宽屏（平板 / 横屏，宽 ≥ 高 × 1.25）把菜单栏
  /// 从底部搬到**左侧**竖排导轨，纵向空间还给内容；其余保持底部胶囊。
  /// 用户可在「设置 → 外观 → 样式 → 菜单栏位置」强制指定三个方向之一。
  /// 仅移动端生效（桌面端是左侧边栏 + 顶栏，与本项无关）。
  String mobileNavPlacement;
  /// 移动端高刷新率：在支持 90 / 120 / 144Hz 的屏幕上请求该屏幕的最高刷新率
  /// （Android 专用，见 services/refresh_rate.dart + MainActivity 的原生实现）。
  /// 默认开启；关闭 = 交还系统默认刷新率（不干预），用于省电。
  bool highRefreshRate;
  /// 「样式 → 添加边框」：为所有卡片与药丸画一条用户可配置的实线描边。
  /// 默认关闭（关闭时必须与现状像素一致）；颜色/宽度由用户在设置里自己改。
  bool borderEnabled;
  /// 边框颜色（ARGB int）
  int borderColor;
  /// 边框宽度（逻辑像素，0.5 ~ 4.0）
  double borderWidth;

  static const fontWeightValues = [300, 400, 500, 600, 700];
  int get fontWeightValue => fontWeightValues[fontWeightIndex.clamp(0, 4)];

  /// 平台默认字体，用于「清除缓存」后回退（导入的字体文件已被删除）
  static String get defaultFontFamily => _defaultFontFamily;

  static const defaultKeyBindings = <String, List<String>>{
    'canvas_select_all': ['Control', 'A'],
    'canvas_delete_selected': ['Delete'],
    'canvas_undo': ['Control', 'Z'],
    'canvas_redo': ['Control', 'Shift', 'Z'],
    'canvas_probe_mode': [],
    'canvas_hide_logic': [],
    'project_select_all': ['Control', 'A'],
    'queue_add_all': ['Control', 'Shift', 'A'],
    'queue_start_all': ['Control', 'Shift', 'S'],
    'project_clear_all': ['Control', 'Shift', 'Delete'],
    'queue_stop_all': ['Control', 'Shift', 'X'],
    'canvas_pan_button': ['right'],
    'canvas_select_button': ['left'],
    'nav_projects': ['Control', '1'],
    'nav_queue': ['Control', '2'],
    'nav_command': ['Control', '3'],
    'nav_settings': ['Control', '4'],
    'project_search': ['Control', 'F'],
  };

  AppConfig({
    this.language = 'zh', this.ffmpegPath = '', this.ffprobePath = '',
    this.defaultOutputDir = '', this.intermediateDir = '', this.darkMode = true, this.themeColor = 0xFF5E6AD2, this.themeColor2 = -1,
    String? fontFamily, this.fontSize = 17.0, this.fontWeightIndex = 1,
    this.backgroundImage = '', this.backgroundOpacity = 0.8, this.cardOpacity = 0.7,
    this.canvasBg = 'global',
    this.glassEffect = 'liquid',
    this.cardStyle = 'liquid',
    this.navStyle = 'liquid',
    this.navAutoHide = false,
    this.pillStyle = 'liquid',
    this.menuStyle = 'liquid',
    this.glassAutoTuned = false,
    this.glassFollowTheme = false,
    this.sliderParticles = true,
    this.glassBlur = 16.0,
    this.glassClarity = 0.45,
    this.glassHighlight = 1.0,
    this.glassLightPos = 0.0,
    this.glassEdge = 1.0,
    this.themeTone = 0.45,
    this.settingsGlassMode = 'follow',
    this.gateStd = 'ansi',
    this.nodeMiniMap = true,
    this.nodeSnap = true,
    List<String>? favoriteNodeTypes,
    List<String>? recentNodeTypes,
    this.debugMode = false, this.saveLogs = false, this.enableSystemNotification = false, this.logSavePath = '',
    this.editMode = 0,
    this.useNodeEditorLandscape = false,
    this.editorToolbarScale = 1.0,
    this.editorZoomScale = 1.0,
    this.autosaveEnabled = true,
    this.autosaveIntervalSec = 30,
    this.maxConcurrentTasks = 1,
    this.probeThreads = 1,
    Map<String, int>? nodeUsageCount,
    Map<String, List<String>>? keyBindings,
    this.autoCheckUpdate = true,
    this.mcpEnabled = false,
    this.mcpPort = 3000,
    this.mcpHost = '127.0.0.1',
    this.mcpAllowWrite = false,
    this.mcpAllowFsAccess = true,
    this.aiProvider = 'openai',
    this.aiApiKey = '',
    this.aiApiUrl = 'https://api.openai.com/v1/chat/completions',
    this.aiModel = 'gpt-4o',
    this.aiEnabled = true,
    this.aiReadAccess = false,
    this.aiWriteAccess = false,
    this.aiAutoExecute = false,
    this.aiAllowAsk = false,
    this.aiShowThinking = true,
    this.aiAutoTitle = true,
    this.aiTitlePrompt = 'You are a title generator. Reply with ONLY a short title (max 20 chars) summarizing the conversation topic. No quotes, no punctuation.',
    this.aiGraphMode = 'redo',
    this.aiSystemPrompt = '',
    this.aiTemperature = 0.3,
    this.aiMaxTokens = 4096,
    this.aiContextWindow = 128000,
    this.aiApproveMode = 'ask',
    this.aiAskSkipTools = const ['save', 'undo', 'redo', 'error_check'],
    List<AiProfile>? aiProfiles,
    this.activeAiProfileId = '',
    this.useDynamicColor = false,
    this.predictiveBack = true,
    this.noPreload = false,
    this.glassGpuOnDesktop = false,
    this.mobileNavPlacement = 'auto',
    this.highRefreshRate = true,
    this.borderEnabled = false,
    this.borderColor = 0xFF9E9E9E,
    this.borderWidth = 1.0,
  }) : fontFamily = fontFamily ?? _defaultFontFamily,
       aiProfiles = aiProfiles ?? <AiProfile>[],
       nodeUsageCount = nodeUsageCount ?? {},
       favoriteNodeTypes = favoriteNodeTypes ?? <String>[],
       recentNodeTypes = recentNodeTypes ?? <String>[],
       keyBindings = keyBindings ?? Map.from(defaultKeyBindings);

  static bool? _softBool(dynamic v) => v is bool ? v : null;

  /// 「设置卡片玻璃」兼容迁移：新值直接通过；老配置里互斥的两个布尔开关
  /// （settings_frosted_glass / no_card_glass）折算成单一模式。
  static String _migrateSettingsGlass(Map<String, dynamic> j) {
    final raw = j['settings_glass_mode'];
    if (raw is String && const ['follow', 'frosted', 'solid'].contains(raw)) {
      return raw;
    }
    if (j['no_card_glass'] == true) return 'solid';
    if (j['settings_frosted_glass'] == true) return 'frosted';
    return 'follow';
  }

  /// 表面样式（卡片/底部菜单栏/顶部药丸）兼容迁移：
  /// 旧版 cardStyle 的 'glass' → 'liquid'、'flat' → 'gray'；新四值直接通过；
  /// 缺失/未知值回退 'liquid'（与旧默认 'glass' 观感一致）。
  static String _migrateSurfaceStyle(String? v) => switch (v) {
        'theme' || 'liquid' || 'blur' || 'gray' => v!,
        'glass' => 'liquid',
        'flat' => 'gray',
        _ => 'liquid',
      };

  static Map<String, int> _safeIntMap(dynamic v) {    if (v is! Map) return {};
    final out = <String, int>{};
    for (final e in v.entries) {
      if (e.value is num) out['${e.key}'] = (e.value as num).toInt();
    }
    return out;
  }

  /// 宽松解析字符串列表：非 List 或非字符串元素一律丢弃。
  /// 配置文件是用户可手改的，损坏的键不该让整份配置加载失败。
  static List<String> _safeStringList(dynamic v) {
    if (v is! List) return <String>[];
    return [for (final e in v) if (e is String && e.isNotEmpty) e];
  }

  static Map<String, List<String>>? _safeStringListMap(dynamic v) {
    if (v is! Map) return null;
    final out = <String, List<String>>{};
    for (final e in v.entries) {
      if (e.value is List) {
        final list = (e.value as List).whereType<String>().toList();
        out['${e.key}'] = list;
      }
    }
    return out;
  }

  // [FIX H-14] 带 NaN/Infinity 过滤与范围钳制的 double 解析。
  // JSON 含 1e999 → jsonDecode 得到 double.infinity，若不处理会令
  // app.dart 的 ((-inf) * 220).round() 抛 UnsupportedError 导致启动崩溃。
  static double _clampDouble(dynamic raw, double lo, double hi, double fb) {
    assert(lo <= hi, 'clamp 区间必须满足 lo <= hi');
    final v = (raw as num?)?.toDouble();
    if (v == null || !v.isFinite) return fb; // 缺失 / NaN / Infinity / -Infinity 均回退默认值
    return v.clamp(lo, hi).toDouble();
  }

  // [FIX M-7] 容错 int 解析：JSON 浮点 / 字符串数字都不再抛 TypeError，
  // 否则 ConfigService.load 的 catch 会把整份配置回退默认值（用户全部设置丢失）。
  static int _asInt(dynamic raw, int fb) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fb;
    return fb; // 缺失或非数字类型 → 回退默认值
  }

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        language: json['language'] as String? ?? 'zh',
        ffmpegPath: json['ffmpeg_path'] as String? ?? '',
        ffprobePath: json['ffprobe_path'] as String? ?? '',
        defaultOutputDir: json['default_output_dir'] as String? ?? '',
        intermediateDir: json['intermediate_dir'] as String? ?? '',
        darkMode: json['dark_mode'] as bool? ?? true,
        themeColor: _asInt(json['theme_color'], 0xFF5E6AD2), // [FIX M-7]
        themeColor2: _asInt(json['theme_color2'], -1), // [FIX M-7]
        fontFamily: _parseFontFamily(json['font_family']),
        fontSize: _clampDouble(json['font_size'], 8.0, 64.0, 17.0), // [FIX H-14] 字号缩放钳制 8~64
        fontWeightIndex: _asInt(json['font_weight'], 1), // [FIX M-7]
        backgroundImage: json['background_image'] as String? ?? '',
        backgroundOpacity: _clampDouble(json['background_opacity'], 0.0, 1.0, 0.8), // [FIX H-14] 透明度钳制 0~1
        glassEffect: json['glass_effect'] as String? ?? 'liquid',
        cardStyle: _migrateSurfaceStyle(json['card_style'] as String?),
        navStyle: _migrateSurfaceStyle(json['nav_style'] as String?),
        navAutoHide: json['nav_auto_hide'] as bool? ?? false,
        pillStyle: _migrateSurfaceStyle(json['pill_style'] as String?),
        menuStyle: _migrateSurfaceStyle(json['menu_style'] as String? ?? 'liquid'),
        glassAutoTuned: json['glass_auto_tuned'] as bool? ?? false,
        glassFollowTheme: json['glass_follow_theme'] as bool? ?? false,
        settingsGlassMode: _migrateSettingsGlass(json),
        // 玻璃细节参数：均可调，默认值＝引入本项之前的观感（见字段注释）
        glassBlur: _clampDouble(json['glass_blur'], 0.0, 30.0, 16.0),
        glassClarity: _clampDouble(json['glass_clarity'], 0.0, 1.0, 0.45),
        glassHighlight: _clampDouble(json['glass_highlight'], 0.0, 1.6, 1.0),
        glassLightPos: _clampDouble(json['glass_light_pos'], 0.0, 1.0, 0.0),
        glassEdge: _clampDouble(json['glass_edge'], 0.0, 2.0, 1.0),
        themeTone: _clampDouble(json['theme_tone'], 0.0, 0.8, 0.45),
        // 拖动粒子特效：新键 slider_particles，旧键 slider_stars 继续读
        //（老配置文件里写的是 slider_stars，语义完全相同）。
        sliderParticles: json['slider_particles'] as bool? ??
            json['slider_stars'] as bool? ??
            true,
        gateStd: json['gate_std'] as String? ?? 'ansi',
        nodeMiniMap: json['node_mini_map'] as bool? ?? true,
        nodeSnap: json['node_snap'] as bool? ?? true,
        favoriteNodeTypes: _safeStringList(json['favorite_node_types']),
        recentNodeTypes: _safeStringList(json['recent_node_types']),
        cardOpacity: _clampDouble(json['card_opacity'], 0.0, 1.0, 0.7), // [FIX H-14] 透明度钳制 0~1
        canvasBg: json['canvas_bg'] as String? ?? 'global',
        debugMode: json['debug_mode'] as bool? ?? false,
        saveLogs: json['save_logs'] as bool? ?? false,
        enableSystemNotification: json['enable_system_notification'] as bool? ?? false,
        logSavePath: json['log_save_path'] as String? ?? '',
        // 传统模式（旧值 2）已移除：自动迁移为节点编辑器
        // [FIX M-7] 旧值 2（传统模式）已移除→迁移为 0；用 _asInt 容错解析避免浮点 JSON 抛错
        editMode: (() {
          final v = _asInt(json['edit_mode'], 0);
          return v == 2 ? 0 : v;
        })(),
        useNodeEditorLandscape: json['use_node_editor_landscape'] as bool? ?? false,
        editorToolbarScale: _clampDouble(json['editor_toolbar_scale'], 0.5, 3.0, 1.0), // [FIX H-14] 缩放钳制 0.5~3.0
        editorZoomScale: _clampDouble(json['editor_zoom_scale'], 0.5, 3.0, 1.0), // [FIX H-14] 缩放钳制 0.5~3.0
        autosaveEnabled: json['autosave_enabled'] as bool? ?? true,
        autosaveIntervalSec: _asInt(json['autosave_interval_sec'], 30), // [FIX M-7]
        maxConcurrentTasks: _asInt(json['max_concurrent_tasks'], 1), // [FIX M-7]
        probeThreads: _asInt(json['probe_threads'], 1), // [FIX M-7]
        nodeUsageCount: _safeIntMap(json['node_usage_count']),
        keyBindings: _safeStringListMap(json['key_bindings']) ?? Map.from(defaultKeyBindings),
        autoCheckUpdate: json['auto_check_update'] as bool? ?? true,
        mcpEnabled: json['mcp_enabled'] as bool? ?? false,
        mcpPort: _asInt(json['mcp_port'], 3000), // [FIX M-7]
        mcpHost: json['mcp_host'] as String? ?? '127.0.0.1',
        mcpAllowWrite: json['mcp_allow_write'] as bool? ?? false,
        mcpAllowFsAccess: json['mcp_allow_fs'] as bool? ?? true,
        aiProvider: json['ai_provider'] as String? ?? 'openai',
        aiApiKey: SecureKeyStore.decrypt(json['ai_api_key'] as String? ?? ''),
        aiApiUrl: json['ai_api_url'] as String? ?? 'https://api.openai.com/v1/chat/completions',
        aiModel: json['ai_model'] as String? ?? 'gpt-4o',
        aiEnabled: json['ai_enabled'] as bool? ?? true,
        // 旧配置迁移：ai_read_access/ai_auto_apply 存在但类型不对时软回退，避免整份配置加载失败
        aiReadAccess: _softBool(json['ai_read_access']) ?? _softBool(json['ai_auto_apply']) ?? false,
        aiWriteAccess: json['ai_write_access'] as bool? ?? false,
        aiAutoExecute: _softBool(json['ai_auto_execute']) ?? _softBool(json['ai_auto_apply']) ?? false,
        aiAllowAsk: json['ai_allow_ask'] as bool? ?? false,
        aiShowThinking: json['ai_show_thinking'] as bool? ?? true,
        aiAutoTitle: json['ai_auto_title'] as bool? ?? true,
        aiTitlePrompt: json['ai_title_prompt'] as String? ?? 'You are a title generator. Reply with ONLY a short title (max 20 chars) summarizing the conversation topic. No quotes, no punctuation.',
        aiGraphMode: json['ai_graph_mode'] as String? ?? 'redo',
        aiSystemPrompt: json['ai_system_prompt'] as String? ?? '',
        aiTemperature: (json['ai_temperature'] as num?)?.toDouble() ?? 0.3,
        aiMaxTokens: _asInt(json['ai_max_tokens'], 4096), // [FIX M-7]
        aiContextWindow: _asInt(json['ai_context_window'], 128000), // [FIX M-7]
        aiApproveMode: json['ai_approve_mode'] as String? ?? 'ask',
        aiAskSkipTools: (json['ai_ask_skip_tools'] as List<dynamic>?)?.cast<String>() ?? const ['save', 'undo', 'redo', 'error_check'],
        aiProfiles: (json['ai_profiles'] as List<dynamic>?)?.map((e) => AiProfile.fromJson(e as Map<String, dynamic>)).toList() ?? <AiProfile>[],
        activeAiProfileId: json['active_ai_profile_id'] as String? ?? '',
        useDynamicColor: json['use_dynamic_color'] as bool? ?? false,
        predictiveBack: json['predictive_back'] as bool? ?? true,
        noPreload: json['no_preload'] as bool? ?? false,
        glassGpuOnDesktop: json['glass_gpu_on_desktop'] as bool? ?? false,
        // 移动端导航位置：非法/缺失值一律回退 'auto'（自动按横纵比判定），
        // 这样老配置文件升级后不需要迁移步骤。
        mobileNavPlacement: () {
          final v = json['mobile_nav_placement'] as String?;
          return const ['auto', 'bottom', 'left', 'right'].contains(v) ? v! : 'auto';
        }(),
        highRefreshRate: json['high_refresh_rate'] as bool? ?? true,
        borderEnabled: json['border_enabled'] as bool? ?? false,
        borderColor: _asInt(json['border_color'], 0xFF9E9E9E), // [FIX M-7]
        borderWidth: ((json['border_width'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 4.0),
      );

  Map<String, dynamic> toJson() => {
        'language': language, 'ffmpeg_path': ffmpegPath, 'ffprobe_path': ffprobePath,
        'default_output_dir': defaultOutputDir, 'intermediate_dir': intermediateDir, 'dark_mode': darkMode,
        'theme_color': themeColor, 'theme_color2': themeColor2, 'font_family': fontFamily, 'font_size': fontSize,
        'font_weight': fontWeightIndex,
        'background_image': backgroundImage, 'background_opacity': backgroundOpacity,
        'glass_effect': glassEffect,
        'card_style': cardStyle, 'nav_style': navStyle, 'pill_style': pillStyle,
        'nav_auto_hide': navAutoHide,
        'menu_style': menuStyle,
        'glass_auto_tuned': glassAutoTuned,
        'glass_follow_theme': glassFollowTheme,
        'settings_glass_mode': settingsGlassMode,
        // 兼容旧读端：两个派生布尔继续写出（读取时由 _migrateSettingsGlass 折算）
        'settings_frosted_glass': settingsFrostedGlass, 'no_card_glass': noCardGlass, 'gate_std': gateStd,
        'node_mini_map': nodeMiniMap, 'node_snap': nodeSnap,
        'favorite_node_types': favoriteNodeTypes, 'recent_node_types': recentNodeTypes,
        // 粒子特效：新键 + 旧键一起写出，回滚到旧版本也读得到同一个开关
        'slider_particles': sliderParticles, 'slider_stars': sliderParticles,
        'glass_blur': glassBlur, 'glass_clarity': glassClarity, 'glass_highlight': glassHighlight,
        'glass_light_pos': glassLightPos, 'glass_edge': glassEdge, 'theme_tone': themeTone,
        'card_opacity': cardOpacity,
        'canvas_bg': canvasBg,
        'debug_mode': debugMode,
        'save_logs': saveLogs, 'enable_system_notification': enableSystemNotification, 'log_save_path': logSavePath,
        'edit_mode': editMode,
        'use_node_editor_landscape': useNodeEditorLandscape,
        'editor_toolbar_scale': editorToolbarScale,
        'editor_zoom_scale': editorZoomScale,
        'autosave_enabled': autosaveEnabled,
        'autosave_interval_sec': autosaveIntervalSec,
        'max_concurrent_tasks': maxConcurrentTasks,
        'probe_threads': probeThreads,
        'node_usage_count': nodeUsageCount,
        'key_bindings': keyBindings,
        'auto_check_update': autoCheckUpdate,
        'mcp_enabled': mcpEnabled,
        'mcp_port': mcpPort,
        'mcp_host': mcpHost,
        'mcp_allow_write': mcpAllowWrite,
        'mcp_allow_fs': mcpAllowFsAccess,
        'ai_provider': aiProvider,
        'ai_api_key': SecureKeyStore.encrypt(aiApiKey),
        'ai_api_url': aiApiUrl,
        'ai_model': aiModel,
        'ai_enabled': aiEnabled,
        'ai_read_access': aiReadAccess,
        'ai_write_access': aiWriteAccess,
        'ai_auto_execute': aiAutoExecute,
        'ai_allow_ask': aiAllowAsk,
        'ai_show_thinking': aiShowThinking,
        'ai_auto_title': aiAutoTitle,
        'ai_title_prompt': aiTitlePrompt,
        'ai_graph_mode': aiGraphMode,
        'ai_system_prompt': aiSystemPrompt,
        'ai_temperature': aiTemperature,
        'ai_max_tokens': aiMaxTokens,
        'ai_context_window': aiContextWindow,
        'ai_approve_mode': aiApproveMode,
        'ai_ask_skip_tools': aiAskSkipTools,
        'ai_profiles': aiProfiles.map((e) => e.toJson()).toList(),
        'active_ai_profile_id': activeAiProfileId,
        'use_dynamic_color': useDynamicColor,
        'predictive_back': predictiveBack,
        'no_preload': noPreload,
        'glass_gpu_on_desktop': glassGpuOnDesktop,
        'mobile_nav_placement': mobileNavPlacement,
        'high_refresh_rate': highRefreshRate,
        'border_enabled': borderEnabled,
        'border_color': borderColor,
        'border_width': borderWidth,
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

  // [FIX M-9] 确定性 FNV-1a 32 位哈希：替代不稳定的 String.hashCode（项目已明确弃用）。
  static int _stableHash(String s) {
    var h = 0x811c9dc5;
    for (final b in s.codeUnits) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  Map<String, dynamic> toJson() => {'fileId': fileId, 'index': index};

  // [FIX M-9] 对任意畸形 JSON 都不抛异常：嵌套整条非 Map / fileId 缺失或非字符串时，
  // 用「索引 + 整条 JSON 的稳定哈希」生成唯一且可复现的回退 id，避免一个容器损坏导致整个配置库加载失败。
  factory ContainerItem.fromJson(dynamic json) {
    if (json is! Map) {
      // 列表里混入了 null / 字符串等非法元素：返回确定占位，绝不让上层 map 抛错
      return ContainerItem(fileId: '__invalid_item__', index: 0);
    }
    final map = json as Map<Object?, Object?>;
    final fileId = map['fileId'] as String?;
    final index = (map['index'] as num?)?.toInt() ?? 0;
    final id = fileId ?? '__cid_${index}_${_stableHash(map.toString())}';
    return ContainerItem(fileId: id, index: index);
  }
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
