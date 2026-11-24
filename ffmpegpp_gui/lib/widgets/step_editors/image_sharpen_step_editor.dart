import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageSharpenStepEditor extends ParamsStepEditor {
  const ImageSharpenStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageSharpenStepEditor> createState() => _ImageSharpenStepEditorState();
}

class _ImageSharpenStepEditorState extends State<ImageSharpenStepEditor> with StepEditorState<ImageSharpenStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'sharpen_mode': 'value', 'sharpen_strength': 1.0, 'random_min': 0.5, 'random_max': 3.0});
  }

  @override
  Widget build(BuildContext context) {
    final mode = p['sharpen_mode'] as String? ?? 'value';
    final strength = (p['sharpen_strength'] as num?)?.toDouble() ?? 1.0;

    return StepEditorScaffold(
      title: zh ? '图片锐化' : 'Image Sharpen',
      infoText: zh ? '使用 unsharp 滤镜进行锐化。\n5x5 卷积核，强度越大锐化效果越明显。'
                   : 'Uses unsharp filter for sharpening.\n5x5 kernel, higher strength = more sharpening.',
      children: [
        EditorDropdown(
          label: zh ? '锐化模式' : 'Mode',
          value: mode,
          items: [('value', zh ? '固定强度' : 'Fixed'), ('random', zh ? '随机强度' : 'Random')],
          onChanged: (v) => update('sharpen_mode', v),
        ),
        const SizedBox(height: 8),

        if (mode == 'value') ...[
          LabeledSlider(
            text: '${zh ? "强度" : "Strength"}: ${strength.toStringAsFixed(1)}',
            value: strength.clamp(0.0, 5.0), min: 0.0, max: 5.0, divisions: 50,
            sliderLabel: strength.toStringAsFixed(1),
            onChanged: (v) => update('sharpen_strength', v),
          ),
        ] else ...[
          NumberRangeFields(
            minLabel: zh ? '最小强度' : 'Min', maxLabel: zh ? '最大强度' : 'Max',
            minText: '${(p['random_min'] as num?)?.toDouble() ?? 0.5}',
            maxText: '${(p['random_max'] as num?)?.toDouble() ?? 3.0}',
            onMinChanged: (d) => update('random_min', d),
            onMaxChanged: (d) => update('random_max', d),
          ),
        ],
      ],
    );
  }
}
