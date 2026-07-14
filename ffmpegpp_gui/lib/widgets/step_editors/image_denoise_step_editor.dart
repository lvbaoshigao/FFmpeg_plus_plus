import 'package:flutter/material.dart';

class ImageDenoiseStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ImageDenoiseStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ImageDenoiseStepEditor> createState() => _ImageDenoiseStepEditorState();
}

class _ImageDenoiseStepEditorState extends State<ImageDenoiseStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('denoise_method', () => 'nlmeans');
    p.putIfAbsent('denoise_mode', () => 'value');
    p.putIfAbsent('denoise_strength', () => 3.0);
    p.putIfAbsent('random_min', () => 1.0);
    p.putIfAbsent('random_max', () => 10.0);
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final method = p['denoise_method'] as String? ?? 'nlmeans';
    final mode = p['denoise_mode'] as String? ?? 'value';
    final strength = (p['denoise_strength'] as num?)?.toDouble() ?? 3.0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '图片降噪' : 'Image Denoise',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: method,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: zh ? '降噪算法' : 'Method', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: [
            DropdownMenuItem(value: 'nlmeans', child: Text('NLMeans', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'hqdn3d', child: Text('HQDN3D', style: TextStyle(fontSize: 13, color: cs.onSurface))),
          ],
          onChanged: (v) { if (v != null) _update('denoise_method', v); },
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
          onChanged: (v) { if (v != null) _update('denoise_mode', v); },
        ),
        const SizedBox(height: 16),

        if (mode == 'value') ...[
          Row(children: [
            Text('${zh ? "强度" : "Strength"}: ${strength.toStringAsFixed(1)}',
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: strength.clamp(1.0, 20.0), min: 1.0, max: 20.0, divisions: 38,
              label: strength.toStringAsFixed(1),
              onChanged: (v) => _update('denoise_strength', v),
            )),
          ]),
        ] else ...[
          Row(children: [
            Expanded(child: TextFormField(
              initialValue: '${(p['random_min'] as num?)?.toDouble() ?? 1.0}',
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
              initialValue: '${(p['random_max'] as num?)?.toDouble() ?? 10.0}',
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
              zh ? 'NLMeans: 非局部均值降噪，效果好但较慢。\nHQDN3D: 高质量3D降噪，速度快。'
                 : 'NLMeans: non-local means, better quality but slower.\nHQDN3D: high quality 3D denoise, faster.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
