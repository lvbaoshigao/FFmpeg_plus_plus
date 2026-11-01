import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// 视频帧率转换节点编辑器。
class VideoFrameRateStepEditor extends ParamsStepEditor {
  const VideoFrameRateStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<VideoFrameRateStepEditor> createState() => _VideoFrameRateStepEditorState();
}

class _VideoFrameRateStepEditorState extends State<VideoFrameRateStepEditor>
    with StepEditorState<VideoFrameRateStepEditor> {
  static const _presets = <(double, String)>[
    (23.976, '23.976'),
    (24.0, '24'),
    (25.0, '25'),
    (29.97, '29.97'),
    (30.0, '30'),
    (50.0, '50'),
    (59.94, '59.94'),
    (60.0, '60'),
  ];

  @override
  void initState() {
    super.initState();
    initDefaults(const {'fps': 30.0, 'fps_preset': '30'});
  }

  @override
  Widget build(BuildContext context) {
    final zh = this.zh;
    final cs = Theme.of(context).colorScheme;
    final fps = (p['fps'] as num?)?.toDouble() ?? 30.0;
    final presetValue = p['fps_preset'] as String? ?? '30';
    final isCustom = presetValue == 'custom';

    return StepEditorScaffold(
      title: zh ? '视频帧率转换' : 'Video Frame Rate',
      infoText: zh
          ? '重新编码视频并输出恒定帧率（CFR），音频保持不变。\n'
              '提高帧率不会增加真实信息，只会补重复帧；降低帧率可减小体积。'
          : 'Re-encodes to a constant frame rate (CFR) while copying audio.\n'
              'Raising FPS only duplicates frames; lowering it reduces size.',
      children: [
        EditorDropdown(
          label: zh ? '目标帧率' : 'Target FPS',
          value: isCustom || _presets.every((e) => e.$2 != presetValue) ? 'custom' : presetValue,
          items: [
            for (final e in _presets) (e.$2, '${e.$2} fps'),
            ('custom', zh ? '自定义' : 'Custom'),
          ],
          onChanged: (v) {
            if (v == 'custom') {
              update('fps_preset', 'custom');
            } else {
              final parsed = double.tryParse(v);
              if (parsed != null) {
                update('fps', parsed);
                update('fps_preset', v);
              }
            }
          },
        ),
        if (isCustom) ...[
          const SizedBox(height: 8),
          TextFormField(
            initialValue: fps.toString(),
            decoration: editorDenseField(zh ? '帧率 (1-240)' : 'FPS (1-240)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) {
              final d = double.tryParse(v);
              if (d != null && d > 0 && d <= 240) update('fps', d);
            },
          ),
        ],
        const SizedBox(height: 8),
        Text(
          zh ? '当前目标：${fps.toStringAsFixed(2)} fps' : 'Target: ${fps.toStringAsFixed(2)} fps',
          style: TextStyle(fontSize: 11, color: cs.primary, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
