import 'package:flutter/material.dart';
import 'editor_kit.dart';

class AudioSpeedStepEditor extends ParamsStepEditor {
  const AudioSpeedStepEditor({super.key, required super.params, required super.onChanged, super.isZh});
  @override
  State<AudioSpeedStepEditor> createState() => _AudioSpeedStepEditorState();
}

class _AudioSpeedStepEditorState extends State<AudioSpeedStepEditor> with StepEditorState<AudioSpeedStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'atempo': 1.0});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tempo = (p['atempo'] as num?)?.toDouble() ?? 1.0;

    return StepEditorScaffold(
      title: zh ? '调整速度' : 'Audio Speed',
      infoText: zh ? '使用 atempo 滤镜调整音频播放速度。\n范围: 0.5x (半速) ~ 4.0x (4倍速)\n不改变音高。'
                   : 'Uses atempo filter to adjust playback speed.\nRange: 0.5x (half) ~ 4.0x (quadruple)\nPitch is preserved.',
      children: [
        Row(children: [
          Text(zh ? '速度: ${tempo.toStringAsFixed(2)}x' : 'Speed: ${tempo.toStringAsFixed(2)}x',
              style: TextStyle(fontSize: 12, color: cs.onSurface)),
          const Spacer(),
          TextButton(onPressed: () => update('atempo', 1.0),
              child: Text(zh ? '重置' : 'Reset', style: const TextStyle(fontSize: 11))),
        ]),
        Row(children: [
          Expanded(child: Slider(
            value: tempo.clamp(0.5, 4.0),
            min: 0.5, max: 4.0, divisions: 70,
            label: '${tempo.toStringAsFixed(2)}x',
            onChanged: (v) => update('atempo', double.parse(v.toStringAsFixed(2))),
          )),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final preset in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0])
            ChoiceChip(
              label: Text('${preset}x', style: const TextStyle(fontSize: 11)),
              selected: (tempo - preset).abs() < 0.01,
              onSelected: (_) => update('atempo', preset),
              visualDensity: VisualDensity.compact,
            ),
        ]),
      ],
    );
  }
}
