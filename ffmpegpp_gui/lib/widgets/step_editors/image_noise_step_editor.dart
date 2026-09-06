import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageNoiseStepEditor extends ParamsStepEditor {
  const ImageNoiseStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageNoiseStepEditor> createState() => _ImageNoiseStepEditorState();
}

class _ImageNoiseStepEditorState extends State<ImageNoiseStepEditor> with StepEditorState<ImageNoiseStepEditor> {
  @override
  void initState() {
    super.initState();
    // noise_strength 为 int；随机范围为 int（alls=参数为整数）
    initDefaults(const {'noise_mode': 'value', 'noise_strength': 10, 'noise_type': 'u', 'random_min': 5, 'random_max': 50});
  }

  @override
  Widget build(BuildContext context) {
    final mode = p['noise_mode'] as String? ?? 'value';
    final strength = (p['noise_strength'] as num?)?.toInt() ?? 10;
    final noiseType = p['noise_type'] as String? ?? 'u';

    return StepEditorScaffold(
      title: zh ? '添加噪点' : 'Add Noise',
      infoText: zh ? 'alls=强度：所有通道的噪点强度（0-100）\nallf=类型：u=均匀分布，t=时间变化，p=图案'
                   : 'alls=strength: noise intensity on all channels (0-100)\nallf=type: u=uniform, t=temporal, p=pattern',
      children: [
        EditorDropdown(
          label: zh ? '噪点类型' : 'Noise Type',
          value: noiseType,
          items: [
            ('u', zh ? '均匀分布 (Uniform)' : 'Uniform'),
            ('t', zh ? '时间变化 (Temporal)' : 'Temporal'),
            ('p', zh ? '图案噪点 (Pattern)' : 'Pattern'),
          ],
          onChanged: (v) => update('noise_type', v),
        ),
        const SizedBox(height: 8),

        EditorDropdown(
          label: zh ? '强度模式' : 'Strength Mode',
          value: mode,
          items: [('value', zh ? '固定强度' : 'Fixed'), ('random', zh ? '随机强度' : 'Random')],
          onChanged: (v) => update('noise_mode', v),
        ),
        const SizedBox(height: 8),

        if (mode == 'value') ...[
          LabeledSlider(
            text: '${zh ? "强度" : "Strength"}: $strength',
            value: strength.toDouble().clamp(0, 100), min: 0, max: 100, divisions: 100,
            sliderLabel: '$strength',
            onChanged: (v) => update('noise_strength', v.round()),
          ),
        ] else ...[
          NumberRangeFields(
            minLabel: zh ? '最小强度' : 'Min Strength', maxLabel: zh ? '最大强度' : 'Max Strength',
            minText: '${(p['random_min'] as num?)?.toInt() ?? 5}',
            maxText: '${(p['random_max'] as num?)?.toInt() ?? 50}',
            integer: true,
            onMinChanged: (d) => update('random_min', d),
            onMaxChanged: (d) => update('random_max', d),
          ),
        ],
      ],
    );
  }
}
