import 'package:flutter/material.dart';

class ImageBrightnessStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ImageBrightnessStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ImageBrightnessStepEditor> createState() => _ImageBrightnessStepEditorState();
}

class _ImageBrightnessStepEditorState extends State<ImageBrightnessStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('brightness_mode', () => 'value');
    p.putIfAbsent('brightness', () => 0.0);
    p.putIfAbsent('range_min', () => -0.5);
    p.putIfAbsent('range_max', () => 0.5);
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mode = p['brightness_mode'] as String? ?? 'value';
    final brightness = (p['brightness'] as num?)?.toDouble() ?? 0.0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '亮度调节' : 'Brightness Adjustment',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          value: mode,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: zh ? '调节模式' : 'Mode', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: [
            DropdownMenuItem(value: 'value', child: Text(zh ? '固定值' : 'Fixed Value', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'range', child: Text(zh ? '指定范围' : 'Range', style: TextStyle(fontSize: 13, color: cs.onSurface))),
          ],
          onChanged: (v) { if (v != null) _update('brightness_mode', v); },
        ),
        const SizedBox(height: 16),

        if (mode == 'value') ...[
          Row(children: [
            Text('${zh ? "亮度" : "Brightness"}: ${brightness.toStringAsFixed(2)}',
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: brightness.clamp(-1.0, 1.0), min: -1.0, max: 1.0, divisions: 200,
              label: brightness.toStringAsFixed(2),
              onChanged: (v) => _update('brightness', v),
            )),
          ]),
          Text(zh ? '负值降低亮度，正值增加亮度' : 'Negative = darker, positive = brighter',
              style: TextStyle(fontSize: 11, color: cs.outline)),
        ] else ...[
          Row(children: [
            Expanded(child: TextFormField(
              initialValue: '${(p['range_min'] as num?)?.toDouble() ?? -0.5}',
              decoration: InputDecoration(
                labelText: zh ? '最小值' : 'Min', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) { final d = double.tryParse(v); if (d != null) _update('range_min', d); },
            )),
            const SizedBox(width: 8),
            Expanded(child: TextFormField(
              initialValue: '${(p['range_max'] as num?)?.toDouble() ?? 0.5}',
              decoration: InputDecoration(
                labelText: zh ? '最大值' : 'Max', isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) { final d = double.tryParse(v); if (d != null) _update('range_max', d); },
            )),
          ]),
          const SizedBox(height: 8),
          Text(zh ? '程序将在范围内随机取值（-1.0 ~ 1.0）' : 'Value will be picked randomly within range (-1.0 ~ 1.0)',
              style: TextStyle(fontSize: 11, color: cs.outline)),
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
              zh ? '使用 FFmpeg eq 滤镜调节亮度。\n范围: -1.0（全黑）到 1.0（全白），0 为不变。'
                 : 'Uses FFmpeg eq filter for brightness.\nRange: -1.0 (black) to 1.0 (white), 0 = unchanged.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
