import 'package:flutter/material.dart';

class AudioVolumeStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;
  const AudioVolumeStepEditor({super.key, required this.params, required this.onChanged, this.isZh = true});
  @override
  State<AudioVolumeStepEditor> createState() => _AudioVolumeStepEditorState();
}

class _AudioVolumeStepEditorState extends State<AudioVolumeStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('volume_db', () => 0.0);
  }

  void _update(String key, dynamic value) { setState(() => p[key] = value); widget.onChanged(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final db = (p['volume_db'] as num?)?.toDouble() ?? 0.0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '调整音量' : 'Audio Volume', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),
        Row(children: [
          Text(zh ? '音量: ${db >= 0 ? "+$db" : "$db"} dB' : 'Volume: ${db >= 0 ? "+$db" : "$db"} dB',
              style: TextStyle(fontSize: 12, color: cs.onSurface)),
          const Spacer(),
          TextButton(onPressed: () => _update('volume_db', 0.0),
              child: Text(zh ? '重置' : 'Reset', style: const TextStyle(fontSize: 11))),
        ]),
        Row(children: [
          Expanded(child: Slider(
            value: db.clamp(-30.0, 30.0),
            min: -30.0, max: 30.0, divisions: 120,
            label: '${db.toStringAsFixed(1)} dB',
            onChanged: (v) => _update('volume_db', double.parse(v.toStringAsFixed(1))),
          )),
        ]),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('-30 dB', style: TextStyle(fontSize: 10, color: cs.outline)),
          Text('0 dB', style: TextStyle(fontSize: 10, color: cs.outline)),
          Text('+30 dB', style: TextStyle(fontSize: 10, color: cs.outline)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final preset in [-10.0, -5.0, -3.0, 0.0, 3.0, 5.0, 10.0])
            ChoiceChip(
              label: Text('${preset >= 0 ? "+" : ""}${preset.toInt()} dB', style: const TextStyle(fontSize: 11)),
              selected: (db - preset).abs() < 0.05,
              onSelected: (_) => _update('volume_db', preset),
              visualDensity: VisualDensity.compact,
            ),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: cs.surfaceContainerHighest.withAlpha(60), borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14, color: cs.outline),
            const SizedBox(width: 8),
            Expanded(child: Text(
              zh ? '正值增大音量，负值减小音量。\n超过 0 dB 可能导致削波失真。'
                 : 'Positive values boost, negative values reduce.\nValues above 0 dB may cause clipping.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
