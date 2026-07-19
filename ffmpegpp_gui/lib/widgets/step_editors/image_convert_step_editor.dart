import 'package:flutter/material.dart';

class ImageConvertStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ImageConvertStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ImageConvertStepEditor> createState() => _ImageConvertStepEditorState();
}

class _ImageConvertStepEditorState extends State<ImageConvertStepEditor> {
  Map<String, dynamic> get p => widget.params;

  static const _formats = ['png', 'jpg', 'bmp', 'webp', 'tiff', 'ico'];
  static const _formatLabels = ['PNG', 'JPEG', 'BMP', 'WebP', 'TIFF', 'ICO'];

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('output_format', () => 'png');
    p.putIfAbsent('quality', () => 95);
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final fmt = p['output_format'] as String? ?? 'png';
    final quality = (p['quality'] as num?)?.toInt() ?? 95;
    final showQuality = fmt == 'jpg' || fmt == 'webp';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '图片格式转换' : 'Image Format Conversion',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: _formats.contains(fmt) ? fmt : _formats.first,
          isExpanded: true,
          decoration: InputDecoration(labelText: zh ? '输出格式' : 'Output Format'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: List.generate(_formats.length, (i) => DropdownMenuItem(
            value: _formats[i],
            child: Text(_formatLabels[i], style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )),
          onChanged: (v) { if (v != null) _update('output_format', v); },
        ),
        const SizedBox(height: 16),

        if (showQuality) ...[
          Row(children: [
            Text('${zh ? "质量" : "Quality"}: $quality',
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: quality.toDouble(), min: 1, max: 100, divisions: 99,
              label: '$quality',
              onChanged: (v) => _update('quality', v.round()),
            )),
          ]),
          const SizedBox(height: 12),
        ],

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
              zh ? '输入来自帧提取或其他图片源。\n通过 FFmpeg 进行图片格式转换。'
                 : 'Input comes from frame extraction or other image sources.\nConverts image format via FFmpeg.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
