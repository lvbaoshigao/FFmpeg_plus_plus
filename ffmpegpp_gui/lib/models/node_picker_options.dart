import 'models.dart';

/// Shared media groups for the main and detached element pickers.
enum NodePickerCategory { video, audio, image, generic, control, container, plugin }

/// Ordering within the selected category; favourites can be pinned separately.
enum NodePickerSort { name, usage }

const nodePickerGenericTypes = [
  PipelineStepType.metadataStrip,
  PipelineStepType.mediaConvert,
  PipelineStepType.mediaScale,
  PipelineStepType.mediaCrop,
  PipelineStepType.mediaRotate,
  PipelineStepType.mediaColor,
  PipelineStepType.mediaSharpen,
  PipelineStepType.mediaOverlay,
];

const nodePickerVideoTypes = [
  PipelineStepType.avProcess,
  PipelineStepType.subtitle,
  PipelineStepType.clip,
  PipelineStepType.frame,
  PipelineStepType.speed,
  PipelineStepType.extractAudio,
  PipelineStepType.videoFrameRate,
  PipelineStepType.videoDeinterlace,
  PipelineStepType.videoReverse,
  PipelineStepType.videoFade,
];

const nodePickerAudioTypes = [
  PipelineStepType.audioQuality,
  PipelineStepType.audioSpeed,
  PipelineStepType.audioVolume,
  PipelineStepType.audioCompressor,
  PipelineStepType.audioMetadata,
  PipelineStepType.audioFade,
  PipelineStepType.audioNormalize,
  PipelineStepType.audioNoiseGate,
  PipelineStepType.audioDenoise,
  PipelineStepType.audioSilenceTrim,
  PipelineStepType.audioSpectrum,
  PipelineStepType.audioWaveform,
  PipelineStepType.audioReverse,
  PipelineStepType.audioEqualizer,
];

const nodePickerImageTypes = [
  PipelineStepType.imageBrightness,
  PipelineStepType.imageNoise,
  PipelineStepType.imageDenoise,
  PipelineStepType.imageChannelExtract,
  PipelineStepType.imageCompress,
];

const nodePickerContainerTypes = [
  PipelineStepType.concatMedia,
  PipelineStepType.imageToVideo,
];

/// Keeps legacy node types classifiable without exposing them in the catalog.
NodePickerCategory? nodePickerCategoryFor(PipelineStepType type) {
  if (type == PipelineStepType.unknown) return null;
  if (type == PipelineStepType.start || type == PipelineStepType.output) {
    return NodePickerCategory.control;
  }
  if (nodePickerContainerTypes.contains(type)) {
    return NodePickerCategory.container;
  }
  if (nodePickerGenericTypes.contains(type)) return NodePickerCategory.generic;
  if (nodePickerVideoTypes.contains(type) || type.name.startsWith('video')) {
    return NodePickerCategory.video;
  }
  if (type.name.startsWith('audio')) return NodePickerCategory.audio;
  if (type.name.startsWith('image')) return NodePickerCategory.image;
  return null;
}

String nodePickerCategoryLabel(
  NodePickerCategory category, {
  bool isZh = true,
}) => switch (category) {
  NodePickerCategory.video => isZh ? '视频' : 'Video',
  NodePickerCategory.audio => isZh ? '音频' : 'Audio',
  NodePickerCategory.image => isZh ? '图片' : 'Image',
  NodePickerCategory.generic => isZh ? '通用' : 'General',
  NodePickerCategory.control => isZh ? '控制与逻辑' : 'Control & logic',
  NodePickerCategory.container => isZh ? '容器' : 'Container',
  NodePickerCategory.plugin => isZh ? '插件' : 'Plugins',
};

String nodePickerGateUsageKey(String name) => 'gate:$name';
String nodePickerBlockUsageKey(String name) => 'block:$name';

/// Orders any picker kind by frequency, then its English name and stable key.
int compareNodePickerEntries(
  String nameA,
  String nameB, {
  required String keyA,
  required String keyB,
  NodePickerSort sort = NodePickerSort.name,
  Map<String, int> usageCounts = const {},
}) {
  if (sort == NodePickerSort.usage) {
    final countA = (usageCounts[keyA] ?? 0).clamp(0, 1 << 53);
    final countB = (usageCounts[keyB] ?? 0).clamp(0, 1 << 53);
    final usageOrder = countB.compareTo(countA);
    if (usageOrder != 0) return usageOrder;
  }
  final order = nameA.toLowerCase().compareTo(nameB.toLowerCase());
  return order != 0 ? order : keyA.compareTo(keyB);
}

/// Filters before sorting and never changes the caller's catalog or counts.
List<PipelineStepType> selectNodePickerTypes(
  Iterable<PipelineStepType> types, {
  NodePickerCategory? category,
  String query = '',
  NodePickerSort sort = NodePickerSort.name,
  Map<String, int> usageCounts = const {},
}) {
  final normalized = query.trim().toLowerCase();
  final labels = <PipelineStepType, String>{};
  final result = <PipelineStepType>[];
  for (final type in types.toSet()) {
    final group = nodePickerCategoryFor(type);
    if (group == null || (category != null && group != category)) continue;
    final node = PipelineNode(id: '', type: type);
    final searchable = '${node.label} ${node.labelEn} ${type.name}'
        .toLowerCase();
    if (normalized.isNotEmpty && !searchable.contains(normalized)) continue;
    // Stable A–Z across UI languages; this is English ordering, not pinyin.
    labels[type] = node.labelEn.toLowerCase();
    result.add(type);
  }
  result.sort(
    (a, b) => compareNodePickerEntries(
      labels[a]!,
      labels[b]!,
      keyA: a.name,
      keyB: b.name,
      sort: sort,
      usageCounts: usageCounts,
    ),
  );
  return result;
}
