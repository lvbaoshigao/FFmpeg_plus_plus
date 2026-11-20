import 'package:flutter/material.dart';

import 'editor_kit.dart';
import 'media_step_editor_controls.dart';

/// Adjusts the low, middle, and high audio frequency bands.
class AudioEqualizerStepEditor extends ParamsStepEditor {
  const AudioEqualizerStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<AudioEqualizerStepEditor> createState() =>
      _AudioEqualizerStepEditorState();
}

class _AudioEqualizerStepEditorState extends State<AudioEqualizerStepEditor>
    with StepEditorState<AudioEqualizerStepEditor> {
  static const _defaults = {'bass_db': 0.0, 'mid_db': 0.0, 'treble_db': 0.0};

  @override
  void initState() {
    super.initState();
    _prepareParams();
  }

  @override
  void didUpdateWidget(covariant AudioEqualizerStepEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.params, widget.params)) {
      _prepareParams();
    }
  }

  void _prepareParams() {
    initDefaults(_defaults);
    for (final key in _defaults.keys) {
      p[key] = editorNumberInRange(p[key], fallback: 0, min: -12, max: 12);
    }
  }

  void _reset() {
    setState(() => p.addAll(_defaults));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => StepEditorScaffold(
    key: ObjectKey(p),
    title: zh ? '音频均衡器' : 'Audio equalizer',
    description: zh
        ? '正值增强该频段，负值衰减；0 dB 保持原声。'
        : 'Positive values boost a band; negative values reduce it. At 0 dB, it stays unchanged.',
    scrollable: true,
    infoText: zh
        ? '每个频段可调 −12 到 +12 dB。增强过多可能导致失真，可在后续节点降低整体音量。'
        : 'Each band ranges from −12 to +12 dB. Strong boosts may distort; reduce the overall volume if needed.',
    children: [
      for (final (key, label, frequency) in [
        ('bass_db', zh ? '低频' : 'Bass', '100 Hz'),
        ('mid_db', zh ? '中频' : 'Mid', '1 kHz'),
        ('treble_db', zh ? '高频' : 'Treble', '8 kHz'),
      ]) ...[
        LabeledSlider(
          key: ValueKey('equalizer_$key'),
          adaptive: true,
          text:
              '$label ($frequency): ${(p[key] as num) > 0 ? "+" : ""}${(p[key] as num).toStringAsFixed(1)} dB',
          value: (p[key] as num).toDouble(),
          min: -12,
          max: 12,
          divisions: 48,
          sliderLabel: '${(p[key] as num).toStringAsFixed(1)} dB',
          onChanged: (value) =>
              update(key, double.parse(value.toStringAsFixed(1))),
        ),
        const SizedBox(height: 16),
      ],
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const ValueKey('equalizer_reset'),
          onPressed: _reset,
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.restart_alt_rounded, size: 20),
          label: Text(zh ? '重置为原声' : 'Reset all bands'),
        ),
      ),
    ],
  );
}
