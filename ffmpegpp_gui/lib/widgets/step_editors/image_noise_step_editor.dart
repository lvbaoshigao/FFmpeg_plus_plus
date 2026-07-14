import 'package:flutter/material.dart';

class ImageNoiseStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ImageNoiseStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ImageNoiseStepEditor> createState() => _ImageNoiseStepEditorState();
}

class _ImageNoiseStepEditorState extends State<ImageNoiseStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('noise_mode', () => 'value');
    p.putIfAbsent('noise_strength', () => 10);
    p.putIfAbsent('noise_type', () => 'u');
    p.putIfAbsent('random_min', () => 5);
    p.putIfAbsent('random_max', () => 50);
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mode = p['noise_mode'] as String? ?? 'value';
    final strength = (p['noise_strength'] as num?)?.toInt() ?? 10;
    final noiseType = p['noise_type'] as String? ?? 'u';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '添加噪点' : 'Add Noise',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: noiseType,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: zh ? '噪点类型' : 'Noise Type', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: [
            DropdownMenuItem(value: 'u', child: Text(zh ? '均匀分布 (Uniform)' : 'Uniform', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 't', child: Text(zh ? '时间变化 (Temporal)' : 'Temporal', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'p', child: Text(zh ? '图案噪点 (Pattern)' : 'Pattern', style: TextStyle(fontSize: 13, color: cs.onSurface))),
          ],
          onChanged: (v) { if (v != null) _update('noise_type', v); },
        ),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: mode,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: zh ? '强度模式' : 'Strength Mode', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: [
            DropdownMenuItem(value: 'value', child: Text(zh ? '固定强度' : 'Fixed', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'random', child: Text(zh ? '随机强度' : 'Random', style: TextStyle(fontSize: 13, color: cs.onSurface))),
          ],
          onChanged: (v) { if (v != null) _update('noise_mode', v); },
        ),
        const SizedBox(height: 16),

        if (mode == 'value') ...[
          Row(children: [
            Text('${zh ? "强度" : "Strength"}: $strength',
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: strength.toDouble().clamp(0, 100), min: 0, max: 100, divisions: 100,
              label: '$strength',
              onChanged: (v) => _update('noise_strength', v.round()),
            )),
          ]),
        ] else ...[
          Row(children: [
            Expanded(child: TextFormField(
              initialValue: '${(p['random_min'] as num?)?.toInt() ?? 5}',
              decoration: InputDecoration(
                labelText: zh ? '最小强度' : 'Min Strength', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) { final d = int.tryParse(v); if (d != null) _update('random_min', d); },
            )),
            const SizedBox(width: 8),
            Expanded(child: TextFormField(
              initialValue: '${(p['random_max'] as num?)?.toInt() ?? 50}',
              decoration: InputDecoration(
                labelText: zh ? '最大强度' : 'Max Strength', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) { final d = int.tryParse(v); if (d != null) _update('random_max', d); },
            )),
          ]),
        ],

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withAlpha(60),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14, color: cs.outline),
            const SizedBox(width: 8),
            Expanded(child: Text(
              zh ? 'alls=强度：所有通道的噪点强度（0-100）\nallf=类型：u=均匀分布，t=时间变化，p=图案'
                 : 'alls=strength: noise intensity on all channels (0-100)\nallf=type: u=uniform, t=temporal, p=pattern',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
