import 'audio_visualization_step_editor.dart';

/// Configures the size and image format of an audio spectrum.
class AudioSpectrumStepEditor extends AudioVisualizationStepEditor {
  const AudioSpectrumStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh,
  }) : super(waveform: false);
}
