import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageBrightnessStepEditor extends ParamsStepEditor {
  const ImageBrightnessStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageBrightnessStepEditor> createState() => _ImageBrightnessStepEditorState();
}

class _ImageBrightnessStepEditorState extends State<ImageBrightnessStepEditor> with StepEditorState<ImageBrightnessStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'brightness_mode': 'value', 'brightness': 0.0, 'range_min': -0.5, 'range_max': 0.5});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mode = p['brightness_mode'] as String? ?? 'value';
    final brightness = (p['brightness'] as num?)?.toDouble() ?? 0.0;

    return StepEditorScaffold(
      title: zh ? '亮度调节' : 'Brightness Adjustment',
      infoText: zh ? '使用 FFmpeg eq 滤镜调节亮度。\n范围: -1.0（全黑）到 1.0（全白），0 为不变。'
                   : 'Uses FFmpeg eq filter for brightness.\nRange: -1.0 (black) to 1.0 (white), 0 = unchanged.',
      children: [
        EditorDropdown(
          label: zh ? '调节模式' : 'Mode',
          value: mode,
          items: [('value', zh ? '固定值' : 'Fixed Value'), ('range', zh ? '指定范围' : 'Range')],
          onChanged: (v) => update('brightness_mode', v),
        ),
        const SizedBox(height: 8),

        if (mode == 'value') ...[
          LabeledSlider(
            text: '${zh ? "亮度" : "Brightness"}: ${brightness.toStringAsFixed(2)}',
            value: brightness.clamp(-1.0, 1.0), min: -1.0, max: 1.0, divisions: 200,
            sliderLabel: brightness.toStringAsFixed(2),
            onChanged: (v) => update('brightness', v),
          ),
          Text(zh ? '负值降低亮度，正值增加亮度' : 'Negative = darker, positive = brighter',
              style: TextStyle(fontSize: 11, color: cs.outline)),
        ] else ...[
          NumberRangeFields(
            minLabel: zh ? '最小值' : 'Min', maxLabel: zh ? '最大值' : 'Max',
            minText: '${(p['range_min'] as num?)?.toDouble() ?? -0.5}',
            maxText: '${(p['range_max'] as num?)?.toDouble() ?? 0.5}',
            onMinChanged: (d) => update('range_min', d),
            onMaxChanged: (d) => update('range_max', d),
          ),
          const SizedBox(height: 8),
          Text(zh ? '程序将在范围内随机取值（-1.0 ~ 1.0）' : 'Value will be picked randomly within range (-1.0 ~ 1.0)',
              style: TextStyle(fontSize: 11, color: cs.outline)),
        ],
      ],
    );
  }
}
