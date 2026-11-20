import 'package:flutter/material.dart';

import '../models/models.dart';
import 'tabler_icon.dart';

/// 节点类型对应的 Tabler 图标。
///
/// 主编辑器与独立面板窗口共享此映射；新增节点时须补齐穷尽分支。
/// SVG 资源统一由 [TablerIcon] 加载。
TablerGlyph stepIconFor(PipelineStepType type) => switch (type) {
  PipelineStepType.start => TablerGlyph.movie,
  PipelineStepType.avProcess => TablerGlyph.adjustmentsHorizontal,
  PipelineStepType.subtitle => TablerGlyph.subtitles,
  PipelineStepType.clip => TablerGlyph.scissors,
  PipelineStepType.frame => TablerGlyph.camera,
  PipelineStepType.speed => TablerGlyph.gauge,
  PipelineStepType.imageConvert => TablerGlyph.photoCog,
  PipelineStepType.audioConvert => TablerGlyph.fileMusic,
  PipelineStepType.audioQuality => TablerGlyph.equalizer,
  PipelineStepType.audioSpeed => TablerGlyph.gauge,
  PipelineStepType.audioVolume => TablerGlyph.volume,
  PipelineStepType.audioCompressor => TablerGlyph.waveSine,
  PipelineStepType.audioMetadata => TablerGlyph.tag,
  PipelineStepType.extractAudio => TablerGlyph.music,
  PipelineStepType.concatMedia => TablerGlyph.arrowsJoin,
  PipelineStepType.imageToVideo => TablerGlyph.video,
  PipelineStepType.imageCrop => TablerGlyph.crop,
  PipelineStepType.imageRotate => TablerGlyph.rotateClockwise,
  PipelineStepType.imageScale => TablerGlyph.resize,
  PipelineStepType.imageBrightness => TablerGlyph.brightness,
  PipelineStepType.imageNoise => TablerGlyph.grain,
  PipelineStepType.imageSharpen => TablerGlyph.focus2,
  PipelineStepType.imageDenoise => TablerGlyph.sparkles,
  PipelineStepType.imageChannelExtract => TablerGlyph.palette,
  PipelineStepType.videoCrop => TablerGlyph.crop,
  PipelineStepType.videoFilter => TablerGlyph.wand,
  PipelineStepType.videoGeometry => TablerGlyph.aspectRatio,
  PipelineStepType.videoOverlay => TablerGlyph.layersIntersect,
  PipelineStepType.audioFade => TablerGlyph.chartLine,
  PipelineStepType.imageAdjust => TablerGlyph.adjustmentsHorizontal,
  PipelineStepType.mediaConvert => TablerGlyph.switchHorizontal,
  PipelineStepType.mediaScale => TablerGlyph.resize,
  PipelineStepType.mediaCrop => TablerGlyph.crop,
  PipelineStepType.mediaRotate => TablerGlyph.rotateClockwise,
  PipelineStepType.mediaColor => TablerGlyph.colorFilter,
  PipelineStepType.mediaSharpen => TablerGlyph.focus2,
  PipelineStepType.mediaOverlay => TablerGlyph.layersIntersect,
  PipelineStepType.output => TablerGlyph.fileExport,
  PipelineStepType.imageCompress => TablerGlyph.arrowsMinimize,
  PipelineStepType.audioNormalize => TablerGlyph.equalizer,
  PipelineStepType.audioNoiseGate => TablerGlyph.waveSquare,
  PipelineStepType.videoFrameRate => TablerGlyph.clockPlay,
  PipelineStepType.metadataStrip => TablerGlyph.eraser,
  PipelineStepType.audioDenoise => TablerGlyph.sparkles,
  PipelineStepType.audioSilenceTrim => TablerGlyph.volume3,
  PipelineStepType.videoDeinterlace => TablerGlyph.lineHeight,
  PipelineStepType.unknown => TablerGlyph.helpCircle,
  PipelineStepType.audioSpectrum => TablerGlyph.chartLine,
  PipelineStepType.audioWaveform => TablerGlyph.waveSine,
  PipelineStepType.audioReverse => TablerGlyph.rotateClockwise,
  PipelineStepType.videoReverse => TablerGlyph.rotateClockwise,
  PipelineStepType.audioEqualizer => TablerGlyph.equalizer,
  PipelineStepType.videoFade => TablerGlyph.chartLine,
};

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

/// 由 id 还原节点类型；未知 id 回退 [PipelineStepType.unknown]。
PipelineStepType stepTypeFromId(String id) => PipelineStepType.values
    .firstWhere((t) => t.name == id, orElse: () => PipelineStepType.unknown);
