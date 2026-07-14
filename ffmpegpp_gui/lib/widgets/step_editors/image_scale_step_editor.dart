import 'package:flutter/material.dart';

class ImageScaleStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ImageScaleStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ImageScaleStepEditor> createState() => _ImageScaleStepEditorState();
}

class _ImageScaleStepEditorState extends State<ImageScaleStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('scale_mode', () => 'factor');
    p.putIfAbsent('scale_factor', () => 1.0);
    p.putIfAbsent('random_min', () => 0.5);
    p.putIfAbsent('random_max', () => 2.0);
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mode = p['scale_mode'] as String? ?? 'factor';
    final factor = (p['scale_factor'] as num?)?.toDouble() ?? 1.0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '图片缩放' : 'Image Scale',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: mode,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: zh ? '缩放模式' : 'Scale Mode', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: [
            DropdownMenuItem(value: 'factor', child: Text(zh ? '指定倍数' : 'Factor', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'random', child: Text(zh ? '随机倍数' : 'Random', style: TextStyle(fontSize: 13, color: cs.onSurface))),
          ],
          onChanged: (v) { if (v != null) _update('scale_mode', v); },
        ),
        const SizedBox(height: 16),

        if (mode == 'factor') ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final f in [0.25, 0.5, 1.0, 2.0, 4.0])
              ChoiceChip(
                label: Text('${f}x'),
                selected: (factor - f).abs() < 0.01,
                onSelected: (_) => _update('scale_factor', f),
              ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Text('${zh ? "倍数" : "Factor"}: ${factor.toStringAsFixed(2)}x',
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: factor.clamp(0.1, 10.0), min: 0.1, max: 10.0, divisions: 99,
              label: '${factor.toStringAsFixed(2)}x',
              onChanged: (v) => _update('scale_factor', v),
            )),
          ]),
        ] else ...[
          Row(children: [
            Expanded(child: TextFormField(
              initialValue: '${(p['random_min'] as num?)?.toDouble() ?? 0.5}',
              decoration: InputDecoration(
                labelText: zh ? '最小倍数' : 'Min Factor', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) { final d = double.tryParse(v); if (d != null) _update('random_min', d); },
            )),
            const SizedBox(width: 8),
            Expanded(child: TextFormField(
              initialValue: '${(p['random_max'] as num?)?.toDouble() ?? 2.0}',
              decoration: InputDecoration(
                labelText: zh ? '最大倍数' : 'Max Factor', isDense: true,
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
              zh ? '按倍数缩放图片尺寸。\n输出尺寸自动对齐为偶数像素。'
                 : 'Scale image dimensions by factor.\nOutput dimensions are automatically aligned to even pixels.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
