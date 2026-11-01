import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// 响度标准化节点编辑器（EBU R128 / FFmpeg loudnorm）。
class AudioNormalizeStepEditor extends ParamsStepEditor {
  const AudioNormalizeStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<AudioNormalizeStepEditor> createState() => _AudioNormalizeStepEditorState();
}

class _AudioNormalizeStepEditorState extends State<AudioNormalizeStepEditor>
    with StepEditorState<AudioNormalizeStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'target_i': -16.0, 'target_tp': -1.5, 'target_lra': 11.0});
  }

  @override
  Widget build(BuildContext context) {
    final zh = this.zh;
    final cs = Theme.of(context).colorScheme;
    final targetI = (p['target_i'] as num?)?.toDouble() ?? -16.0;
    final targetTp = (p['target_tp'] as num?)?.toDouble() ?? -1.5;
    final targetLra = (p['target_lra'] as num?)?.toDouble() ?? 11.0;

    return StepEditorScaffold(
      title: zh ? '响度标准化' : 'Loudness Normalization',
      infoText: zh
          ? '使用 EBU R128 把整体响度拉到目标值，适合各平台音量不一的素材。\n'
              '单遍处理，不需要提前测量；输出格式沿用输入文件。'
          : 'Normalizes overall loudness to the EBU R128 target.\n'
              'Single-pass processing; output keeps the input format.',
      children: [
        LabeledSlider(
          text: '${zh ? "目标响度 I" : "Integrated"}: ${targetI.toStringAsFixed(1)} LUFS',
          value: targetI.clamp(-70.0, -5.0),
          min: -70,
          max: -5,
          divisions: 130,
          onChanged: (v) => update('target_i', double.parse(v.toStringAsFixed(1))),
        ),
        _hint(cs, zh
            ? '平台常用 -16（播客/移动端）或 -14（流媒体）；数值越大越响'
            : '-16 for podcasts/mobile, -14 for streaming; higher = louder'),
        LabeledSlider(
          text: '${zh ? "真峰值上限 TP" : "True Peak"}: ${targetTp.toStringAsFixed(1)} dBTP',
          value: targetTp.clamp(-9.0, 0.0),
          min: -9,
          max: 0,
          divisions: 36,
          onChanged: (v) => update('target_tp', double.parse(v.toStringAsFixed(1))),
        ),
        _hint(cs, zh
            ? '防止削波，通常 -1.5 ~ -1.0 dBTP'
            : 'Prevents clipping; typically -1.5 to -1.0 dBTP'),
        LabeledSlider(
          text: '${zh ? "响度范围 LRA" : "Loudness Range"}: ${targetLra.toStringAsFixed(1)} LU',
          value: targetLra.clamp(1.0, 50.0),
          min: 1,
          max: 50,
          divisions: 98,
          onChanged: (v) => update('target_lra', double.parse(v.toStringAsFixed(1))),
        ),
        _hint(cs, zh
            ? '动态范围上限，默认 11；越大保留越多动态'
            : 'Max dynamic range, default 11; higher keeps more dynamics'),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              update('target_i', -16.0);
              update('target_tp', -1.5);
              update('target_lra', 11.0);
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
