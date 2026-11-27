import 'dart:io' show Platform;

import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../models/node_picker_options.dart';
import 'graph_executor.dart';

/// 快捷配置 (QuickConfig) → 节点处理图 (PipelineGraph) 映射。
///
/// 背景（Bug：快速模式选完预设后"输出与输入完全相同"）：快速模式编辑只把
/// 预设存进 QuickConfigStorage，从来没有把预设项转换成真正的节点图，
/// 任务入队时 video.pipelineGraph 为空 → 走默认转码甚至纯复制，编辑效果
/// 完全丢失。本模块负责把启用中的预设项翻译成 start→(处理链)→output 图，
/// 让快速模式与节点编辑器共用同一条执行管线。
const _uuid = Uuid();

class QuickPipelineResult {
  /// 生成的节点图；[start→…→output] 至少 3 个节点。
  final PipelineGraph graph;

  /// 成功映射的预设项 key 列表。
  final List<String> appliedKeys;

  /// 无法映射 / 需要现场编辑的项的用户可读说明（中英跟随 [isZh]）。
  final List<String> skippedNotes;

  const QuickPipelineResult(this.graph, this.appliedKeys, this.skippedNotes);

  bool get isEmpty => appliedKeys.isEmpty;
}

PipelineNode _node(PipelineStepType type, Map<String, dynamic> params, int i) {
  return PipelineNode(
    id: 'qn_${_uuid.v4()}',
    type: type,
    params: params,
    x: 340 + i * 260,
    y: 120,
  );
}

PipelineGraph _chain(
  List<PipelineNode> middles, {
  required QuickFileType fileType,
  Map<String, dynamic>? inputParams,
  Map<String, dynamic>? outputParams,
}) {
  final graph = PipelineGraph();
  final start = PipelineNode(
    id: 'qs_${_uuid.v4()}',
    type: PipelineStepType.start,
    params: {...?inputParams, 'file_media_type': fileType.name},
    x: 60,
    y: 160,
  );
  final output = PipelineNode(
    id: 'qo_${_uuid.v4()}',
    type: PipelineStepType.output,
    params: outputParams,
    x: 380 + middles.length * 260,
    y: 160,
  );
  graph.nodes
    ..add(start)
    ..addAll(middles)
    ..add(output);
  var prev = start;
  for (final n in [...middles, output]) {
    graph.connections.add(
      PipelineConnection(
        id: 'qc_${_uuid.v4()}',
        fromNodeId: prev.id,
        toNodeId: n.id,
      ),
    );
    prev = n;
  }
  return graph;
}

int _parseBitrateKbps(dynamic v) {
  if (v is num) return v.toInt();
  if (v is! String) return 0;
  final s = v.trim().toLowerCase();
  final numMatch = RegExp(r'([\d.]+)').firstMatch(s)?.group(1) ?? '';
  final val = double.tryParse(numMatch) ?? 0;
  if (val <= 0) return 0;
  if (s.endsWith('m') || s.contains('mbps')) return (val * 1000).round();
  return val.round(); // kbps 或无单位
}

QuickConfigItem? _find(List<QuickConfigItem> items, String key) =>
    items.where((i) => i.key == key && i.enabled).firstOrNull;

/// 把一份快捷配置转成节点图。任何一项都无法映射时返回 appliedKeys 为空的
/// 结果，由调用方决定提示。
QuickPipelineResult buildGraphFromQuickConfig(
  QuickConfig cfg, {
  required bool isZh,
}) {
  if (cfg.nodes != null) {
    final errors = [
      ...validateQuickConfigNodes(cfg, isZh: isZh),
      ...validateQuickConfigParameters(cfg, isZh: isZh),
    ];
    if (errors.isNotEmpty) throw FormatException(errors.join('; '));
    final nodes = cfg.nodes!.map((node) => node.deepCopy()).toList();
    for (final (index, node) in nodes.indexed) {
      node.x = 340 + index * 260;
      node.y = 120;
    }
    final graph = _chain(
      nodes,
      fileType: cfg.fileType,
      inputParams: PipelineNode.deepCopyMap(cfg.inputParams),
      outputParams: PipelineNode.deepCopyMap(cfg.outputParams),
    );
    final graphErrors = GraphExecutor.validateGraph(graph);
    if (graphErrors.isNotEmpty) throw FormatException(graphErrors.join('; '));
    return QuickPipelineResult(
      graph,
      nodes.map((node) => node.id).toList(),
      const [],
    );
  }
  final skipped = <String>[];
  final applied = <String>[];

  switch (cfg.fileType) {
    // ═══════════════════ 视频 ═══════════════════
    case QuickFileType.video:
      // 默认编码：Android 优先 MediaCodec 硬编（GPU），桌面走 CPU 软编。
      // 此前硬编码 libx264/CPU，导致移动端快速模式永远软编——即使设备
      // 有 MediaCodec 可用。若当前 APK 的 ffmpeg 未编译硬编，后端 resolveEncoder
      // 会明确报「不支持的编码器」，由界面提示用户（而非无声回退）。
      final useMediaCodec = Platform.isAndroid;
      final avParams = <String, dynamic>{
        'video_codec': useMediaCodec ? 'h264_mediacodec' : 'libx264',
        'gpu': useMediaCodec ? 'Android' : 'CPU',
        'preset': 'medium',
        'audio_codec': 'aac',
      };
      final vf = <String>[];
      var hasAv = false;

      final compress = _find(cfg.items, 'compress');
      if (compress != null) {
        final rawCodec = compress.params['codec'] as String? ?? 'h264';
        if (useMediaCodec) {
          // Android 硬编：把用户选的编码格式映射到 MediaCodec 等价编码器。
          // h264/hevc 有对应硬编；av1/vp9 MediaCodec 编码支持稀少，回退 h264 硬编
          // 而不是悄悄落到 CPU 软编。
          avParams['video_codec'] = switch (rawCodec) {
            'hevc' || 'h265' || 'libx265' => 'hevc_mediacodec',
            _ => 'h264_mediacodec',
          };
        } else {
          final mapped = switch (rawCodec) {
            'h264' => 'libx264',
            'hevc' || 'h265' => 'libx265',
            'av1' => 'libaom-av1',
            'vp9' => 'libvpx-vp9',
            _ => rawCodec,
          };
          avParams['video_codec'] = mapped;
        }
        final preset = compress.params['preset'] as String?;
        if (preset != null && preset.isNotEmpty) avParams['preset'] = preset;
        hasAv = true;
        applied.add(compress.key);
      }

      final bitrateItem = _find(cfg.items, 'bitrate');
      if (bitrateItem != null) {
        final crf = bitrateItem.params['crf'];
        final kbps = _parseBitrateKbps(bitrateItem.params['bitrate']);
        if (crf is num && crf > 0) {
          avParams['rate_mode'] = 'crf';
          avParams['crf'] = crf.toInt();
        } else if (kbps > 0) {
          avParams['rate_mode'] = 'bitrate';
          avParams['video_bitrate'] = kbps;
        } else {
          skipped.add(
            isZh ? '码率控制参数无效，已忽略' : 'Invalid bitrate settings ignored',
          );
        }
        hasAv = true;
        applied.add(bitrateItem.key);
      }

      final crop = _find(cfg.items, 'crop');
      if (crop != null) {
        final w = (crop.params['w'] as num?)?.toInt() ?? 0;
        final h = (crop.params['h'] as num?)?.toInt() ?? 0;
        if (w > 0 && h > 0) {
          avParams['vf_filters'] = [
            ...vf,
            'crop=$w:$h:${(crop.params['x'] as num?)?.toInt() ?? 0}:${(crop.params['y'] as num?)?.toInt() ?? 0}',
          ];
          applied.add(crop.key);
        } else {
          skipped.add(isZh ? '裁剪尺寸无效（宽高需大于 0）' : 'Invalid crop size');
        }
      } else if (vf.isNotEmpty) {
        avParams['vf_filters'] = vf;
      }

      final rotate = _find(cfg.items, 'rotate');
      if (rotate != null) {
        final angle = ((rotate.params['angle'] as num?)?.toDouble() ?? 90)
            .round();
        final filter = switch (((angle % 360) + 360) % 360) {
          90 => 'transpose=1',
          180 => 'transpose=1,transpose=1',
          270 => 'transpose=2',
          _ => null,
        };
        if (filter != null) {
          final existing = avParams['vf_filters'] as List?;
          avParams['vf_filters'] = [...?existing, filter];
          applied.add(rotate.key);
        } else if (((angle % 360) + 360) % 360 == 0) {
          // 旋转 0° 无实际意义，跳过但不算应用成功也不算错误
        } else {
          skipped.add(
            isZh ? '旋转角度仅支持 90/180/270°' : 'Rotation supports 90/180/270° only',
          );
        }
      }

      final sub = _find(cfg.items, 'subtitle');
      final subPath = (sub?.params['subtitle_path'] as String?) ?? '';

      final middle = <PipelineNode>[];
      if (sub != null && subPath.isNotEmpty) {
        middle.add(
          _node(PipelineStepType.subtitle, {
            'source': 'external',
            'subtitle_file': subPath,
            'subtitle_index': sub.params['index'] ?? 0,
          }, 0),
        );
        applied.add(sub.key);
      } else if (sub != null && subPath.isEmpty) {
        skipped.add(
          isZh
              ? '字幕烧录未指定字幕文件路径，请到配置库编辑该项'
              : 'Subtitle enabled but no subtitle file set — edit it in Config Library',
        );
      }
      if (hasAv || (avParams['vf_filters'] as List?)?.isNotEmpty == true) {
        middle.insert(
          sub != null && subPath.isNotEmpty ? 1 : 0,
          _node(PipelineStepType.avProcess, avParams, 0),
        );
      }
      for (final k in ['watermark']) {
        if (_find(cfg.items, k) != null) {
          skipped.add(
            isZh
                ? '水印暂不支持一键应用，请在现场编辑中使用节点添加'
                : 'Watermark needs manual editing (node editor)',
          );
        }
      }
      return QuickPipelineResult(
        _chain(
          middle,
          fileType: cfg.fileType,
          inputParams: PipelineNode.deepCopyMap(cfg.inputParams),
          outputParams: PipelineNode.deepCopyMap(cfg.outputParams),
        ),
        applied,
        skipped,
      );

    // ═══════════════════ 图片 ═══════════════════
    case QuickFileType.image:
      final middle = <PipelineNode>[];
      var idx = 0;

      final resize = _find(cfg.items, 'resize');
      if (resize != null) {
        final w = (resize.params['w'] as num?)?.toInt() ?? 0;
        final h = (resize.params['h'] as num?)?.toInt() ?? 0;
        if (w > 0 || h > 0) {
          // 执行期探测源尺寸，按 fit 规划等比、裁剪、拉伸及单向缩放。
          middle.add(
            _node(PipelineStepType.imageScale, {
              'scale_mode': 'absolute',
              if (w > 0) 'target_w': w,
              if (h > 0) 'target_h': h,
              'fit': resize.params['fit'] ?? 'contain',
            }, idx++),
          );
          applied.add(resize.key);
        } else {
          skipped.add(isZh ? '缩放尺寸无效' : 'Invalid resize size');
        }
      }

      final convert = _find(cfg.items, 'convert_format');
      final compressImg = _find(cfg.items, 'compress');
      // 两项都指向图片转换节点时合并成一次转换（避免多余的一步重编码）
      final fmt =
          (convert?.params['format'] ??
                  (compressImg != null
                      ? _normImgFmt(compressImg.params['format'])
                      : null))
              as String?;
      final quality = (compressImg?.params['quality'] as num?)?.toInt();
      if (fmt != null || quality != null) {
        middle.add(
          _node(PipelineStepType.imageConvert, {
            if (fmt != null) 'output_format': _normImgFmt(fmt),
            if (quality != null) 'quality': quality.clamp(0, 100),
          }, idx++),
        );
        if (compressImg != null) applied.add(compressImg.key);
        if (convert != null) applied.add(convert.key);
      }

      final filters = _find(cfg.items, 'filters');
      if (filters != null) {
        final brightness =
            (filters.params['brightness'] as num?)?.toDouble() ?? 0;
        if (brightness != 0) {
          middle.add(
            _node(PipelineStepType.imageBrightness, {
              'brightness_mode': 'fixed',
              'brightness': brightness,
            }, idx++),
          );
          applied.add(filters.key);
        } else if (((filters.params['contrast'] as num?) ?? 1.0) != 1.0 ||
            ((filters.params['saturation'] as num?) ?? 1.0) != 1.0) {
          skipped.add(
            isZh
                ? '对比度/饱和度滤镜请通过节点编辑器实现'
                : 'Contrast/saturation need the node editor',
          );
        }
      }

      if (_find(cfg.items, 'watermark') != null) {
        skipped.add(
          isZh
              ? '水印暂不支持一键应用，请在现场编辑中使用节点添加'
              : 'Watermark needs manual editing (node editor)',
        );
      }
      return QuickPipelineResult(
        _chain(
          middle,
          fileType: cfg.fileType,
          inputParams: PipelineNode.deepCopyMap(cfg.inputParams),
          outputParams: PipelineNode.deepCopyMap(cfg.outputParams),
        ),
        applied,
        skipped,
      );

    // ═══════════════════ 音频 ═══════════════════
    case QuickFileType.audio:
      final aqParams = <String, dynamic>{};
      var hasAq = false;

      final br = _find(cfg.items, 'bitrate');
      if (br != null) {
        final kbps = _parseBitrateKbps(br.params['bitrate']);
        if (kbps > 0) {
          aqParams['audio_bitrate'] = kbps;
          hasAq = true;
          applied.add(br.key);
        } else {
          skipped.add(isZh ? '音频码率参数无效' : 'Invalid audio bitrate');
        }
      }

      final sr = _find(cfg.items, 'sample_rate');
      if (sr != null) {
        final rate = sr.params['rate'];
        if (rate is num && rate > 0) {
          aqParams['sample_rate'] = '${rate.toInt()}';
          hasAq = true;
          applied.add(sr.key);
        } else {
          skipped.add(isZh ? '采样率参数无效' : 'Invalid sample rate');
        }
      }

      final conv = _find(cfg.items, 'convert_format');
      final fmtRaw = conv?.params['format'] as String?;

      final middle = <PipelineNode>[];
      if (hasAq) middle.add(_node(PipelineStepType.audioQuality, aqParams, 0));
      if (conv != null && fmtRaw != null && fmtRaw != 'keep') {
        final codecMap = {
          'mp3': 'libmp3lame',
          'aac': 'aac',
          'm4a': 'aac',
          'flac': 'flac',
          'opus': 'libopus',
          'ogg': 'libopus',
          'wav': 'pcm_s16le',
        };
        final extMap = {
          'm4a': 'm4a',
          'aac': 'aac',
          'mp3': 'mp3',
          'flac': 'flac',
          'opus': 'opus',
          'ogg': 'ogg',
          'wav': 'wav',
        };
        middle.add(
          _node(PipelineStepType.audioConvert, {
            'audio_codec': codecMap[fmtRaw] ?? 'aac',
            'output_format': extMap[fmtRaw] ?? fmtRaw,
          }, 1),
        );
        applied.add(conv.key);
      }
      for (final key in ['channels', 'normalize']) {
        if (_find(cfg.items, key) != null) {
          skipped.add(
            isZh
                ? '声道调整/响度归一化需要现场编辑（节点）'
                : 'Channels/loudness normalization need the node editor',
          );
        }
      }
      return QuickPipelineResult(
        _chain(
          middle,
          fileType: cfg.fileType,
          inputParams: PipelineNode.deepCopyMap(cfg.inputParams),
          outputParams: PipelineNode.deepCopyMap(cfg.outputParams),
        ),
        applied,
        skipped,
      );
  }
}

/// 导出与应用共用完整映射，避免把不完整预设导出成另一条可执行流程。
PipelineGraph buildApplicableQuickConfigGraph(
  QuickConfig config, {
  required bool isZh,
}) {
  final result = buildGraphFromQuickConfig(config, isZh: isZh);
  final errors = [...result.skippedNotes];
  if (result.isEmpty) {
    errors.add(
      isZh
          ? '快捷配置没有可应用的处理节点'
          : 'Quick configuration has no applicable processing nodes',
    );
  }
  errors.addAll(GraphExecutor.validateGraph(result.graph));
  if (errors.isNotEmpty) throw FormatException(errors.join('; '));
  return result.graph;
}

String _normImgFmt(dynamic f) {
  final v = (f as String?)?.toLowerCase() ?? '';
  return switch (v) {
    'jpeg' => 'jpg',
    'tif' => 'tiff',
    '' => 'png',
    _ => v,
  };
}

/// 媒体类型使用主节点模型同源的输入/输出约束。
MediaType quickMediaType(QuickFileType type) =>
    MediaType.values.byName(type.name);

bool _isQuickProcessingNode(PipelineNode node) =>
    !node.isGate &&
    node.type != PipelineStepType.start &&
    node.type != PipelineStepType.output &&
    node.type != PipelineStepType.unknown &&
    node.type != PipelineStepType.concatMedia;

/// 单文件快捷流程不提供逻辑门、源/输出或多文件合并节点。
/// 保留同类型多次添加；可用性跟随当前链末端（如提取音频后仅显示音频操作）。
List<PipelineStepType> availableQuickNodeTypes(
  QuickFileType fileType, {
  List<PipelineNode> nodes = const [],
}) {
  var media = quickMediaType(fileType);
  var frameSet = false;
  for (final node in nodes) {
    if (!_acceptsQuickInput(node, media) ||
        (frameSet && node.type != PipelineStepType.imageToVideo)) {
      return const [];
    }
    media = node.outputType!;
    frameSet = _outputsFrameSet(node);
  }
  if (frameSet) return const [PipelineStepType.imageToVideo];
  return [
    for (final type in [
      ...nodePickerGenericTypes,
      ...nodePickerVideoTypes,
      ...nodePickerAudioTypes,
      ...nodePickerImageTypes,
      PipelineStepType.imageToVideo,
    ])
      if (_acceptsQuickInput(_quickCandidate(type, media), media)) type,
  ];
}

PipelineNode _quickCandidate(PipelineStepType type, MediaType media) =>
    PipelineNode(id: '', type: type)..adoptGenericMediaType(media);

bool _acceptsQuickInput(PipelineNode node, MediaType media) =>
    _isQuickProcessingNode(node) &&
    (!node.isGenericMedia ||
        (PipelineNode.genericSupportedKinds[node.type]?.contains(media) ??
            false)) &&
    node.inputTypes.contains(media) &&
    node.outputType != null;

/// 创建独立处理节点，通用节点直接采用上游媒体类型。
PipelineNode createQuickConfigNode(PipelineStepType type, MediaType inputType) {
  final node = _quickCandidate(type, inputType);
  if (!_acceptsQuickInput(node, inputType)) {
    throw ArgumentError('Node ${type.name} does not accept ${inputType.name}');
  }
  return _node(type, PipelineNode.deepCopyMap(node.params), 0);
}

bool _outputsFrameSet(PipelineNode node) =>
    node.type == PipelineStepType.frame &&
    (node.params['extract_mode'] ?? 'single') != 'single';

/// 保存和执行前共用的串行链校验；不重排、不跳过不兼容节点。
List<String> validateQuickConfigNodes(QuickConfig config, {bool isZh = true}) {
  final errors = <String>[];
  var media = quickMediaType(config.fileType);
  final ids = <String>{};
  var frameSet = false;
  for (final (index, node) in (config.nodes ?? <PipelineNode>[]).indexed) {
    final name = isZh ? node.label : node.labelEn;
    if (node.id.isEmpty || !ids.add(node.id)) {
      errors.add(
        isZh
            ? '第 ${index + 1} 个节点标识重复或为空'
            : 'Node ${index + 1} has a duplicate or empty ID',
      );
    }
    if (!_acceptsQuickInput(node, media)) {
      errors.add(
        isZh
            ? '第 ${index + 1} 个节点「$name」不兼容当前媒体（${media.name}）或不是单文件处理节点'
            : 'Node ${index + 1} ($name) is incompatible with ${media.name} or is not a single-file processor',
      );
    }
    if (frameSet && node.type != PipelineStepType.imageToVideo) {
      errors.add(
        isZh
            ? '多帧提取输出为文件夹，只能放在末尾或接图片合成视频节点'
            : 'Multi-frame extraction produces a folder; end the sequence here or add Image to Video',
      );
    }
    frameSet = _outputsFrameSet(node);
    if (node.outputType != null) media = node.outputType!;
  }
  return errors;
}

/// 不依赖编辑器是否被打开的参数校验，防止空裁剪尺寸等配置直接进入执行队列。
List<String> validateQuickConfigParameters(
  QuickConfig config, {
  bool isZh = true,
}) {
  final errors = <String>[];
  for (final (index, node) in (config.nodes ?? <PipelineNode>[]).indexed) {
    if (node.type == PipelineStepType.mediaCrop ||
        node.type == PipelineStepType.imageCrop ||
        node.type == PipelineStepType.videoCrop) {
      final width = node.params['crop_w'];
      final height = node.params['crop_h'];
      if (width is! num ||
          !width.isFinite ||
          width < 1 ||
          height is! num ||
          !height.isFinite ||
          height < 1) {
        errors.add(
          isZh
              ? '第 ${index + 1} 个裁剪节点需要配置至少 1 像素的宽度和高度，请点击节点设置裁剪区域'
              : 'Crop node ${index + 1} needs a positive width and height (at least 1 pixel); open the node to set its crop area',
        );
      }
    }
  }
  return errors;
}

/// 从严格的 source → processors → output 图恢复快捷配置。
/// 分支、孤立节点、逻辑门/块及未知节点均拒绝转换，绝不静默截断原流程。
QuickConfig quickConfigFromGraph({
  required PipelineGraph graph,
  required QuickFileType fileType,
  String? id,
  String name = '',
}) {
  QuickConfig empty() => QuickConfig(
    id: id ?? _uuid.v4(),
    fileType: fileType,
    name: name,
    nodes: [],
  );
  if (graph.logicBlocks.isNotEmpty ||
      graph.nodes.any((node) => node.isGate) ||
      graph.connections.any((edge) => edge.kind != 'data')) {
    throw const FormatException(
      'Quick configuration requires a serial graph without logic nodes or blocks',
    );
  }
  if (graph.nodes.isEmpty && graph.connections.isEmpty) return empty();
  final byId = {for (final node in graph.nodes) node.id: node};
  final starts = graph.nodes
      .where((node) => node.type == PipelineStepType.start)
      .toList();
  final outputs = graph.nodes
      .where((node) => node.type == PipelineStepType.output)
      .toList();
  if (byId.length != graph.nodes.length ||
      starts.length != 1 ||
      outputs.length != 1 ||
      graph.connections.length != graph.nodes.length - 1) {
    throw const FormatException(
      'Quick configuration requires exactly one source and one serial output',
    );
  }
  final incoming = <String, int>{};
  final next = <String, String>{};
  for (final edge in graph.connections) {
    if (!byId.containsKey(edge.fromNodeId) ||
        !byId.containsKey(edge.toNodeId) ||
        next.containsKey(edge.fromNodeId)) {
      throw const FormatException(
        'Quick configuration cannot restore branches or invalid connections',
      );
    }
    next[edge.fromNodeId] = edge.toNodeId;
    incoming[edge.toNodeId] = (incoming[edge.toNodeId] ?? 0) + 1;
  }
  if ((incoming[starts.single.id] ?? 0) != 0 ||
      next.containsKey(outputs.single.id) ||
      incoming.values.any((count) => count != 1)) {
    throw const FormatException(
      'Quick configuration cannot restore branches or cycles',
    );
  }
  final seen = <String>{};
  final ordered = <PipelineNode>[];
  PipelineNode? cursor = starts.single;
  while (cursor != null && seen.add(cursor.id)) {
    ordered.add(cursor);
    cursor = byId[next[cursor.id]];
  }
  if (seen.length != graph.nodes.length ||
      ordered.last.id != outputs.single.id) {
    throw const FormatException(
      'Quick configuration cannot restore cycles or disconnected nodes',
    );
  }
  final config = empty()
    ..nodes = ordered
        .skip(1)
        .take(ordered.length - 2)
        .map((node) => node.deepCopy())
        .toList()
    ..inputParams = PipelineNode.deepCopyMap(starts.single.params)
    ..outputParams = PipelineNode.deepCopyMap(outputs.single.params);
  final errors = validateQuickConfigNodes(config, isZh: false);
  if (errors.isNotEmpty) throw FormatException(errors.join('; '));
  return config;
}
