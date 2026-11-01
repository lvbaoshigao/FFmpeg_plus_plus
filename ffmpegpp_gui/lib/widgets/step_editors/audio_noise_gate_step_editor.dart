import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// 音频噪声门节点编辑器（FFmpeg agate）。
///
/// 只让超过阈值的信号通过，用来压掉底噪、呼吸声、房间回声。
class AudioNoiseGateStepEditor extends ParamsStepEditor {
  const AudioNoiseGateStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<AudioNoiseGateStepEditor> createState() => _AudioNoiseGateStepEditorState();
}

class _AudioNoiseGateStepEditorState extends State<AudioNoiseGateStepEditor>
    with StepEditorState<AudioNoiseGateStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {
      'threshold_db': -30.0,
      'ratio': 2.0,
      'attack': 20.0,
      'release': 250.0,
    });
  }

  @override
  Widget build(BuildContext context) {
    final zh = this.zh;
    final cs = Theme.of(context).colorScheme;
    final threshold = (p['threshold_db'] as num?)?.toDouble() ?? -30.0;
    final ratio = (p['ratio'] as num?)?.toDouble() ?? 2.0;
    final attack = (p['attack'] as num?)?.toDouble() ?? 20.0;
    final release = (p['release'] as num?)?.toDouble() ?? 250.0;

    return StepEditorScaffold(
      title: zh ? '音频噪声门' : 'Audio Noise Gate',
      infoText: zh
          ? '低于阈值的信号被衰减，用来去掉持续底噪。\n'
              '阈值不要设太高，否则人声的气口/尾音会被一起吃掉。'
          : 'Attenuates signal below the threshold to remove steady noise.\n'
              'Avoid a very high threshold or quiet speech tails get cut.',
      children: [
        LabeledSlider(
          text: '${zh ? "阈值" : "Threshold"}: ${threshold.toStringAsFixed(0)} dB',
          value: threshold.clamp(-80.0, 0.0),
          min: -80,
          max: 0,
          divisions: 80,
          onChanged: (v) => update('threshold_db', double.parse(v.toStringAsFixed(0))),
        ),
        _hint(cs, zh
            ? '底噪通常在 -50 ~ -35dB，人声在 -25dB 以上'
            : 'Room noise is around -50 to -35 dB; speech sits above -25 dB'),
        LabeledSlider(
          text: '${zh ? "压缩比" : "Ratio"}: ${ratio.toStringAsFixed(1)}:1',
          value: ratio.clamp(1.0, 20.0),
          min: 1,
          max: 20,
          divisions: 38,
          onChanged: (v) => update('ratio', double.parse(v.toStringAsFixed(1))),
        ),
        _hint(cs, zh
            ? '低于阈值的部分被压低多少倍，越大越干净'
            : 'How hard sub-threshold audio is reduced; higher = cleaner'),
        LabeledSlider(
          text: '${zh ? "启动" : "Attack"}: ${attack.toStringAsFixed(0)} ms',
          value: attack.clamp(0.01, 500.0),
          min: 0.01,
          max: 500,
          divisions: 500,
          onChanged: (v) => update('attack', double.parse(v.toStringAsFixed(0))),
        ),
        _hint(cs, zh ? '开门速度，越小越灵敏' : 'How fast the gate opens'),
        LabeledSlider(
          text: '${zh ? "释放" : "Release"}: ${release.toStringAsFixed(0)} ms',
          value: release.clamp(10.0, 2000.0),
          min: 10,
          max: 2000,
          divisions: 199,
          onChanged: (v) => update('release', double.parse(v.toStringAsFixed(0))),
        ),
        _hint(cs, zh ? '关门速度，太小会听出"抽气"感' : 'How fast the gate closes; too low sounds choppy'),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              update('threshold_db', -30.0);
              update('ratio', 2.0);
              update('attack', 20.0);
              update('release', 250.0);
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
