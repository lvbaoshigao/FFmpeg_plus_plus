import 'package:flutter/material.dart';

import '../../models/models.dart';
import 'audio_convert_step_editor.dart';
import 'av_process_step_editor.dart';
import 'editor_kit.dart';
import 'image_adjust_step_editor.dart';
import 'image_convert_step_editor.dart';
import 'image_crop_step_editor.dart';
import 'image_rotate_step_editor.dart';
import 'image_scale_step_editor.dart';
import 'image_sharpen_step_editor.dart';
import 'video_crop_step_editor.dart';
import 'video_filter_step_editor.dart';
import 'video_geometry_step_editor.dart';
import 'video_overlay_step_editor.dart';

/// 通用节点（语义跨 音/视频/图片）的属性编辑器外壳。
///
/// 顶部是**必选**的媒体类型单选（SegmentedButton），下方按所选类型
/// 复用既有单格式编辑器 —— 参数键与对应旧节点完全一致，执行层也按
/// `media_type` 派发到既有 action，后端零改动。
///
/// 类型切换走 [PipelineNode.setGenericMediaType]（清掉不适用键，
/// 防 v2 导出 PKC_MISMATCH）；连线自动回填走 [PipelineNode.adoptGenericMediaType]。
class GenericMediaStepEditor extends StatefulWidget {
  const GenericMediaStepEditor({
    super.key,
    required this.node,
    required this.onChanged,
    this.isZh = true,
    this.videoPath,
    this.videoDuration = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.fps = 0,
    this.sourceImagePath,
  });

  final PipelineNode node;
  final VoidCallback onChanged;
  final bool isZh;
  final String? videoPath;
  final double videoDuration;
  final int videoWidth;
  final int videoHeight;
  final double fps;
  final String? sourceImagePath;

  @override
  State<GenericMediaStepEditor> createState() => _GenericMediaStepEditorState();
}

class _GenericMediaStepEditorState extends State<GenericMediaStepEditor> {
  PipelineNode get _n => widget.node;

  /// 类型选择器上方的区块（顶部小内边距 + 标题行 + 分段按钮）。
  Widget _buildTypeSelector(MediaType? current, List<MediaType> supported) {
    final cs = Theme.of(context).colorScheme;
    String label(MediaType k) => switch (k) {
      MediaType.video => widget.isZh ? '视频' : 'Video',
      MediaType.image => widget.isZh ? '图片' : 'Image',
      MediaType.audio => widget.isZh ? '音频' : 'Audio',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.category_outlined, size: 14, color: cs.outline),
          const SizedBox(width: 6),
          Text(widget.isZh ? '媒体类型（必选）' : 'Media Type (required)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<MediaType>(
            // key 含当前类型：切类型后子编辑器必然重建（initState 重跑 initDefaults）
            key: ValueKey('${_n.id}:$_kTag:${current?.name ?? 'none'}'),
            segments: [
              for (final k in supported)
                ButtonSegment(value: k, label: Text(label(k), style: const TextStyle(fontSize: 12))),
            ],
            selected: {if (current != null && supported.contains(current)) current},
            showSelectedIcon: false,
            onSelectionChanged: (sel) {
              if (sel.isEmpty) return;
              setState(() => _n.setGenericMediaType(sel.first));
              widget.onChanged();
            },
          ),
        ),
      ]),
    );
  }

  /// 未选类型时的占位提示（未选前画布不可连线、导出校验也会拦）。
  Widget _buildEmptyHint() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withAlpha(60),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outline.withAlpha(80)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.touch_app_outlined, size: 14, color: cs.outline),
          const SizedBox(width: 8),
          Expanded(child: Text(
            widget.isZh
                ? '请先在上方选择媒体类型（视频 / 图片 / 音频）。未选择前该节点无法连线，也不会参与导出与转码。'
                : 'Pick a media type above first. Until then this node cannot '
                  'be connected, exported, or executed.',
            style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
          )),
        ]),
      ),
    );
  }

  String get _kTag => _n.mediaKind?.name ?? 'none';

  /// 按类型复用既有单格式编辑器（参数键与对应旧节点完全一致）。
  Widget _buildSubEditor(MediaType k) {
    final p = _n.params;
    final zh = widget.isZh;
    final cb = widget.onChanged;
    // 子编辑器 key 带 mediaKind：保证切类型必走 initState（initDefaults 重新注入）
    switch (_n.type) {
      case PipelineStepType.mediaConvert:
        return switch (k) {
          MediaType.video => AvProcessStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh),
          MediaType.image => ImageConvertStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh),
          MediaType.audio => AudioConvertStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh),
        };
      case PipelineStepType.mediaScale:
        return k == MediaType.video
            ? VideoGeometryStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh)
            : ImageScaleStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh);
      case PipelineStepType.mediaCrop:
        return k == MediaType.video
            ? VideoCropStepEditor(
                key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh,
                videoPath: widget.videoPath ?? '',
                videoWidth: widget.videoWidth, videoHeight: widget.videoHeight, fps: widget.fps)
            : ImageCropStepEditor(
                key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh,
                sourceImagePath: widget.sourceImagePath);
      case PipelineStepType.mediaRotate:
        return k == MediaType.video
            ? VideoGeometryStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh)
            : ImageRotateStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh);
      case PipelineStepType.mediaColor:
        return k == MediaType.video
            ? VideoFilterStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh)
            : ImageAdjustStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh);
      case PipelineStepType.mediaSharpen:
        return k == MediaType.video
            ? VideoFilterStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh)
            : ImageSharpenStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh);
      case PipelineStepType.mediaOverlay:
        return VideoOverlayStepEditor(key: ValueKey('${_n.id}:$k'), params: p, onChanged: cb, isZh: zh);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = PipelineNode.genericSupportedKinds[_n.type] ?? const <MediaType>[];
    final current = _n.mediaKind;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildTypeSelector(current, supported),
      if (current == null)
        _buildEmptyHint()
      else if (supported.contains(current))
        _buildSubEditor(current)
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: EditorInfoBox(widget.isZh
              ? '当前媒体类型不支持此操作，请重新选择。'
              : 'This media type is not supported here, pick another.'),
        ),
    ]);
  }
}
