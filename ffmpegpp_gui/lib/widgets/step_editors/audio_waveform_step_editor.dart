import 'audio_visualization_step_editor.dart';

/// Configures the size and image format of an audio waveform.
class AudioWaveformStepEditor extends AudioVisualizationStepEditor {
  const AudioWaveformStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  }) : super(waveform: true);
}
