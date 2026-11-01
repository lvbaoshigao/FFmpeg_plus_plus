import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// 视频去隔行节点编辑器（FFmpeg yadif）。
class VideoDeinterlaceStepEditor extends ParamsStepEditor {
  const VideoDeinterlaceStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<VideoDeinterlaceStepEditor> createState() =>
      _VideoDeinterlaceStepEditorState();
}

class _VideoDeinterlaceStepEditorState extends State<VideoDeinterlaceStepEditor>
    with StepEditorState<VideoDeinterlaceStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'mode': 0, 'parity': -1});
  }

  @override
  Widget build(BuildContext context) {
    final zh = this.zh;
    final cs = Theme.of(context).colorScheme;
    final mode = ((p['mode'] as num?)?.toInt() ?? 0).clamp(0, 1);
    final parity = ((p['parity'] as num?)?.toInt() ?? -1).clamp(-1, 1);

    return StepEditorScaffold(
      title: zh ? '视频去隔行' : 'Video Deinterlace',
      infoText: zh
          ? 'yadif 去隔行，适合电视录制/DVD 这类隔行扫描素材。\n'
              '逐帧输出分辨率不变；逐场输出会保留更多运动细节但帧率翻倍。'
          : 'yadif deinterlacing for TV/DVD interlaced sources.\n'
              'Frame output keeps resolution; field output doubles frame rate.',
      children: [
        EditorDropdown(
          label: zh ? '输出模式' : 'Output Mode',
          value: mode.toString(),
          items: [
            ('0', zh ? '逐帧（推荐）' : 'Frame (recommended)'),
            ('1', zh ? '逐场（帧率翻倍）' : 'Field (double framerate)'),
          ],
          onChanged: (v) => update('mode', int.tryParse(v) ?? 0),
        ),
        const SizedBox(height: 8),
        EditorDropdown(
          label: zh ? '场序（parity）' : 'Field Parity',
          value: parity.toString(),
          items: [
            ('-1', zh ? '自动检测' : 'Auto detect'),
            ('0', zh ? '上场优先（TFF）' : 'Top field first'),
            ('1', zh ? '下场优先（BFF）' : 'Bottom field first'),
          ],
          onChanged: (v) => update('parity', int.tryParse(v) ?? -1),
        ),
        const SizedBox(height: 8),
        Text(
          zh
              ? '当前：${mode == 0 ? "逐帧" : "逐场"} / ${parity == -1 ? "自动场序" : parity == 0 ? "上场优先" : "下场优先"}'
              : 'Current: ${mode == 0 ? "frame" : "field"} / ${parity == -1 ? "auto" : parity == 0 ? "TFF" : "BFF"}',
          style: TextStyle(fontSize: 11, color: cs.primary, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
