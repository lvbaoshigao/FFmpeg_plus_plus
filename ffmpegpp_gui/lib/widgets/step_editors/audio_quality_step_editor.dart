import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'editor_kit.dart';

class AudioQualityStepEditor extends ParamsStepEditor {
  const AudioQualityStepEditor({super.key, required super.params, required super.onChanged, super.isZh = true});
  @override
  State<AudioQualityStepEditor> createState() => _AudioQualityStepEditorState();
}

class _AudioQualityStepEditorState extends State<AudioQualityStepEditor> with StepEditorState<AudioQualityStepEditor> {
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
    // audio_bitrate 为 null 表示不指定码率（keep），非 keep 非 custom 时写入 int kbps
    initDefaults(const {'bitrate_mode': 'keep', 'audio_bitrate': null, 'sample_rate': 'keep'});
    _customBitrateCtrl = TextEditingController(text: '${(p['audio_bitrate'] as num?)?.toInt() ?? 128}');
  }

  @override
  void dispose() { _customBitrateCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final sr = p['sample_rate'] as String? ?? 'keep';
    final bitrateMode = p['bitrate_mode'] as String? ?? 'keep';

    return StepEditorScaffold(
      title: zh ? '音质调整' : 'Audio Quality',
      children: [
        EditorDropdown(
          label: zh ? '码率' : 'Bitrate',
          value: _bitratePresets.contains(bitrateMode) ? bitrateMode : 'keep',
          items: [for (var i = 0; i < _bitratePresets.length; i++)
            (_bitratePresets[i], zh ? _bitrateLabels[i] : _bitrateLabelsEn[i])],
          dense: false,
          onChanged: (v) {
            update('bitrate_mode', v);
            if (v == 'keep') { update('audio_bitrate', null); }
            else if (v != 'custom') { final bv = int.tryParse(v) ?? 128; update('audio_bitrate', bv); _customBitrateCtrl.text = '$bv'; }
          },
        ),
        if (bitrateMode == 'custom') ...[
          const SizedBox(height: 8),
          TextField(
            controller: _customBitrateCtrl,
            decoration: InputDecoration(labelText: zh ? '自定义码率 (kbps)' : 'Custom Bitrate (kbps)'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) { final bv = int.tryParse(v); if (v.isEmpty) { update('audio_bitrate', null); } else if (bv != null && bv > 0) { update('audio_bitrate', bv); } },
          ),
        ],
        const SizedBox(height: 8),

        EditorDropdown(
          label: zh ? '采样率' : 'Sample Rate',
          value: _sampleRates.contains(sr) ? sr : _sampleRates.first,
          items: [for (var i = 0; i < _sampleRates.length; i++)
            (_sampleRates[i], zh ? _sampleRateLabels[i] : _sampleRateLabelsEn[i])],
          dense: false,
          onChanged: (v) => update('sample_rate', v),
        ),
      ],
    );
  }
}
