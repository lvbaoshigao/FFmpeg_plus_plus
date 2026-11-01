import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// 首尾静音裁剪节点编辑器（FFmpeg silenceremove）。
class AudioSilenceTrimStepEditor extends ParamsStepEditor {
  const AudioSilenceTrimStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<AudioSilenceTrimStepEditor> createState() =>
      _AudioSilenceTrimStepEditorState();
}

class _AudioSilenceTrimStepEditorState extends State<AudioSilenceTrimStepEditor>
    with StepEditorState<AudioSilenceTrimStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'mode': 'both', 'threshold_db': -40.0, 'min_duration': 0.1});
  }

  @override
  Widget build(BuildContext context) {
    final zh = this.zh;
    final cs = Theme.of(context).colorScheme;
    final mode = p['mode'] as String? ?? 'both';
    final threshold = (p['threshold_db'] as num?)?.toDouble() ?? -40.0;
    final minDur = (p['min_duration'] as num?)?.toDouble() ?? 0.1;

    return StepEditorScaffold(
      title: zh ? '静音裁剪' : 'Silence Trim',
      infoText: zh
          ? '删除开头/结尾的静音段（silenceremove），适合录音、播客、配音素材。\n'
              '只处理首尾，不会删除中间的停顿。'
          : 'Removes leading/trailing silence (silenceremove). Middle pauses are kept.',
      children: [
        EditorDropdown(
          label: zh ? '裁剪方式' : 'Trim Mode',
          value: ['both', 'leading', 'trailing'].contains(mode) ? mode : 'both',
          items: [
            ('both', zh ? '首尾都裁' : 'Both ends'),
            ('leading', zh ? '只裁开头' : 'Leading only'),
            ('trailing', zh ? '只裁结尾' : 'Trailing only'),
          ],
          onChanged: (v) => update('mode', v),
        ),
        const SizedBox(height: 8),
        LabeledSlider(
          text: '${zh ? "静音阈值" : "Threshold"}: ${threshold.toStringAsFixed(0)} dB',
          value: threshold.clamp(-60.0, -20.0),
          min: -60,
          max: -20,
          divisions: 40,
          onChanged: (v) => update('threshold_db', double.parse(v.toStringAsFixed(0))),
        ),
        _hint(cs, zh
            ? '低于此音量视为静音；-40 ~ -35dB 通常合适'
            : 'Below this level counts as silence; -40 to -35 dB is typical'),
        LabeledSlider(
          text: '${zh ? "最短静音时长" : "Min Silence"}: ${minDur.toStringAsFixed(2)} s',
          value: minDur.clamp(0.0, 5.0),
          min: 0,
          max: 5,
          divisions: 100,
          onChanged: (v) => update('min_duration', double.parse(v.toStringAsFixed(2))),
        ),
        _hint(cs, zh
            ? '超过该时长的静音才会被裁掉，避免误删自然停顿'
            : 'Only silences longer than this are removed'),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              update('mode', 'both');
              update('threshold_db', -40.0);
              update('min_duration', 0.1);
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
