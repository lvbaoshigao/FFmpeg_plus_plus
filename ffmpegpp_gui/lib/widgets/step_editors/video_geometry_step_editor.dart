import 'package:flutter/material.dart';
import 'editor_kit.dart';

/// 画面变换：缩放 / 翻转 / 旋转，执行时拼成一条 `-vf` 链（顺序固定）。
///
/// 参数：
/// - `scale_mode`：none / width / height / percent
/// - `scale_width` `scale_height` `scale_percent`：对应模式的数值
/// - `flip`：none / hflip / vflip / both
/// - `rotate`：none / 90 / 180 / 270
///
/// 与「音视频处理」的分辨率不同：此节点可在链路中任意位置生效，
/// 且缩放不改变音频，可与视频滤镜、叠加自由串联。
class VideoGeometryStepEditor extends ParamsStepEditor {
  const VideoGeometryStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<VideoGeometryStepEditor> createState() => _VideoGeometryStepEditorState();
}

class _VideoGeometryStepEditorState extends State<VideoGeometryStepEditor> with StepEditorState<VideoGeometryStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {
      'scale_mode': 'none',
      'scale_width': 1280,
      'scale_height': 720,
      'scale_percent': 100.0,
      'flip': 'none',
      'rotate': 'none',
    });
  }

  @override
  Widget build(BuildContext context) {
    final scaleMode = p['scale_mode'] as String? ?? 'none';
    final flip = p['flip'] as String? ?? 'none';
    final rotate = p['rotate'] as String? ?? 'none';
    final w = (p['scale_width'] as num?)?.toInt() ?? 1280;
    final h = (p['scale_height'] as num?)?.toInt() ?? 720;
    final pct = (p['scale_percent'] as num?)?.toDouble() ?? 100.0;

    return StepEditorScaffold(
      title: zh ? '画面变换' : 'Geometry',
      scrollable: true,
      infoText: zh
          ? '变换顺序固定为：缩放 → 翻转 → 旋转。\n缩放使用 -2 自动保持宽高比为偶数，避免编码器报错。'
          : 'Order is fixed: scale → flip → rotate.\nScaling uses -2 to keep dimensions even.',
      children: [
        EditorDropdown(
          label: zh ? '缩放' : 'Scale',
          value: scaleMode,
          items: [
            ('none', zh ? '不缩放' : 'None'),
            ('width', zh ? '指定宽度' : 'Fixed width'),
            ('height', zh ? '指定高度' : 'Fixed height'),
            ('percent', zh ? '按百分比' : 'Percent'),
          ],
          onChanged: (v) => update('scale_mode', v),
        ),

        if (scaleMode == 'width') ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final v in [640, 1280, 1920, 2560])
              ChoiceChip(
                label: Text('$v', style: const TextStyle(fontSize: 12)),
                selected: w == v,
                onSelected: (_) => update('scale_width', v),
              ),
          ]),
          const SizedBox(height: 8),
          TextFormField(
            key: const ValueKey('vg_width'),
            initialValue: '$w',
            decoration: editorDenseField(zh ? '宽度 (px)' : 'Width (px)'),
            keyboardType: TextInputType.number,
            onChanged: (v) { final d = int.tryParse(v); if (d != null) update('scale_width', d); },
          ),
        ],

        if (scaleMode == 'height') ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final v in [360, 480, 720, 1080])
              ChoiceChip(
                label: Text('$v', style: const TextStyle(fontSize: 12)),
                selected: h == v,
                onSelected: (_) => update('scale_height', v),
              ),
          ]),
          const SizedBox(height: 8),
          TextFormField(
            key: const ValueKey('vg_height'),
            initialValue: '$h',
            decoration: editorDenseField(zh ? '高度 (px)' : 'Height (px)'),
            keyboardType: TextInputType.number,
            onChanged: (v) { final d = int.tryParse(v); if (d != null) update('scale_height', d); },
          ),
        ],

        if (scaleMode == 'percent') ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final v in [25.0, 50.0, 75.0, 200.0])
              ChoiceChip(
                label: Text('${v.toInt()}%', style: const TextStyle(fontSize: 12)),
                selected: (pct - v).abs() < 0.01,
                onSelected: (_) => update('scale_percent', v),
              ),
          ]),
          const SizedBox(height: 8),
          LabeledSlider(
            text: '${zh ? "百分比" : "Percent"}: ${pct.toStringAsFixed(0)}%',
            value: pct.clamp(1.0, 400.0), min: 1.0, max: 400.0, divisions: 80,
            sliderLabel: '${pct.toStringAsFixed(0)}%',
            onChanged: (v) => update('scale_percent', v),
          ),
        ],

        const SizedBox(height: 8),
        EditorDropdown(
          label: zh ? '翻转' : 'Flip',
          value: flip,
          items: [
            ('none', zh ? '不翻转' : 'None'),
            ('hflip', zh ? '水平翻转' : 'Horizontal'),
            ('vflip', zh ? '垂直翻转' : 'Vertical'),
            ('both', zh ? '水平 + 垂直' : 'Both'),
          ],
          onChanged: (v) => update('flip', v),
        ),

        const SizedBox(height: 8),
        EditorDropdown(
          label: zh ? '旋转' : 'Rotate',
          value: rotate,
          items: [
            ('none', zh ? '不旋转' : 'None'),
            ('90', zh ? '顺时针 90°' : '90° CW'),
            ('180', '180°'),
            ('270', zh ? '顺时针 270°' : '270° CW'),
          ],
          onChanged: (v) => update('rotate', v),
        ),
      ],
    );
  }
}
