import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageDenoiseStepEditor extends ParamsStepEditor {
  const ImageDenoiseStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageDenoiseStepEditor> createState() => _ImageDenoiseStepEditorState();
}

class _ImageDenoiseStepEditorState extends State<ImageDenoiseStepEditor> with StepEditorState<ImageDenoiseStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'denoise_method': 'nlmeans', 'denoise_mode': 'value', 'denoise_strength': 3.0, 'random_min': 1.0, 'random_max': 10.0});
  }

  @override
  Widget build(BuildContext context) {
    final mode = p['denoise_mode'] as String? ?? 'value';
    final method = p['denoise_method'] as String? ?? 'nlmeans';
    final strength = (p['denoise_strength'] as num?)?.toDouble() ?? 3.0;

    return StepEditorScaffold(
      title: zh ? '图片降噪' : 'Image Denoise',
      infoText: zh ? 'NLMeans: 非局部均值降噪，效果好但较慢。\nHQDN3D: 高质量3D降噪，速度快。'
                   : 'NLMeans: non-local means, better quality but slower.\nHQDN3D: high quality 3D denoise, faster.',
      children: [
        EditorDropdown(
          label: zh ? '降噪算法' : 'Method',
          value: method,
          items: [('nlmeans', 'NLMeans'), ('hqdn3d', 'HQDN3D')],
          onChanged: (v) => update('denoise_method', v),
        ),
        const SizedBox(height: 8),

        EditorDropdown(
          label: zh ? '强度模式' : 'Strength Mode',
          value: mode,
          items: [('value', zh ? '固定强度' : 'Fixed'), ('random', zh ? '随机强度' : 'Random')],
          onChanged: (v) => update('denoise_mode', v),
        ),
        const SizedBox(height: 8),

        if (mode == 'value') ...[
          LabeledSlider(
            text: '${zh ? "强度" : "Strength"}: ${strength.toStringAsFixed(1)}',
            value: strength.clamp(1.0, 20.0), min: 1.0, max: 20.0, divisions: 38,
            sliderLabel: strength.toStringAsFixed(1),
            onChanged: (v) => update('denoise_strength', v),
          ),
        ] else ...[
          NumberRangeFields(
            minLabel: zh ? '最小强度' : 'Min', maxLabel: zh ? '最大强度' : 'Max',
            minText: '${(p['random_min'] as num?)?.toDouble() ?? 1.0}',
            maxText: '${(p['random_max'] as num?)?.toDouble() ?? 10.0}',
            onMinChanged: (d) => update('random_min', d),
            onMaxChanged: (d) => update('random_max', d),
          ),
        ],
      ],
    );
  }
}
