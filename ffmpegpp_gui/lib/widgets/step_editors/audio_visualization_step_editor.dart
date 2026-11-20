import 'package:flutter/material.dart';

import 'editor_kit.dart';
import 'media_step_editor_controls.dart';

/// Shared size and image-format controls for audio visualizations.
abstract class AudioVisualizationStepEditor extends ParamsStepEditor {
  const AudioVisualizationStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    required this.waveform,
    super.isZh,
  });

  final bool waveform;

  @override
  State<AudioVisualizationStepEditor> createState() =>
      _AudioVisualizationStepEditorState();
}

class _AudioVisualizationStepEditorState
    extends State<AudioVisualizationStepEditor>
    with StepEditorState<AudioVisualizationStepEditor> {
  @override
  void initState() {
    super.initState();
    _prepareParams();
  }

  @override
  void didUpdateWidget(covariant AudioVisualizationStepEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.params, widget.params)) {
      _prepareParams();
    }
  }

  void _prepareParams() {
    initDefaults(const {'width': 1280, 'height': 720, 'output_format': 'png'});
    p['width'] = editorNumberInRange(
      p['width'],
      fallback: 1280,
      min: 64,
      max: 4096,
    ).toInt();
    p['height'] = editorNumberInRange(
      p['height'],
      fallback: 720,
      min: 64,
      max: 4096,
    ).toInt();
    final rawFormat = p['output_format'].toString().trim().toLowerCase();
    final format = rawFormat == 'jpeg' ? 'jpg' : rawFormat;
    p['output_format'] = const ['png', 'jpg', 'webp'].contains(format)
        ? format
        : 'png';
  }

  @override
  Widget build(BuildContext context) {
    final prefix = widget.waveform ? 'audio_waveform' : 'audio_spectrum';
    return StepEditorScaffold(
      key: ObjectKey(p),
      title: widget.waveform
          ? (zh ? '音频波形图' : 'Audio waveform')
          : (zh ? '音频频谱图' : 'Audio spectrum'),
      description: widget.waveform
          ? (zh
                ? '将随时间变化的音频振幅导出为单张图像。'
                : 'Export the audio’s amplitude over time as a single image.')
          : (zh
                ? '将音频的频率分布导出为单张图像。'
                : 'Export the audio’s frequency distribution as a single image.'),
      scrollable: true,
      infoText: zh
          ? '输出为静态图像，不包含音频。后续可连接图像处理节点。'
          : 'The output is a still image without audio. It can feed image-processing nodes.',
      children: [
        EditorFieldPair(
          first: EditorNumberField(
            key: ValueKey('${prefix}_width'),
            label: zh ? '宽度' : 'Width',
            value: p['width'] as int,
            min: 64,
            max: 4096,
            integer: true,
            unit: 'px',
            helper: '64–4096 px',
            isZh: zh,
            onChanged: (value) => update('width', value.toInt()),
          ),
          second: EditorNumberField(
            key: ValueKey('${prefix}_height'),
            label: zh ? '高度' : 'Height',
            value: p['height'] as int,
            min: 64,
            max: 4096,
            integer: true,
            unit: 'px',
            helper: '64–4096 px',
            isZh: zh,
            onChanged: (value) => update('height', value.toInt()),
          ),
        ),
        const SizedBox(height: 20),
        EditorChoiceField(
          key: ValueKey('${prefix}_format'),
          label: zh ? '图像格式' : 'Image format',
          value: p['output_format'] as String,
          items: const [('png', 'PNG'), ('jpg', 'JPG'), ('webp', 'WebP')],
          onChanged: (value) => update('output_format', value),
        ),
        const SizedBox(height: 12),
        Text(
          '${p['width']} × ${p['height']} px · ${p['output_format'].toString().toUpperCase()}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
