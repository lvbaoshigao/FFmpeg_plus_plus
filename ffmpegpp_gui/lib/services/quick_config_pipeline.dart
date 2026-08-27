import 'package:uuid/uuid.dart';
import '../models/models.dart';

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

PipelineGraph _chain(List<PipelineNode> middles) {
  final graph = PipelineGraph();
  final start = PipelineNode(id: 'qs_${_uuid.v4()}', type: PipelineStepType.start, x: 60, y: 160);
  final output = PipelineNode(id: 'qo_${_uuid.v4()}', type: PipelineStepType.output, x: 380 + middles.length * 260, y: 160);
  graph.nodes..add(start)..addAll(middles)..add(output);
  var prev = start;
  for (final n in [...middles, output]) {
    graph.connections.add(PipelineConnection(
      id: 'qc_${_uuid.v4()}', fromNodeId: prev.id, toNodeId: n.id,
    ));
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
QuickPipelineResult buildGraphFromQuickConfig(QuickConfig cfg, {required bool isZh}) {
  final skipped = <String>[];
  final applied = <String>[];

  switch (cfg.fileType) {
    // ═══════════════════ 视频 ═══════════════════
    case QuickFileType.video:
      final avParams = <String, dynamic>{
        'video_codec': 'libx264', 'gpu': 'CPU', 'preset': 'medium',
        'audio_codec': 'aac',
      };
      final vf = <String>[];
      var hasAv = false;

      final compress = _find(cfg.items, 'compress');
      if (compress != null) {
        final rawCodec = compress.params['codec'] as String? ?? 'h264';
        final mapped = switch (rawCodec) {
          'h264' => 'libx264', 'hevc' || 'h265' => 'libx265',
          'av1' => 'libaom-av1', 'vp9' => 'libvpx-vp9',
          _ => rawCodec,
        };
        avParams['video_codec'] = mapped;
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
          skipped.add(isZh ? '码率控制参数无效，已忽略' : 'Invalid bitrate settings ignored');
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
        final angle = ((rotate.params['angle'] as num?)?.toDouble() ?? 90).round();
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
          skipped.add(isZh ? '旋转角度仅支持 90/180/270°' : 'Rotation supports 90/180/270° only');
        }
      }

      final sub = _find(cfg.items, 'subtitle');
      final subPath = (sub?.params['subtitle_path'] as String?) ?? '';

      final middle = <PipelineNode>[];
      if (sub != null && subPath.isNotEmpty) {
        middle.add(_node(PipelineStepType.subtitle, {
          'source': 'external',
          'subtitle_file': subPath,
          'subtitle_index': sub.params['index'] ?? 0,
        }, 0));
        applied.add(sub.key);
      } else if (sub != null && subPath.isEmpty) {
        skipped.add(isZh
            ? '字幕烧录未指定字幕文件路径，请到配置库编辑该项'
            : 'Subtitle enabled but no subtitle file set — edit it in Config Library');
      }
      if (hasAv || (avParams['vf_filters'] as List?)?.isNotEmpty == true) {
        middle.insert(sub != null && subPath.isNotEmpty ? 1 : 0,
            _node(PipelineStepType.avProcess, avParams, 0));
      }
      for (final k in ['watermark']) {
        if (_find(cfg.items, k) != null) {
          skipped.add(isZh
              ? '水印暂不支持一键应用，请在现场编辑中使用节点添加'
              : 'Watermark needs manual editing (node editor)');
        }
      }
      return QuickPipelineResult(_chain(middle), applied, skipped);

    // ═══════════════════ 图片 ═══════════════════
    case QuickFileType.image:
      final middle = <PipelineNode>[];
      var idx = 0;

      final resize = _find(cfg.items, 'resize');
      if (resize != null) {
        final w = (resize.params['w'] as num?)?.toInt() ?? 0;
        final h = (resize.params['h'] as num?)?.toInt() ?? 0;
        if (w > 0 || h > 0) {
          // scale_mode='absolute'：执行期用 ffprobe 探测源尺寸换算缩放系数，
          // 等比缩放以目标短边为准（保持纵横比）。
          middle.add(_node(PipelineStepType.imageScale, {
            'scale_mode': 'absolute',
            if (w > 0) 'target_w': w,
            if (h > 0) 'target_h': h,
            'fit': resize.params['fit'] ?? 'contain',
          }, idx++));
          applied.add(resize.key);
        } else {
          skipped.add(isZh ? '缩放尺寸无效' : 'Invalid resize size');
        }
      }

      final convert = _find(cfg.items, 'convert_format');
      final compressImg = _find(cfg.items, 'compress');
      // 两项都指向图片转换节点时合并成一次转换（避免多余的一步重编码）
      final fmt = (convert?.params['format'] ??
          (compressImg != null ? _normImgFmt(compressImg.params['format']) : null)) as String?;
      final quality = (compressImg?.params['quality'] as num?)?.toInt();
      if (fmt != null || quality != null) {
        middle.add(_node(PipelineStepType.imageConvert, {
          if (fmt != null) 'output_format': _normImgFmt(fmt),
          if (quality != null) 'quality': quality.clamp(0, 100),
        }, idx++));
        if (compressImg != null) applied.add(compressImg.key);
        if (convert != null) applied.add(convert.key);
      }

      final filters = _find(cfg.items, 'filters');
      if (filters != null) {
        final brightness = (filters.params['brightness'] as num?)?.toDouble() ?? 0;
        if (brightness != 0) {
          middle.add(_node(PipelineStepType.imageBrightness, {
            'brightness_mode': 'fixed',
            'brightness': brightness,
          }, idx++));
          applied.add(filters.key);
        } else if (((filters.params['contrast'] as num?) ?? 1.0) != 1.0 ||
            ((filters.params['saturation'] as num?) ?? 1.0) != 1.0) {
          skipped.add(isZh
              ? '对比度/饱和度滤镜请通过节点编辑器实现'
              : 'Contrast/saturation need the node editor');
        }
      }

      if (_find(cfg.items, 'watermark') != null) {
        skipped.add(isZh
            ? '水印暂不支持一键应用，请在现场编辑中使用节点添加'
            : 'Watermark needs manual editing (node editor)');
      }
      return QuickPipelineResult(_chain(middle), applied, skipped);

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
          'mp3': 'libmp3lame', 'aac': 'aac', 'm4a': 'aac', 'flac': 'flac',
          'opus': 'libopus', 'ogg': 'libopus', 'wav': 'pcm_s16le',
        };
        final extMap = {'m4a': 'm4a', 'aac': 'aac', 'mp3': 'mp3', 'flac': 'flac', 'opus': 'opus', 'ogg': 'ogg', 'wav': 'wav'};
        middle.add(_node(PipelineStepType.audioConvert, {
          'audio_codec': codecMap[fmtRaw] ?? 'aac',
          'output_format': extMap[fmtRaw] ?? fmtRaw,
        }, 1));
        applied.add(conv.key);
      }
      for (final key in ['channels', 'normalize']) {
        if (_find(cfg.items, key) != null) {
          skipped.add(isZh
              ? '声道调整/响度归一化需要现场编辑（节点）'
              : 'Channels/loudness normalization need the node editor');
        }
      }
      return QuickPipelineResult(_chain(middle), applied, skipped);
  }
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
