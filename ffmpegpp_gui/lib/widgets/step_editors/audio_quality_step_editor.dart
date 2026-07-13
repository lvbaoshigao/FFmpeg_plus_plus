import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AudioQualityStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;
  const AudioQualityStepEditor({super.key, required this.params, required this.onChanged, this.isZh = true});
  @override
  State<AudioQualityStepEditor> createState() => _AudioQualityStepEditorState();
}

class _AudioQualityStepEditorState extends State<AudioQualityStepEditor> {
  Map<String, dynamic> get p => widget.params;
  late TextEditingController _customBitrateCtrl;

  static const _sampleRates = ['keep', '22050', '44100', '48000', '96000'];
  static const _sampleRateLabels = ['保持原始', '22.05 kHz', '44.1 kHz', '48 kHz', '96 kHz'];
  static const _sampleRateLabelsEn = ['Keep', '22.05 kHz', '44.1 kHz', '48 kHz', '96 kHz'];

  static const _bitratePresets = ['keep', '64', '96', '128', '192', '256', '320', 'custom'];
  static const _bitrateLabels = ['保持原样', '64 kbps', '96 kbps', '128 kbps', '192 kbps', '256 kbps', '320 kbps', '自定义'];
  static const _bitrateLabelsEn = ['Keep', '64 kbps', '96 kbps', '128 kbps', '192 kbps', '256 kbps', '320 kbps', 'Custom'];

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('bitrate_mode', () => 'keep');
    p.putIfAbsent('audio_bitrate', () => null);
    p.putIfAbsent('sample_rate', () => 'keep');
    _customBitrateCtrl = TextEditingController(text: '${(p['audio_bitrate'] as num?)?.toInt() ?? 128}');
  }

  @override
  void dispose() { _customBitrateCtrl.dispose(); super.dispose(); }

  void _update(String key, dynamic value) { setState(() => p[key] = value); widget.onChanged(); }

  InputDecoration _dec(String label) => InputDecoration(
    labelText: label, isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final sr = p['sample_rate'] as String? ?? 'keep';
    final bitrateMode = p['bitrate_mode'] as String? ?? 'keep';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '音质调整' : 'Audio Quality', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        DropdownButtonFormField<String>(
          value: _bitratePresets.contains(bitrateMode) ? bitrateMode : 'keep',
          isExpanded: true,
          decoration: _dec(zh ? '码率' : 'Bitrate'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: List.generate(_bitratePresets.length, (i) => DropdownMenuItem(
            value: _bitratePresets[i],
            child: Text(zh ? _bitrateLabels[i] : _bitrateLabelsEn[i], style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )),
          onChanged: (v) {
            if (v == null) return;
            _update('bitrate_mode', v);
            if (v == 'keep') { _update('audio_bitrate', null); }
            else if (v != 'custom') { final bv = int.tryParse(v) ?? 128; _update('audio_bitrate', bv); _customBitrateCtrl.text = '$bv'; }
          },
        ),
        if (bitrateMode == 'custom') ...[
          const SizedBox(height: 12),
          TextField(
            controller: _customBitrateCtrl,
            decoration: _dec(zh ? '自定义码率 (kbps)' : 'Custom Bitrate (kbps)'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) { final bv = int.tryParse(v); if (bv != null && bv > 0) _update('audio_bitrate', bv); },
          ),
        ],
        const SizedBox(height: 12),

        DropdownButtonFormField<String>(
          value: _sampleRates.contains(sr) ? sr : _sampleRates.first,
          isExpanded: true,
          decoration: _dec(zh ? '采样率' : 'Sample Rate'),
          dropdownColor: cs.surface,
          style: TextStyle(fontSize: 13, color: cs.onSurface),
          items: List.generate(_sampleRates.length, (i) => DropdownMenuItem(
            value: _sampleRates[i],
            child: Text(zh ? _sampleRateLabels[i] : _sampleRateLabelsEn[i], style: TextStyle(fontSize: 13, color: cs.onSurface)),
          )),
          onChanged: (v) { if (v != null) _update('sample_rate', v); },
        ),
      ]),
    );
  }
}
