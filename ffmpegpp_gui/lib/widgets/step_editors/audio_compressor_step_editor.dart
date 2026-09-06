import 'package:flutter/material.dart';
import 'editor_kit.dart';

class AudioCompressorStepEditor extends ParamsStepEditor {
  const AudioCompressorStepEditor({super.key, required super.params, required super.onChanged, super.isZh = true});
  @override
  State<AudioCompressorStepEditor> createState() => _AudioCompressorStepEditorState();
}

class _AudioCompressorStepEditorState extends State<AudioCompressorStepEditor> with StepEditorState<AudioCompressorStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'threshold': -20.0, 'ratio': 3.0, 'attack': 10.0, 'release': 100.0, 'makeup': 4.0, 'knee': 2.8});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final threshold = (p['threshold'] as num?)?.toDouble() ?? -20.0;
    final ratio = (p['ratio'] as num?)?.toDouble() ?? 3.0;
    final attack = (p['attack'] as num?)?.toDouble() ?? 10.0;
    final release = (p['release'] as num?)?.toDouble() ?? 100.0;
    final makeup = (p['makeup'] as num?)?.toDouble() ?? 4.0;
    final knee = (p['knee'] as num?)?.toDouble() ?? 2.8;

    return StepEditorScaffold(
      title: zh ? '压缩动态范围' : 'Dynamic Range Compressor',
      children: [
        _paramSlider(cs, zh ? '阈值 (threshold)' : 'Threshold', '$threshold dB',
            threshold, -60.0, 0.0, 120, (v) => update('threshold', double.parse(v.toStringAsFixed(1)))),
        _hint(cs, zh ? '超过此值才开始压缩。越小越容易触发' : 'Compression starts above this level'),

        _paramSlider(cs, zh ? '压缩比 (ratio)' : 'Ratio', '${ratio.toStringAsFixed(1)}:1',
            ratio, 1.0, 20.0, 38, (v) => update('ratio', double.parse(v.toStringAsFixed(1)))),
        _hint(cs, zh ? '超出阈值部分按此比例压缩。越大越平' : 'Compression ratio for signal above threshold'),

        _paramSlider(cs, zh ? '启动 (attack)' : 'Attack', '${attack.toStringAsFixed(0)} ms',
            attack, 0.1, 200.0, 200, (v) => update('attack', double.parse(v.toStringAsFixed(1)))),
        _hint(cs, zh ? '压缩器启动速度。小值反应快，大值保留爆发力' : 'How fast compression engages'),

        _paramSlider(cs, zh ? '释放 (release)' : 'Release', '${release.toStringAsFixed(0)} ms',
            release, 10.0, 1000.0, 99, (v) => update('release', double.parse(v.toStringAsFixed(0)))),
        _hint(cs, zh ? '低于阈值后停止压缩的速度' : 'How fast compression releases'),

        _paramSlider(cs, zh ? '补偿增益 (makeup)' : 'Makeup Gain', '${makeup.toStringAsFixed(1)}x',
            makeup, 1.0, 16.0, 30, (v) => update('makeup', double.parse(v.toStringAsFixed(1)))),
        _hint(cs, zh ? '压缩后提升整体音量。通常 2~8' : 'Boosts overall level after compression'),

        _paramSlider(cs, zh ? '拐点 (knee)' : 'Knee', knee.toStringAsFixed(1),
            knee, 1.0, 10.0, 18, (v) => update('knee', double.parse(v.toStringAsFixed(1)))),
        _hint(cs, zh ? '阈值附近的过渡柔化程度。越大越自然' : 'Smoothness of transition around threshold'),

        const SizedBox(height: 8),
        Align(alignment: Alignment.centerRight, child: TextButton(
          onPressed: () {
            update('threshold', -20.0); update('ratio', 3.0);
            update('attack', 10.0); update('release', 100.0);
            update('makeup', 4.0); update('knee', 2.8);
          },
          child: Text(zh ? '恢复默认' : 'Reset Defaults', style: const TextStyle(fontSize: 11)),
        )),
      ],
    );
  }

  Widget _paramSlider(ColorScheme cs, String label, String valueStr, double value, double min, double max, int divisions, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(label, style: TextStyle(fontSize: 12, color: cs.onSurface)),
          const Spacer(),
          Text(valueStr, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.primary)),
        ]),
        Row(children: [
          Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged)),
        ]),
      ]),
    );
  }

  Widget _hint(ColorScheme cs, String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 4),
    child: Text(text, style: TextStyle(fontSize: 10, color: cs.outline)),
  );
}
