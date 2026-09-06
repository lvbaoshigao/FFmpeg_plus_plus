import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ImageToVideoStepEditor extends ParamsStepEditor {
  final int containerFileCount;
  const ImageToVideoStepEditor({super.key, required super.params, required super.onChanged, super.isZh = true, this.containerFileCount = 0});
  @override
  State<ImageToVideoStepEditor> createState() => _ImageToVideoStepEditorState();
}

class _ImageToVideoStepEditorState extends State<ImageToVideoStepEditor> with StepEditorState<ImageToVideoStepEditor> {
  late TextEditingController _orderCtrl;

  @override
  void initState() {
    super.initState();
    initDefaults(const {'framerate': 30.0, 'order_mode': 'index', 'manual_order': '', 'output_format': 'mp4', 'video_codec': 'h264'});
    _orderCtrl = TextEditingController(text: p['manual_order'] as String? ?? '');
  }

  @override
  void dispose() { _orderCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fps = (p['framerate'] as num?)?.toDouble() ?? 30.0;
    final orderMode = p['order_mode'] as String? ?? 'index';
    final fmt = p['output_format'] as String? ?? 'mp4';
    final codec = p['video_codec'] as String? ?? 'h264';

    return StepEditorScaffold(
      title: zh ? '图片合成视频' : 'Image to Video',
      infoText: zh ? '将容器内图片按编号顺序合成为视频。\n每张图片显示 1/帧率 秒。'
                   : 'Combines images into video by index order.\nEach image shows for 1/fps seconds.',
      children: [
        // 帧率
        Row(children: [
          Text(zh ? '帧率: ${fps.toStringAsFixed(0)} fps' : 'FPS: ${fps.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 12, color: cs.onSurface)),
          const Spacer(),
          TextButton(onPressed: () => update('framerate', 30.0),
              child: Text(zh ? '重置' : 'Reset', style: const TextStyle(fontSize: 11))),
        ]),
        Row(children: [
          Expanded(child: Slider(
            value: fps.clamp(1.0, 60.0), min: 1, max: 60, divisions: 59,
            onChanged: (v) => update('framerate', v.roundToDouble()),
          )),
        ]),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final preset in [1.0, 5.0, 10.0, 24.0, 30.0, 60.0])
            ChoiceChip(
              label: Text('${preset.toInt()} fps', style: const TextStyle(fontSize: 11)),
              selected: (fps - preset).abs() < 0.5,
              onSelected: (_) => update('framerate', preset),
              visualDensity: VisualDensity.compact,
            ),
        ]),

        const SizedBox(height: 8),

        // 顺序
        Text(zh ? '图片顺序' : 'Order', style: TextStyle(fontSize: 12, color: cs.onSurface)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'index', label: Text(zh ? '按编号' : 'By Index', style: const TextStyle(fontSize: 12))),
            ButtonSegment(value: 'manual', label: Text(zh ? '手动' : 'Manual', style: const TextStyle(fontSize: 12))),
          ],
          selected: {orderMode},
          onSelectionChanged: (s) => update('order_mode', s.first),
        ),

        if (orderMode == 'manual') ...[
          const SizedBox(height: 8),
          TextField(
            controller: _orderCtrl,
            decoration: InputDecoration(
              labelText: zh ? '输入编号顺序' : 'Enter index order',
              hintText: zh ? '如: 1,3,2,4' : 'e.g. 1,3,2,4',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (v) => update('manual_order', v),
          ),
        ],

        const SizedBox(height: 8),

        // 输出格式 + 编码器
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(
            borderRadius: BorderRadius.circular(12),
            initialValue: fmt, isExpanded: true,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            dropdownColor: cs.surface,
            decoration: InputDecoration(labelText: zh ? '格式' : 'Format', isDense: true,
                labelStyle: TextStyle(color: cs.onSurface),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            items: ['mp4', 'mkv', 'avi', 'webm'].map((f) => DropdownMenuItem(value: f, child: Text(f.toUpperCase()))).toList(),
            onChanged: (v) { if (v != null) update('output_format', v); },
          )),
          const SizedBox(width: 12),
          Expanded(child: DropdownButtonFormField<String>(
            borderRadius: BorderRadius.circular(12),
            initialValue: codec, isExpanded: true,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            dropdownColor: cs.surface,
            decoration: InputDecoration(labelText: zh ? '编码器' : 'Codec', isDense: true,
                labelStyle: TextStyle(color: cs.onSurface),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            items: ['h264', 'h265', 'vp9'].map((c) => DropdownMenuItem(value: c, child: Text(c.toUpperCase()))).toList(),
            onChanged: (v) { if (v != null) update('video_codec', v); },
          )),
        ]),
      ],
    );
  }
}
