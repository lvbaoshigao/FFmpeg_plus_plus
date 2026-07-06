import 'package:flutter/material.dart';

class ExtractAudioStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ExtractAudioStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<ExtractAudioStepEditor> createState() => _ExtractAudioStepEditorState();
}

class _ExtractAudioStepEditorState extends State<ExtractAudioStepEditor> {
  Map<String, dynamic> get p => widget.params;

  static const _codecs = ['copy', 'aac', 'libmp3lame', 'flac', 'libopus', 'pcm_s16le'];
  static const _codecLabels = ['复制流 (无损)', 'AAC', 'MP3 (LAME)', 'FLAC', 'Opus', 'PCM 16-bit'];
  static const _codecLabelsEn = ['Copy (lossless)', 'AAC', 'MP3 (LAME)', 'FLAC', 'Opus', 'PCM 16-bit'];
  static const _formats = ['m4a', 'mp3', 'flac', 'ogg', 'wav', 'aac'];

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('audio_codec', () => 'copy');
    p.putIfAbsent('audio_bitrate', () => 128);
    p.putIfAbsent('output_format', () => 'm4a');
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  InputDecoration _dec(String label) => InputDecoration(
    labelText: label, isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final codec = p['audio_codec'] as String? ?? 'copy';
    final bitrate = (p['audio_bitrate'] as num?)?.toInt() ?? 128;
    final fmt = p['output_format'] as String? ?? 'm4a';
    final showBitrate = codec != 'copy' && codec != 'flac' && codec != 'pcm_s16le';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '提取音频' : 'Extract Audio',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          value: _formats.contains(fmt) ? fmt : _formats.first,
          isExpanded: true,
          decoration: _dec(zh ? '输出格式' : 'Output Format'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: _formats.map((f) => DropdownMenuItem(
            value: f, child: Text(f.toUpperCase(), style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )).toList(),
          onChanged: (v) { if (v != null) _update('output_format', v); },
        ),
        const SizedBox(height: 12),

        DropdownButtonFormField<String>(
          value: _codecs.contains(codec) ? codec : _codecs.first,
          isExpanded: true,
          decoration: _dec(zh ? '编码器' : 'Codec'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: List.generate(_codecs.length, (i) => DropdownMenuItem(
            value: _codecs[i],
            child: Text(zh ? _codecLabels[i] : _codecLabelsEn[i],
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )),
          onChanged: (v) { if (v != null) _update('audio_codec', v); },
        ),
        const SizedBox(height: 12),

        if (showBitrate) ...[
          Row(children: [
            Text('${zh ? "码率" : "Bitrate"}: ${bitrate}k',
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: bitrate.toDouble(), min: 32, max: 320, divisions: 18,
              label: '${bitrate}k',
              onChanged: (v) => _update('audio_bitrate', v.round()),
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
              zh ? '从视频中提取音频轨道。\n选择"复制流"可无损提取原始音频，速度最快。'
                 : 'Extract audio track from video.\nSelect "Copy" for lossless extraction (fastest).',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
