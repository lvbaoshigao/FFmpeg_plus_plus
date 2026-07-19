import 'package:flutter/material.dart';

class AudioConvertStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const AudioConvertStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<AudioConvertStepEditor> createState() => _AudioConvertStepEditorState();
}

class _AudioConvertStepEditorState extends State<AudioConvertStepEditor> {
  Map<String, dynamic> get p => widget.params;

  static const _codecs = ['aac', 'libmp3lame', 'libopus', 'libvorbis', 'flac', 'pcm_s16le'];
  static const _codecLabels = ['AAC', 'MP3 (LAME)', 'Opus', 'Vorbis', 'FLAC (lossless)', 'PCM 16-bit'];
  static const _formats = ['m4a', 'mp3', 'ogg', 'flac', 'wav', 'aac'];

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('audio_codec', () => 'aac');
    p.putIfAbsent('output_format', () => 'm4a');
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final codec = p['audio_codec'] as String? ?? 'aac';
    final fmt = p['output_format'] as String? ?? 'm4a';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '音频格式转换' : 'Audio Format Conversion',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: _formats.contains(fmt) ? fmt : _formats.first,
          isExpanded: true,
          decoration: InputDecoration(labelText: zh ? '输出格式' : 'Output Format'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: _formats.map((f) => DropdownMenuItem(
            value: f, child: Text(f.toUpperCase(), style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )).toList(),
          onChanged: (v) { if (v != null) _update('output_format', v); },
        ),
        const SizedBox(height: 12),

        DropdownButtonFormField<String>(
          borderRadius: BorderRadius.circular(12),
          value: _codecs.contains(codec) ? codec : _codecs.first,
          isExpanded: true,
          decoration: InputDecoration(labelText: zh ? '编码器' : 'Codec'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: List.generate(_codecs.length, (i) => DropdownMenuItem(
            value: _codecs[i],
            child: Text(_codecLabels[i], style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )),
          onChanged: (v) { if (v != null) _update('audio_codec', v); },
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
              zh ? '仅转换音频格式和编码器。\n如需调整码率和采样率，请使用"音质调整"元素。'
                 : 'Converts audio format and codec only.\nUse "Audio Quality" node to adjust bitrate and sample rate.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
