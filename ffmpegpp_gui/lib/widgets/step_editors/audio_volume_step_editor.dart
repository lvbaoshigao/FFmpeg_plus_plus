import 'package:flutter/material.dart';
import 'editor_kit.dart';

class AudioVolumeStepEditor extends ParamsStepEditor {
  const AudioVolumeStepEditor({super.key, required super.params, required super.onChanged, super.isZh = true});
  @override
  State<AudioVolumeStepEditor> createState() => _AudioVolumeStepEditorState();
}

class _AudioVolumeStepEditorState extends State<AudioVolumeStepEditor> with StepEditorState<AudioVolumeStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'volume_db': 0.0});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final db = (p['volume_db'] as num?)?.toDouble() ?? 0.0;

    return StepEditorScaffold(
      title: zh ? '调整音量' : 'Audio Volume',
      infoText: zh ? '正值增大音量，负值减小音量。\n超过 0 dB 可能导致削波失真。'
                   : 'Positive values boost, negative values reduce.\nValues above 0 dB may cause clipping.',
      children: [
        Row(children: [
          Text(zh ? '音量: ${db >= 0 ? "+$db" : "$db"} dB' : 'Volume: ${db >= 0 ? "+$db" : "$db"} dB',
              style: TextStyle(fontSize: 12, color: cs.onSurface)),
          const Spacer(),
          TextButton(onPressed: () => update('volume_db', 0.0),
              child: Text(zh ? '重置' : 'Reset', style: const TextStyle(fontSize: 11))),
        ]),
        Row(children: [
          Expanded(child: Slider(
            value: db.clamp(-30.0, 30.0),
            min: -30.0, max: 30.0, divisions: 120,
            label: '${db.toStringAsFixed(1)} dB',
            onChanged: (v) => update('volume_db', double.parse(v.toStringAsFixed(1))),
          )),
        ]),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('-30 dB', style: TextStyle(fontSize: 10, color: cs.outline)),
          Text('0 dB', style: TextStyle(fontSize: 10, color: cs.outline)),
          Text('+30 dB', style: TextStyle(fontSize: 10, color: cs.outline)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final preset in [-10.0, -5.0, -3.0, 0.0, 3.0, 5.0, 10.0])
            ChoiceChip(
              label: Text('${preset >= 0 ? "+" : ""}${preset.toInt()} dB', style: const TextStyle(fontSize: 11)),
              selected: (db - preset).abs() < 0.05,
              onSelected: (_) => update('volume_db', preset),
              visualDensity: VisualDensity.compact,
            ),
        ]),
      ],
    );
  }
}
