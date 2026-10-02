import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'editor_kit.dart';

/// 画面叠加：把一张图片（水印 / Logo）叠到画面指定位置。
///
/// 参数：
/// - `overlay_path`：叠加图片路径（为空时该节点在链路上跳过，不报错）
/// - `position`：top-left / top-right / bottom-left / bottom-right / center
/// - `opacity`：叠加图透明度 0–1
/// - `margin`：距边缘像素
/// - `overlay_scale`：叠加图相对原尺寸的百分比
class VideoOverlayStepEditor extends ParamsStepEditor {
  const VideoOverlayStepEditor({super.key, required super.params, required super.onChanged, super.isZh});

  @override
  State<VideoOverlayStepEditor> createState() => _VideoOverlayStepEditorState();
}

class _VideoOverlayStepEditorState extends State<VideoOverlayStepEditor> with StepEditorState<VideoOverlayStepEditor> {
  @override
  void initState() {
    super.initState();
    initDefaults(const {
      'overlay_path': '',
      'position': 'bottom-right',
      'opacity': 1.0,
      'margin': 16,
      'overlay_scale': 100.0,
    });
  }

  Future<void> _pickOverlay() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'bmp', 'webp', 'gif'],
    );
    if (picked?.path == null) return;
    if (!mounted) return;
    update('overlay_path', picked!.path!);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final path = p['overlay_path'] as String? ?? '';
    final pos = p['position'] as String? ?? 'bottom-right';
    final opacity = (p['opacity'] as num?)?.toDouble() ?? 1.0;
    final margin = (p['margin'] as num?)?.toInt() ?? 16;
    final scalePct = (p['overlay_scale'] as num?)?.toDouble() ?? 100.0;
    final fileName = path.isEmpty ? '' : path.split(RegExp(r'[\\/]')).last;

    return StepEditorScaffold(
      title: zh ? '画面叠加' : 'Overlay',
      scrollable: true,
      infoText: zh
          ? '建议使用带透明通道的 PNG。\n叠加会重新编码视频，若只需缩放请用「画面变换」。'
          : 'A PNG with alpha is recommended.\nOverlay re-encodes video; use Geometry for scaling only.',
      children: [
        Text(zh ? '叠加素材（水印 / Logo）' : 'Overlay image (watermark / logo)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 8),
        if (path.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(60),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              if (File(path).existsSync())
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(File(path), width: 48, height: 48, fit: BoxFit.cover,
                      cacheWidth: 144, errorBuilder: (_, _, _) => Icon(Icons.broken_image, size: 32, color: cs.outline)),
                )
              else
                Icon(Icons.image_not_supported_outlined, size: 32, color: cs.outline),
              const SizedBox(width: 10),
              Expanded(
                child: Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurface)),
              ),
            ]),
          ),
          const SizedBox(height: 8),
        ],
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _pickOverlay,
              icon: const Icon(Icons.image_outlined, size: 16),
              label: Text(path.isEmpty ? (zh ? '选择图片' : 'Choose image') : (zh ? '重新选择' : 'Change'),
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
          if (path.isNotEmpty) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: zh ? '清除' : 'Clear',
              onPressed: () => update('overlay_path', ''),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ]),

        const SizedBox(height: 12),
        EditorDropdown(
          label: zh ? '位置' : 'Position',
          value: pos,
          items: [
            ('top-left', zh ? '左上' : 'Top-left'),
            ('top-right', zh ? '右上' : 'Top-right'),
            ('bottom-left', zh ? '左下' : 'Bottom-left'),
            ('bottom-right', zh ? '右下' : 'Bottom-right'),
            ('center', zh ? '居中' : 'Center'),
          ],
          onChanged: (v) => update('position', v),
        ),

        const SizedBox(height: 8),
        LabeledSlider(
          text: '${zh ? "透明度" : "Opacity"}: ${(opacity * 100).toStringAsFixed(0)}%',
          value: opacity.clamp(0.0, 1.0), min: 0.0, max: 1.0, divisions: 20,
          sliderLabel: '${(opacity * 100).toStringAsFixed(0)}%',
          onChanged: (v) => update('opacity', v),
        ),
        LabeledSlider(
          text: '${zh ? "缩放" : "Scale"}: ${scalePct.toStringAsFixed(0)}%',
          value: scalePct.clamp(1.0, 100.0), min: 1.0, max: 100.0, divisions: 99,
          sliderLabel: '${scalePct.toStringAsFixed(0)}%',
          onChanged: (v) => update('overlay_scale', v),
        ),

        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('vo_margin'),
          initialValue: '$margin',
          decoration: editorDenseField(zh ? '边距 (px)' : 'Margin (px)'),
          keyboardType: TextInputType.number,
          onChanged: (v) { final d = int.tryParse(v); if (d != null) update('margin', d); },
        ),

        const SizedBox(height: 4),
        if (path.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: EditorInfoBox(
              zh ? '尚未选择叠加图片：该节点在当前链路中会被跳过，不会导致任务失败。'
                 : 'No overlay image selected: this node is skipped in the chain.',
              color: cs.tertiary,
            ),
          ),
      ],
    );
  }
}
