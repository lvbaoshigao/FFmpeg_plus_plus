import 'package:flutter/material.dart';

class ImageChannelExtractStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ImageChannelExtractStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ImageChannelExtractStepEditor> createState() => _ImageChannelExtractStepEditorState();
}

class _ImageChannelExtractStepEditorState extends State<ImageChannelExtractStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('channel', () => 'r');
    p.putIfAbsent('extract_method', () => 'colorize');
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final channel = p['channel'] as String? ?? 'r';
    final method = p['extract_method'] as String? ?? 'colorize';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '通道提取' : 'Channel Extract',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        Text(zh ? '选择通道' : 'Select Channel',
            style: TextStyle(fontSize: 13, color: cs.onSurface)),
        const SizedBox(height: 8),
        Row(children: [
          _channelChip('r', 'R', Colors.red, channel, cs),
          const SizedBox(width: 8),
          _channelChip('g', 'G', Colors.green, channel, cs),
          const SizedBox(width: 8),
          _channelChip('b', 'B', Colors.blue, channel, cs),
        ]),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          value: method,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: zh ? '提取方式' : 'Extract Method', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: [
            DropdownMenuItem(value: 'colorize', child: Text(zh ? '保留颜色（其他通道置零）' : 'Colorize (zero other channels)', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            DropdownMenuItem(value: 'isolate', child: Text(zh ? '灰度提取（单通道灰度图）' : 'Isolate (grayscale)', style: TextStyle(fontSize: 13, color: cs.onSurface))),
          ],
          onChanged: (v) { if (v != null) _update('extract_method', v); },
        ),

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
              zh ? '保留颜色：使用 colorchannelmixer 将其他通道置零。\n灰度提取：使用 extractplanes 输出单通道灰度图。'
                 : 'Colorize: uses colorchannelmixer to zero other channels.\nIsolate: uses extractplanes for single-channel grayscale.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }

  Widget _channelChip(String value, String label, Color color, String selected, ColorScheme cs) {
    final isSelected = selected == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => _update('channel', value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? color.withAlpha(40) : cs.surfaceContainerHighest.withAlpha(80),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isSelected ? color : cs.outlineVariant.withAlpha(60), width: isSelected ? 2 : 1),
          ),
          child: Center(child: Text(label,
            style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700,
              color: isSelected ? color : cs.onSurfaceVariant,
            ),
          )),
        ),
      ),
    );
  }
}
