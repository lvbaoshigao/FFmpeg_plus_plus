import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageScaleStepEditor extends ParamsStepEditor {
  const ImageScaleStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageScaleStepEditor> createState() => _ImageScaleStepEditorState();
}

class _ImageScaleStepEditorState extends State<ImageScaleStepEditor> with StepEditorState<ImageScaleStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'scale_mode': 'factor', 'scale_factor': 1.0, 'random_min': 0.5, 'random_max': 2.0});
  }

  @override
  Widget build(BuildContext context) {
    final mode = p['scale_mode'] as String? ?? 'factor';
    final factor = (p['scale_factor'] as num?)?.toDouble() ?? 1.0;

    return StepEditorScaffold(
      title: zh ? '图片缩放' : 'Image Scale',
      infoText: zh ? '按倍数缩放图片尺寸。\n输出尺寸自动对齐为偶数像素。'
                   : 'Scale image dimensions by factor.\nOutput dimensions are automatically aligned to even pixels.',
      children: [
        EditorDropdown(
          label: zh ? '缩放模式' : 'Scale Mode',
          value: mode,
          items: [('factor', zh ? '指定倍数' : 'Factor'), ('random', zh ? '随机倍数' : 'Random')],
          onChanged: (v) => update('scale_mode', v),
        ),
        const SizedBox(height: 8),

        if (mode == 'factor') ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final f in [0.25, 0.5, 1.0, 2.0, 4.0])
              ChoiceChip(
                label: Text('${f}x'),
                selected: (factor - f).abs() < 0.01,
                onSelected: (_) => update('scale_factor', f),
              ),
          ]),
          const SizedBox(height: 8),
          LabeledSlider(
            text: '${zh ? "倍数" : "Factor"}: ${factor.toStringAsFixed(2)}x',
            value: factor.clamp(0.1, 10.0), min: 0.1, max: 10.0, divisions: 99,
            sliderLabel: '${factor.toStringAsFixed(2)}x',
            onChanged: (v) => update('scale_factor', v),
          ),
        ] else ...[
          NumberRangeFields(
            minLabel: zh ? '最小倍数' : 'Min Factor', maxLabel: zh ? '最大倍数' : 'Max Factor',
            minText: '${(p['random_min'] as num?)?.toDouble() ?? 0.5}',
            maxText: '${(p['random_max'] as num?)?.toDouble() ?? 2.0}',
            onMinChanged: (d) => update('random_min', d),
            onMaxChanged: (d) => update('random_max', d),
          ),
        ],
      ],
    );
  }
}
