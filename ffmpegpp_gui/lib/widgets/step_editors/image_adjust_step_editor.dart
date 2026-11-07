import 'package:flutter/material.dart';
import 'editor_kit.dart';

/// 图片调整：饱和度 / 伽马 / 对比度（eq 滤镜）。
///
/// 与「亮度调节」节点互补 —— 亮度节点只有 brightness 分量，
/// 本节点补齐饱和度/伽马/对比度。三者均为默认值时退化为文件直接复制。
class ImageAdjustStepEditor extends ParamsStepEditor {
  const ImageAdjustStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<ImageAdjustStepEditor> createState() => _ImageAdjustStepEditorState();
}

class _ImageAdjustStepEditorState extends State<ImageAdjustStepEditor> with StepEditorState<ImageAdjustStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {'saturation': 1.0, 'gamma': 1.0, 'contrast': 1.0});
  }

  @override
  Widget build(BuildContext context) {
    final sat = (p['saturation'] as num?)?.toDouble() ?? 1.0;
    final gamma = (p['gamma'] as num?)?.toDouble() ?? 1.0;
    final contrast = (p['contrast'] as num?)?.toDouble() ?? 1.0;

    return StepEditorScaffold(
      title: zh ? '图片调整' : 'Image Adjust',
      infoText: zh
          ? '三项均为 1.00 时不做处理，直接复制文件（不重编码）。\n饱和度 0 = 灰度，伽马 <1 变亮，对比度 1.0 为原样。'
          : 'All values at 1.00 copies the file without re-encoding.\nSaturation 0 = grayscale, gamma <1 brightens.',
      children: [
        LabeledSlider(
          text: '${zh ? "饱和度" : "Saturation"}: ${sat.toStringAsFixed(2)}',
          value: sat.clamp(0.0, 3.0), min: 0.0, max: 3.0, divisions: 60,
          sliderLabel: sat.toStringAsFixed(2),
          onChanged: (v) => update('saturation', v),
        ),
        LabeledSlider(
          text: '${zh ? "伽马" : "Gamma"}: ${gamma.toStringAsFixed(2)}',
          value: gamma.clamp(0.1, 10.0), min: 0.1, max: 10.0, divisions: 99,
          sliderLabel: gamma.toStringAsFixed(2),
          onChanged: (v) => update('gamma', v),
        ),
        LabeledSlider(
          text: '${zh ? "对比度" : "Contrast"}: ${contrast.toStringAsFixed(2)}',
          value: contrast.clamp(0.0, 4.0), min: 0.0, max: 4.0, divisions: 80,
          sliderLabel: contrast.toStringAsFixed(2),
          onChanged: (v) => update('contrast', v),
        ),
      ],
    );
  }
}
