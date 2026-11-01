import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// 图片压缩节点编辑器。
///
/// 与「图片转换」共用后端 image_convert 执行器，但语义聚焦在**体积**：
/// 质量越低体积越小；输出格式决定使用哪种编码器（JPEG/WebP 才受质量影响）。
class ImageCompressStepEditor extends ParamsStepEditor {
  const ImageCompressStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  });

  @override
  State<ImageCompressStepEditor> createState() => _ImageCompressStepEditorState();
}

class _ImageCompressStepEditorState extends State<ImageCompressStepEditor>
    with StepEditorState<ImageCompressStepEditor> {
  static const _formats = ['keep', 'jpg', 'webp', 'png'];
  static const _formatLabelsZh = ['保持原格式', 'JPEG', 'WebP', 'PNG'];
  static const _formatLabelsEn = ['Keep Original', 'JPEG', 'WebP', 'PNG'];

  @override
  void initState() {
    super.initState();
    initDefaults(const {'output_format': 'keep', 'quality': 75});
  }

  @override
  Widget build(BuildContext context) {
    final fmt = (p['output_format'] as String? ?? 'keep').toLowerCase();
    final quality = (p['quality'] as num?)?.toInt() ?? 75;
    final showQuality = fmt != 'png';
    final zh = this.zh;

    return StepEditorScaffold(
      title: zh ? '图片压缩' : 'Image Compression',
      infoText: zh
          ? '通过重新编码降低图片体积：JPEG/WebP 的质量越低文件越小，\n'
              'PNG 为无损格式，质量参数对它无效。'
          : 'Shrinks images by re-encoding: lower JPEG/WebP quality means a smaller file.\n'
              'PNG is lossless, so the quality value does not apply.',
      children: [
        EditorDropdown(
          label: zh ? '输出格式' : 'Output Format',
          value: _formats.contains(fmt) ? fmt : 'keep',
          items: [
            for (var i = 0; i < _formats.length; i++)
              (_formats[i], zh ? _formatLabelsZh[i] : _formatLabelsEn[i]),
          ],
          onChanged: (v) => update('output_format', v),
        ),
        const SizedBox(height: 8),
        if (showQuality) ...[
          LabeledSlider(
            text: '${zh ? "编码质量" : "Quality"}: $quality',
            value: quality.toDouble().clamp(1, 100),
            min: 1,
            max: 100,
            divisions: 99,
            sliderLabel: '$quality',
            onChanged: (v) => update('quality', v.round()),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              zh
                  ? '质量越低体积越小，推荐 60~85；低于 50 可能出现明显噪点/色块'
                  : 'Lower = smaller. 60–85 recommended; below 50 may show artifacts',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
