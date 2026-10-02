import 'package:flutter/material.dart';
import 'editor_kit.dart';

/// 音频淡入 / 淡出（afade）。
///
/// 参数：
/// - `fade_in`：淡入时长（秒），0 = 不淡入
/// - `fade_out`：淡出时长（秒），0 = 不淡出
/// - `fade_out_start`：淡出起始时间（秒，相对源时间轴）
/// - `curve`：曲线 tri / qsin / exp / log / par / qua / cbr / squ
class AudioFadeStepEditor extends ParamsStepEditor {
  const AudioFadeStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<AudioFadeStepEditor> createState() => _AudioFadeStepEditorState();
}

class _AudioFadeStepEditorState extends State<AudioFadeStepEditor> with StepEditorState<AudioFadeStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {
      'fade_in': 2.0,
      'fade_out': 2.0,
      'fade_out_start': 0.0,
      'curve': 'tri',
    });
  }

  @override
  Widget build(BuildContext context) {
    final fadeIn = (p['fade_in'] as num?)?.toDouble() ?? 2.0;
    final fadeOut = (p['fade_out'] as num?)?.toDouble() ?? 2.0;
    final outStart = (p['fade_out_start'] as num?)?.toDouble() ?? 0.0;

    return StepEditorScaffold(
      title: zh ? '音频淡入淡出' : 'Audio Fade',
      scrollable: true,
      infoText: zh
          ? '淡入从 0 秒开始；淡出起始时间设为 0 时按源时长自动推算。\n时长填 0 表示该方向不做淡变。'
          : 'Fade-in starts at 0s; fade-out start 0 means auto from duration.\nA duration of 0 disables that direction.',
      children: [
        LabeledSlider(
          text: '${zh ? "淡入时长" : "Fade in"}: ${fadeIn.toStringAsFixed(1)}s',
          value: fadeIn.clamp(0.0, 60.0), min: 0.0, max: 60.0, divisions: 120,
          sliderLabel: '${fadeIn.toStringAsFixed(1)}s',
          onChanged: (v) => update('fade_in', v),
        ),
        LabeledSlider(
          text: '${zh ? "淡出时长" : "Fade out"}: ${fadeOut.toStringAsFixed(1)}s',
          value: fadeOut.clamp(0.0, 60.0), min: 0.0, max: 60.0, divisions: 120,
          sliderLabel: '${fadeOut.toStringAsFixed(1)}s',
          onChanged: (v) => update('fade_out', v),
        ),
        if (fadeOut > 0) ...[
          const SizedBox(height: 8),
          TextFormField(
            key: const ValueKey('af_out_start'),
            initialValue: outStart.toStringAsFixed(1),
            decoration: editorDenseField(
              zh ? '淡出起始时间 (秒)' : 'Fade-out start (s)',
              hint: zh ? '留空或 0 表示由后端自动推算' : '0 = auto',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) { final d = double.tryParse(v); if (d != null) update('fade_out_start', d); },
          ),
        ],
        const SizedBox(height: 8),
        EditorDropdown(
          label: zh ? '曲线' : 'Curve',
          value: p['curve'] as String? ?? 'tri',
          items: [
            ('tri', zh ? '线性' : 'Linear (tri)'),
            ('qsin', zh ? '正弦' : 'Sine (qsin)'),
            ('exp', zh ? '指数' : 'Exponential (exp)'),
            ('log', zh ? '对数' : 'Logarithmic (log)'),
            ('par', zh ? '抛物线' : 'Parabola (par)'),
            ('qua', zh ? '二次' : 'Quadratic (qua)'),
            ('cbr', zh ? '三次' : 'Cubic (cbr)'),
            ('squ', zh ? '平方根' : 'Square root (squ)'),
          ],
          onChanged: (v) => update('curve', v),
        ),
      ],
    );
  }
}
