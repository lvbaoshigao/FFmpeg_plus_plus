import 'package:flutter/material.dart';

class AudioSpeedStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;
  const AudioSpeedStepEditor({super.key, required this.params, required this.onChanged, this.isZh = true});
  @override
  State<AudioSpeedStepEditor> createState() => _AudioSpeedStepEditorState();
}

class _AudioSpeedStepEditorState extends State<AudioSpeedStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('atempo', () => 1.0);
  }

  void _update(String key, dynamic value) { setState(() => p[key] = value); widget.onChanged(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final tempo = (p['atempo'] as num?)?.toDouble() ?? 1.0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '调整速度' : 'Audio Speed', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),
        Row(children: [
          Text(zh ? '速度: ${tempo.toStringAsFixed(2)}x' : 'Speed: ${tempo.toStringAsFixed(2)}x',
              style: TextStyle(fontSize: 12, color: cs.onSurface)),
          const Spacer(),
          TextButton(onPressed: () => _update('atempo', 1.0),
              child: Text(zh ? '重置' : 'Reset', style: const TextStyle(fontSize: 11))),
        ]),
        Row(children: [
          Expanded(child: Slider(
            value: tempo.clamp(0.5, 4.0),
            min: 0.5, max: 4.0, divisions: 70,
            label: '${tempo.toStringAsFixed(2)}x',
            onChanged: (v) => _update('atempo', double.parse(v.toStringAsFixed(2))),
          )),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final preset in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0])
            ChoiceChip(
              label: Text('${preset}x', style: const TextStyle(fontSize: 11)),
              selected: (tempo - preset).abs() < 0.01,
              onSelected: (_) => _update('atempo', preset),
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
              zh ? '使用 atempo 滤镜调整音频播放速度。\n范围: 0.5x (半速) ~ 4.0x (4倍速)\n不改变音高。'
                 : 'Uses atempo filter to adjust playback speed.\nRange: 0.5x (half) ~ 4.0x (quadruple)\nPitch is preserved.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
