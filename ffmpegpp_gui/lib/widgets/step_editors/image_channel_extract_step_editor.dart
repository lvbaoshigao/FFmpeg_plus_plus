import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageChannelExtractStepEditor extends ParamsStepEditor {
  const ImageChannelExtractStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageChannelExtractStepEditor> createState() => _ImageChannelExtractStepEditorState();
}

class _ImageChannelExtractStepEditorState extends State<ImageChannelExtractStepEditor> with StepEditorState<ImageChannelExtractStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'channel': 'r', 'extract_method': 'colorize'});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final channel = p['channel'] as String? ?? 'r';
    final method = p['extract_method'] as String? ?? 'colorize';

    return StepEditorScaffold(
      title: zh ? '通道提取' : 'Channel Extract',
      infoText: zh ? '保留颜色：使用 colorchannelmixer 将其他通道置零。\n灰度提取：使用 extractplanes 输出单通道灰度图。'
                   : 'Colorize: uses colorchannelmixer to zero other channels.\nIsolate: uses extractplanes for single-channel grayscale.',
      children: [
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
        const SizedBox(height: 8),

        EditorDropdown(
          label: zh ? '提取方式' : 'Extract Method',
          value: method,
          items: [
            ('colorize', zh ? '保留颜色（其他通道置零）' : 'Colorize (zero other channels)'),
            ('isolate', zh ? '灰度提取（单通道灰度图）' : 'Isolate (grayscale)'),
          ],
          onChanged: (v) => update('extract_method', v),
        ),
      ],
    );
  }

  Widget _channelChip(String value, String label, Color color, String selected, ColorScheme cs) {
    final isSelected = selected == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => update('channel', value),
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
