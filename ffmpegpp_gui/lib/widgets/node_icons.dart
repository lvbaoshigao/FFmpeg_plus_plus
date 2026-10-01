import 'package:flutter/material.dart';

import '../models/models.dart';

/// 节点类型的图标与配色。
///
/// 从 `pipeline_editor_page.dart` 抽出来的原因：独立面板窗口是**另一个
/// Flutter 引擎**，没法调用页面 State 上的私有方法；而图标又不能用
/// `IconData(codePoint)` 动态构造 —— 那会让 release 构建的
/// `--tree-shake-icons` 直接报错（"non-constant instances of IconData"）。
/// 所以这里放一份**纯函数**，页面与独立窗口共用同一份图标表。
///
/// 行为与原页面内的 `_stepIcon` / `_nodeColor` 完全一致。
IconData stepIconFor(PipelineStepType t) {
  switch (t) {
    case PipelineStepType.start:
      return Icons.movie_outlined;
    case PipelineStepType.avProcess:
      return Icons.tune_outlined;
    case PipelineStepType.subtitle:
      return Icons.subtitles_outlined;
    case PipelineStepType.clip:
      return Icons.content_cut;
    case PipelineStepType.frame:
      return Icons.photo_camera_outlined;
    case PipelineStepType.speed:
      return Icons.speed;
    case PipelineStepType.imageConvert:
      return Icons.image;
    case PipelineStepType.audioConvert:
      return Icons.audiotrack;
    case PipelineStepType.audioQuality:
      return Icons.equalizer;
    case PipelineStepType.audioSpeed:
      return Icons.speed;
    case PipelineStepType.audioVolume:
      return Icons.volume_up;
    case PipelineStepType.audioCompressor:
      return Icons.compress;
    case PipelineStepType.audioMetadata:
      return Icons.library_music;
    case PipelineStepType.extractAudio:
      return Icons.music_note;
    case PipelineStepType.concatMedia:
      return Icons.merge_type;
    case PipelineStepType.imageToVideo:
      return Icons.movie_creation;
    case PipelineStepType.imageCrop:
      return Icons.crop;
    case PipelineStepType.imageRotate:
      return Icons.rotate_right;
    case PipelineStepType.imageScale:
      return Icons.photo_size_select_large;
    case PipelineStepType.imageBrightness:
      return Icons.brightness_6;
    case PipelineStepType.imageNoise:
      return Icons.grain;
    case PipelineStepType.imageSharpen:
      return Icons.deblur;
    case PipelineStepType.imageDenoise:
      return Icons.blur_on;
    case PipelineStepType.imageChannelExtract:
      return Icons.color_lens_outlined;
    case PipelineStepType.videoCrop:
      return Icons.crop_free;
    case PipelineStepType.videoFilter:
      return Icons.auto_fix_high;
    case PipelineStepType.videoGeometry:
      return Icons.aspect_ratio;
    case PipelineStepType.videoOverlay:
      return Icons.layers_outlined;
    case PipelineStepType.audioFade:
      return Icons.gradient;
    case PipelineStepType.imageAdjust:
      return Icons.tune;
    // ── 通用节点（跨格式；具体媒体类型由属性选择）──
    case PipelineStepType.mediaConvert:
      return Icons.swap_horiz;
    case PipelineStepType.mediaScale:
      return Icons.photo_size_select_large;
    case PipelineStepType.mediaCrop:
      return Icons.crop;
    case PipelineStepType.mediaRotate:
      return Icons.rotate_right;
    case PipelineStepType.mediaColor:
      return Icons.tune;
    case PipelineStepType.mediaSharpen:
      return Icons.deblur;
    case PipelineStepType.mediaOverlay:
      return Icons.layers_outlined;
    case PipelineStepType.output:
      return Icons.save_alt_outlined;
    case PipelineStepType.unknown:
      return Icons.help_outline;
  }
}

/// 节点强调底色（工具栏芯片 / 节点卡片用）。
Color nodeAccentColor(PipelineStepType t, ColorScheme scheme,
    {int? customColor}) {
  if (customColor != null) return Color(customColor).withAlpha(180);
  switch (t) {
    case PipelineStepType.start:
      return scheme.primaryContainer;
    case PipelineStepType.output:
      return scheme.tertiaryContainer;
    case PipelineStepType.mediaConvert:
    case PipelineStepType.mediaScale:
    case PipelineStepType.mediaCrop:
    case PipelineStepType.mediaRotate:
    case PipelineStepType.mediaColor:
    case PipelineStepType.mediaSharpen:
    case PipelineStepType.mediaOverlay:
      return scheme.secondaryContainer;
    default:
      return scheme.surfaceContainerHighest;
  }
}

/// 节点类型的稳定 id（跨引擎传输用；`PipelineStepType.name` 是权威来源）。
String stepTypeId(PipelineStepType t) => t.name;

/// 由 id 还原节点类型；未知 id 回退 [PipelineStepType.unknown]。
PipelineStepType stepTypeFromId(String id) => PipelineStepType.values
    .firstWhere((t) => t.name == id, orElse: () => PipelineStepType.unknown);
