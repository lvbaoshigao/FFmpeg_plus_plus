import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageConvertStepEditor extends ParamsStepEditor {
  const ImageConvertStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageConvertStepEditor> createState() => _ImageConvertStepEditorState();
}

class _ImageConvertStepEditorState extends State<ImageConvertStepEditor> with StepEditorState<ImageConvertStepEditor> {
  static const _formats = ['png', 'jpg', 'bmp', 'webp', 'tiff', 'ico'];
  static const _formatLabels = ['PNG', 'JPEG', 'BMP', 'WebP', 'TIFF', 'ICO'];

  @override
  void initState() {
    super.initState();
    initDefaults(const {'output_format': 'png', 'quality': 95});
  }

  @override
  Widget build(BuildContext context) {
    final fmt = p['output_format'] as String? ?? 'png';
    final quality = (p['quality'] as num?)?.toInt() ?? 95;
    final showQuality = fmt == 'jpg' || fmt == 'webp';

    return StepEditorScaffold(
      title: zh ? '图片格式转换' : 'Image Format Conversion',
      infoText: zh ? '输入来自帧提取或其他图片源。\n通过 FFmpeg 进行图片格式转换。'
                   : 'Input comes from frame extraction or other image sources.\nConverts image format via FFmpeg.',
      children: [
        EditorDropdown(
          label: zh ? '输出格式' : 'Output Format',
          value: _formats.contains(fmt) ? fmt : _formats.first,
          items: [for (var i = 0; i < _formats.length; i++) (_formats[i], _formatLabels[i])],
          onChanged: (v) => update('output_format', v),
        ),
        const SizedBox(height: 8),

        if (showQuality) ...[
          LabeledSlider(
            text: '${zh ? "质量" : "Quality"}: $quality',
            value: quality.toDouble(), min: 1, max: 100, divisions: 99,
            sliderLabel: '$quality',
            onChanged: (v) => update('quality', v.round()),
          ),
        ],
      ],
    );
  }
}
