import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  late TextEditingController _customBitrateCtrl;

  static const _codecs = ['aac', 'libmp3lame', 'libopus', 'libvorbis', 'flac', 'pcm_s16le'];
  static const _codecLabels = ['AAC', 'MP3 (LAME)', 'Opus', 'Vorbis', 'FLAC (lossless)', 'PCM 16-bit'];
  static const _formats = ['m4a', 'mp3', 'ogg', 'flac', 'wav', 'aac'];
  static const _sampleRates = ['keep', '44100', '48000', '96000'];
  static const _sampleRateLabels = ['保持原始', '44.1 kHz', '48 kHz', '96 kHz'];
  static const _sampleRateLabelsEn = ['Keep', '44.1 kHz', '48 kHz', '96 kHz'];

  static const _bitratePresets = ['keep', '64', '96', '128', '192', '256', '320', 'custom'];
  static const _bitrateLabels = ['保持原样', '64 kbps', '96 kbps', '128 kbps', '192 kbps', '256 kbps', '320 kbps', '自定义'];
  static const _bitrateLabelsEn = ['Keep Original', '64 kbps', '96 kbps', '128 kbps', '192 kbps', '256 kbps', '320 kbps', 'Custom'];

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('audio_codec', () => 'aac');
    p.putIfAbsent('audio_bitrate', () => 128);
    p.putIfAbsent('bitrate_mode', () => '128');
    p.putIfAbsent('output_format', () => 'm4a');
    p.putIfAbsent('sample_rate', () => 'keep');
    _customBitrateCtrl = TextEditingController(
      text: '${(p['audio_bitrate'] as num?)?.toInt() ?? 128}',
    );
  }

  @override
  void dispose() {
    _customBitrateCtrl.dispose();
    super.dispose();
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
    final codec = p['audio_codec'] as String? ?? 'aac';
    final fmt = p['output_format'] as String? ?? 'm4a';
    final sr = p['sample_rate'] as String? ?? 'keep';
    final isLossless = codec == 'flac' || codec == 'pcm_s16le';
    final bitrateMode = p['bitrate_mode'] as String? ?? '128';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '音频格式转换' : 'Audio Format Conversion',
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
            child: Text(_codecLabels[i], style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )),
          onChanged: (v) { if (v != null) _update('audio_codec', v); },
        ),
        const SizedBox(height: 12),

        if (!isLossless) ...[
          DropdownButtonFormField<String>(
            value: _bitratePresets.contains(bitrateMode) ? bitrateMode : '128',
            isExpanded: true,
            decoration: _dec(zh ? '码率' : 'Bitrate'),
            dropdownColor: cs.surface,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            items: List.generate(_bitratePresets.length, (i) => DropdownMenuItem(
              value: _bitratePresets[i],
              child: Text(zh ? _bitrateLabels[i] : _bitrateLabelsEn[i],
                  style: TextStyle(fontSize: 13, color: cs.onSurface)),
            )),
            onChanged: (v) {
              if (v == null) return;
              _update('bitrate_mode', v);
              if (v == 'keep') {
                _update('audio_bitrate', null);
              } else if (v != 'custom') {
                final bv = int.tryParse(v) ?? 128;
                _update('audio_bitrate', bv);
                _customBitrateCtrl.text = '$bv';
              }
            },
          ),
          if (bitrateMode == 'custom') ...[
            const SizedBox(height: 12),
            TextField(
              controller: _customBitrateCtrl,
              decoration: _dec(zh ? '自定义码率 (kbps)' : 'Custom Bitrate (kbps)'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (v) {
                final bv = int.tryParse(v);
                if (bv != null && bv > 0) _update('audio_bitrate', bv);
              },
            ),
          ],
          const SizedBox(height: 12),
        ],

        DropdownButtonFormField<String>(
          value: _sampleRates.contains(sr) ? sr : _sampleRates.first,
          isExpanded: true,
          decoration: _dec(zh ? '采样率' : 'Sample Rate'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: List.generate(_sampleRates.length, (i) => DropdownMenuItem(
            value: _sampleRates[i],
            child: Text(zh ? _sampleRateLabels[i] : _sampleRateLabelsEn[i],
                style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )),
          onChanged: (v) { if (v != null) _update('sample_rate', v); },
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
              zh ? '输入来自提取音频或其他音频源。\nFLAC 和 PCM 为无损格式，不需要码率设置。\n选择"保持原样"将不改变原始码率。'
                 : 'Input comes from audio extraction or other audio sources.\nFLAC and PCM are lossless — no bitrate needed.\nSelect "Keep Original" to preserve the source bitrate.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }
}
