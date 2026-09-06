import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageRotateStepEditor extends ParamsStepEditor {
  const ImageRotateStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageRotateStepEditor> createState() => _ImageRotateStepEditorState();
}

class _ImageRotateStepEditorState extends State<ImageRotateStepEditor> with StepEditorState<ImageRotateStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'rotate_mode': 'preset', 'angle': 90.0, 'random_min': 0.0, 'random_max': 360.0});
  }

  @override
  Widget build(BuildContext context) {
    final mode = p['rotate_mode'] as String? ?? 'preset';
    final angle = (p['angle'] as num?)?.toDouble() ?? 90.0;

    return StepEditorScaffold(
      title: zh ? '图片旋转' : 'Image Rotate',
      infoText: zh ? '90°/180°/270° 使用 transpose 滤镜（无损）。\n任意角度使用 rotate 滤镜。'
                   : '90°/180°/270° use transpose filter (lossless).\nArbitrary angles use rotate filter.',
      children: [
        EditorDropdown(
          label: zh ? '旋转模式' : 'Rotate Mode',
          value: mode,
          items: [
            ('preset', zh ? '预设角度' : 'Preset'),
            ('custom', zh ? '自定义角度' : 'Custom'),
            ('random', zh ? '随机角度' : 'Random'),
          ],
          onChanged: (v) => update('rotate_mode', v),
        ),
        const SizedBox(height: 8),

        if (mode == 'preset') ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final deg in [90.0, 180.0, 270.0])
              ChoiceChip(
                label: Text('${deg.toInt()}°'),
                selected: angle == deg,
                onSelected: (_) => update('angle', deg),
              ),
          ]),
        ] else if (mode == 'custom') ...[
          LabeledSlider(
            text: '${zh ? "角度" : "Angle"}: ${angle.toStringAsFixed(1)}°',
            value: angle.clamp(0.0, 360.0), min: 0, max: 360, divisions: 720,
            sliderLabel: '${angle.toStringAsFixed(1)}°',
            onChanged: (v) => update('angle', v),
          ),
        ] else ...[
          NumberRangeFields(
            minLabel: zh ? '最小角度' : 'Min Angle', maxLabel: zh ? '最大角度' : 'Max Angle',
            minText: '${(p['random_min'] as num?)?.toDouble() ?? 0.0}',
            maxText: '${(p['random_max'] as num?)?.toDouble() ?? 360.0}',
            onMinChanged: (d) => update('random_min', d),
            onMaxChanged: (d) => update('random_max', d),
          ),
        ],
      ],
    );
  }
}
