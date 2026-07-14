import 'package:flutter/material.dart';

class ImageRotateStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ImageRotateStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ImageRotateStepEditor> createState() => _ImageRotateStepEditorState();
}

class _ImageRotateStepEditorState extends State<ImageRotateStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('rotate_mode', () => 'preset');
    p.putIfAbsent('angle', () => 90.0);
    p.putIfAbsent('random_min', () => 0.0);
    p.putIfAbsent('random_max', () => 360.0);
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mode = p['rotate_mode'] as String? ?? 'preset';
    final angle = (p['angle'] as num?)?.toDouble() ?? 90.0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '图片旋转' : 'Image Rotate',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: mode,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: zh ? '旋转模式' : 'Rotate Mode', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: [
            DropdownMenuItem(value: 'preset', child: Text(zh ? '预设角度' : 'Preset', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'custom', child: Text(zh ? '自定义角度' : 'Custom', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'random', child: Text(zh ? '随机角度' : 'Random', style: TextStyle(fontSize: 13, color: cs.onSurface))),
          ],
          onChanged: (v) { if (v != null) _update('rotate_mode', v); },
        ),
        const SizedBox(height: 16),

        if (mode == 'preset') ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final deg in [90.0, 180.0, 270.0])
              ChoiceChip(
                label: Text('${deg.toInt()}°'),
                selected: angle == deg,
                onSelected: (_) => _update('angle', deg),
              ),
          ]),
        ] else if (mode == 'custom') ...[
          Row(children: [
            Text('${zh ? "角度" : "Angle"}: ${angle.toStringAsFixed(1)}°',
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: angle.clamp(0.0, 360.0), min: 0, max: 360, divisions: 720,
              label: '${angle.toStringAsFixed(1)}°',
              onChanged: (v) => _update('angle', v),
            )),
          ]),
        ] else ...[
          Row(children: [
            Expanded(child: TextFormField(
              initialValue: '${(p['random_min'] as num?)?.toDouble() ?? 0.0}',
              decoration: InputDecoration(
                labelText: zh ? '最小角度' : 'Min Angle', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) { final d = double.tryParse(v); if (d != null) _update('random_min', d); },
            )),
            const SizedBox(width: 8),
            Expanded(child: TextFormField(
              initialValue: '${(p['random_max'] as num?)?.toDouble() ?? 360.0}',
              decoration: InputDecoration(
                labelText: zh ? '最大角度' : 'Max Angle', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) { final d = double.tryParse(v); if (d != null) _update('random_max', d); },
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
              zh ? '90°/180°/270° 使用 transpose 滤镜（无损）。\n任意角度使用 rotate 滤镜。'
                 : '90°/180°/270° use transpose filter (lossless).\nArbitrary angles use rotate filter.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
