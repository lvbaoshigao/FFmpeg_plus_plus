import 'package:flutter/material.dart';
import 'editor_kit.dart';

class AudioConvertStepEditor extends ParamsStepEditor {
  const AudioConvertStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<AudioConvertStepEditor> createState() => _AudioConvertStepEditorState();
}

class _AudioConvertStepEditorState extends State<AudioConvertStepEditor> with StepEditorState<AudioConvertStepEditor> {
  static const _codecs = ['aac', 'libmp3lame', 'libopus', 'libvorbis', 'flac', 'pcm_s16le'];
  static const _codecLabels = ['AAC', 'MP3 (LAME)', 'Opus', 'Vorbis', 'FLAC (lossless)', 'PCM 16-bit'];
  static const _formats = ['m4a', 'mp3', 'ogg', 'flac', 'wav', 'aac'];

  @override
  void initState() {
    super.initState();
    initDefaults(const {'audio_codec': 'aac', 'output_format': 'm4a'});
  }

  @override
  Widget build(BuildContext context) {
    final codec = p['audio_codec'] as String? ?? 'aac';
    final fmt = p['output_format'] as String? ?? 'm4a';

    return StepEditorScaffold(
      title: zh ? '音频格式转换' : 'Audio Format Conversion',
      infoText: zh ? '仅转换音频格式和编码器。\n如需调整码率和采样率，请使用"音质调整"元素。'
                   : 'Converts audio format and codec only.\nUse "Audio Quality" node to adjust bitrate and sample rate.',
      children: [
        EditorDropdown(
          label: zh ? '输出格式' : 'Output Format',
          value: _formats.contains(fmt) ? fmt : _formats.first,
          items: [for (final f in _formats) (f, f.toUpperCase())],
          onChanged: (v) => update('output_format', v),
        ),
        const SizedBox(height: 8),

        EditorDropdown(
          label: zh ? '编码器' : 'Codec',
          value: _codecs.contains(codec) ? codec : _codecs.first,
          items: [for (var i = 0; i < _codecs.length; i++) (_codecs[i], _codecLabels[i])],
          onChanged: (v) => update('audio_codec', v),
        ),
      ],
    );
  }
}
