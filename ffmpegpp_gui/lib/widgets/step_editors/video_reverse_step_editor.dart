import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// Explains video and audio reversal without adding node parameters.
class VideoReverseStepEditor extends ParamsStepEditor {
  const VideoReverseStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<VideoReverseStepEditor> createState() => _VideoReverseStepEditorState();
}

class _VideoReverseStepEditorState extends State<VideoReverseStepEditor> {
  @override
  Widget build(BuildContext context) => StepEditorScaffold(
    title: widget.isZh ? '视频倒放' : 'Video reverse',
    description: widget.isZh
        ? '将画面和原有音轨一起从结尾倒放到开头。'
        : 'Play the video and its audio track backward from end to start.',
    scrollable: true,
    infoText: widget.isZh
        ? '倒放需要缓存完整素材，较长素材会占用更多内存。建议先用裁剪节点缩短素材。'
        : 'Reversal buffers the full source in memory. Trim long sources first to reduce memory use.',
    children: [
      Text(
        widget.isZh
            ? '无需专用参数，连接素材后即可使用。'
            : 'No specific settings are needed. Connect a source to use this node.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  );
}
