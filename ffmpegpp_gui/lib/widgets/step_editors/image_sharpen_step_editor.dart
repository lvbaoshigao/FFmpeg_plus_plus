import 'package:flutter/material.dart';

class ImageSharpenStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ImageSharpenStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ImageSharpenStepEditor> createState() => _ImageSharpenStepEditorState();
}

class _ImageSharpenStepEditorState extends State<ImageSharpenStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('sharpen_mode', () => 'value');
    p.putIfAbsent('sharpen_strength', () => 1.0);
    p.putIfAbsent('random_min', () => 0.5);
    p.putIfAbsent('random_max', () => 3.0);
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mode = p['sharpen_mode'] as String? ?? 'value';
    final strength = (p['sharpen_strength'] as num?)?.toDouble() ?? 1.0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '图片锐化' : 'Image Sharpen',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          value: mode,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: zh ? '锐化模式' : 'Mode', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: [
            DropdownMenuItem(value: 'value', child: Text(zh ? '固定强度' : 'Fixed', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'random', child: Text(zh ? '随机强度' : 'Random', style: TextStyle(fontSize: 13, color: cs.onSurface))),
          ],
          onChanged: (v) { if (v != null) _update('sharpen_mode', v); },
        ),
        const SizedBox(height: 16),

        if (mode == 'value') ...[
          Row(children: [
            Text('${zh ? "强度" : "Strength"}: ${strength.toStringAsFixed(1)}',
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: strength.clamp(0.0, 5.0), min: 0.0, max: 5.0, divisions: 50,
              label: strength.toStringAsFixed(1),
              onChanged: (v) => _update('sharpen_strength', v),
            )),
          ]),
        ] else ...[
          Row(children: [
            Expanded(child: TextFormField(
              initialValue: '${(p['random_min'] as num?)?.toDouble() ?? 0.5}',
              decoration: InputDecoration(
                labelText: zh ? '最小强度' : 'Min', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) { final d = double.tryParse(v); if (d != null) _update('random_min', d); },
            )),
            const SizedBox(width: 8),
            Expanded(child: TextFormField(
              initialValue: '${(p['random_max'] as num?)?.toDouble() ?? 3.0}',
              decoration: InputDecoration(
                labelText: zh ? '最大强度' : 'Max', isDense: true,
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
              zh ? '使用 unsharp 滤镜进行锐化。\n5x5 卷积核，强度越大锐化效果越明显。'
                 : 'Uses unsharp filter for sharpening.\n5x5 kernel, higher strength = more sharpening.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
