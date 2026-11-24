import 'package:flutter/material.dart';
import 'editor_kit.dart';

/// 视频滤镜：勾选若干调色/增强预设，执行时拼成一条 `-vf` 链。
///
/// 参数：
/// - `presets`：勾选的预设名列表（brightness/contrast/saturation/gamma/hue/
///   vignette/denoise/sharpen/grayscale）
/// - `eq_brightness` `eq_contrast` `eq_saturation` `eq_gamma`：eq 滤镜分量
/// - `hue_degrees`：hue 滤镜色相角度
/// - `vignette_angle`：暗角角度
/// - `denoise_strength`：hqdn3d 空间强度
/// - `unsharp_amount`：锐化强度
class VideoFilterStepEditor extends ParamsStepEditor {
  const VideoFilterStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<VideoFilterStepEditor> createState() => _VideoFilterStepEditorState();
}

class _VideoFilterStepEditorState extends State<VideoFilterStepEditor> with StepEditorState<VideoFilterStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {
      'presets': <String>[],
      'eq_brightness': 0.0,
      'eq_contrast': 1.0,
      'eq_saturation': 1.0,
      'eq_gamma': 1.0,
      'hue_degrees': 0.0,
      'vignette_angle': 0.62831853,
      'denoise_strength': 6.0,
      'unsharp_amount': 1.0,
    });
  }

  List<String> get _presets =>
      (p['presets'] as List?)?.whereType<String>().toList() ?? <String>[];

  void _toggle(String key, bool on) {
    final list = _presets;
    if (on) {
      if (!list.contains(key)) list.add(key);
    } else {
      list.remove(key);
    }
    update('presets', list);
  }

  bool _has(String key) => _presets.contains(key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget presetChip(String key, String zhLabel, String enLabel) => FilterChip(
          label: Text(zh ? zhLabel : enLabel, style: const TextStyle(fontSize: 12)),
          selected: _has(key),
          onSelected: (v) => _toggle(key, v),
        );

    final children = <Widget>[
      Text(zh ? '选择滤镜（可多选）' : 'Filters (multi-select)',
          style: TextStyle(fontSize: 12, color: cs.outline)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        presetChip('brightness', '亮度', 'Brightness'),
        presetChip('contrast', '对比度', 'Contrast'),
        presetChip('saturation', '饱和度', 'Saturation'),
        presetChip('gamma', '伽马', 'Gamma'),
        presetChip('hue', '色相', 'Hue'),
        presetChip('vignette', '暗角', 'Vignette'),
        presetChip('denoise', '视频降噪', 'Video Denoise'),
        presetChip('sharpen', '视频锐化', 'Video Sharpen'),
        presetChip('grayscale', '黑白', 'Grayscale'),
      ]),
    ];

    void addSlider(String preset, String key, String label, double min, double max, double def, int div) {
      if (!_has(preset)) return;
      final v = (p[key] as num?)?.toDouble() ?? def;
      children.add(const SizedBox(height: 8));
      children.add(LabeledSlider(
        text: '$label: ${v.toStringAsFixed(2)}',
        value: v.clamp(min, max), min: min, max: max, divisions: div,
        sliderLabel: v.toStringAsFixed(2),
        onChanged: (nv) => update(key, nv),
      ));
    }

    addSlider('brightness', 'eq_brightness', zh ? '亮度' : 'Brightness', -1.0, 1.0, 0.0, 40);
    addSlider('contrast', 'eq_contrast', zh ? '对比度' : 'Contrast', 0.0, 4.0, 1.0, 80);
    addSlider('saturation', 'eq_saturation', zh ? '饱和度' : 'Saturation', 0.0, 3.0, 1.0, 60);
    addSlider('gamma', 'eq_gamma', zh ? '伽马' : 'Gamma', 0.1, 10.0, 1.0, 99);
    addSlider('hue', 'hue_degrees', zh ? '色相角度' : 'Hue °', -180.0, 180.0, 0.0, 72);
    addSlider('vignette', 'vignette_angle', zh ? '暗角强度' : 'Vignette', 0.0, 3.14159, 0.62831853, 60);
    addSlider('denoise', 'denoise_strength', zh ? '降噪强度' : 'Denoise', 0.0, 30.0, 6.0, 60);
    addSlider('sharpen', 'unsharp_amount', zh ? '锐化强度' : 'Sharpen', 0.0, 5.0, 1.0, 50);

    return StepEditorScaffold(
      title: zh ? '视频滤镜' : 'Video Filter',
      scrollable: true,
      infoText: zh
          ? '多个滤镜会按固定顺序合并为单条 ffmpeg 命令，不产生中间文件。\n未勾选任何滤镜时该节点不改变画面。'
          : 'Selected filters merge into a single ffmpeg command.\nWith no filter selected this node leaves the frame unchanged.',
      children: children,
    );
  }
}
