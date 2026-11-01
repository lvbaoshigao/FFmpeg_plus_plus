import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// 音频降噪节点编辑器（FFmpeg afftdn）。
class AudioDenoiseStepEditor extends ParamsStepEditor {
  const AudioDenoiseStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<AudioDenoiseStepEditor> createState() => _AudioDenoiseStepEditorState();
}

class _AudioDenoiseStepEditorState extends State<AudioDenoiseStepEditor>
    with StepEditorState<AudioDenoiseStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'noise_reduction': 12.0, 'noise_floor': -30.0});
  }

  @override
  Widget build(BuildContext context) {
    final zh = this.zh;
    final cs = Theme.of(context).colorScheme;
    final nr = (p['noise_reduction'] as num?)?.toDouble() ?? 12.0;
    final nf = (p['noise_floor'] as num?)?.toDouble() ?? -30.0;

    return StepEditorScaffold(
      title: zh ? '音频降噪' : 'Audio Denoise',
      infoText: zh
          ? '基于 FFT 的频域降噪（afftdn），适合电流声、风扇声等稳定底噪。\n'
              '降噪量越大越干净，但过大（>25dB）会产生"水声"失真。'
          : 'FFT-based noise reduction (afftdn) for steady noise such as hum or fans.\n'
              'Higher reduction is cleaner, but above ~25 dB it can sound watery.',
      children: [
        LabeledSlider(
          text: '${zh ? "降噪量" : "Reduction"}: ${nr.toStringAsFixed(0)} dB',
          value: nr.clamp(0.01, 40.0),
          min: 0.01,
          max: 40,
          divisions: 400,
          onChanged: (v) => update('noise_reduction', double.parse(v.toStringAsFixed(2))),
        ),
        _hint(cs, zh ? '推荐 6~15dB；超过 25dB 容易伤到人声细节' : '6–15 dB recommended; >25 dB hurts voices'),
        LabeledSlider(
          text: '${zh ? "噪声底" : "Noise Floor"}: ${nf.toStringAsFixed(0)} dB',
          value: nf.clamp(-80.0, -20.0),
          min: -80,
          max: -20,
          divisions: 60,
          onChanged: (v) => update('noise_floor', double.parse(v.toStringAsFixed(0))),
        ),
        _hint(cs, zh
            ? '估计的底噪水平；不知道时保持 -30dB 即可'
            : 'Estimated noise level; keep -30 dB if unsure'),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              update('noise_reduction', 12.0);
              update('noise_floor', -30.0);
            },
            child: Text(zh ? '恢复默认' : 'Reset Defaults',
                style: const TextStyle(fontSize: 11)),
          ),
        ),
      ],
    );
  }

  Widget _hint(ColorScheme cs, String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: Text(text, style: TextStyle(fontSize: 10, color: cs.outline)),
      );
}
