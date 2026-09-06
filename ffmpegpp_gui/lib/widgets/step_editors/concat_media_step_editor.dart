import 'package:flutter/material.dart';
import 'editor_kit.dart';

class ConcatMediaStepEditor extends ParamsStepEditor {
  final int containerFileCount;
  const ConcatMediaStepEditor({super.key, required super.params, required super.onChanged, super.isZh = true, this.containerFileCount = 0});
  @override
  State<ConcatMediaStepEditor> createState() => _ConcatMediaStepEditorState();
}

class _ConcatMediaStepEditorState extends State<ConcatMediaStepEditor> with StepEditorState<ConcatMediaStepEditor> {
  late TextEditingController _orderCtrl;

  @override
  void initState() {
    super.initState();
    initDefaults(const {'mode': 'copy', 'order_mode': 'index', 'manual_order': ''});
    _orderCtrl = TextEditingController(text: p['manual_order'] as String? ?? '');
  }

  @override
  void dispose() { _orderCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mode = p['mode'] as String? ?? 'copy';
    final orderMode = p['order_mode'] as String? ?? 'index';

    return StepEditorScaffold(
      title: zh ? '合并媒体' : 'Concat Media',
      infoText: zh ? '将容器内的所有文件按指定顺序合并为一个文件。\n流复制模式不重新编码，速度极快。\n重新编码模式可处理格式不同的文件。'
                   : 'Merges all files in container into one.\nStream copy is fastest but requires same codec.\nRe-encode handles different formats.',
      children: [
        // 模式
        Text(zh ? '合并模式' : 'Mode', style: TextStyle(fontSize: 12, color: cs.onSurface)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'copy', label: Text(zh ? '流复制' : 'Stream Copy', style: const TextStyle(fontSize: 12))),
            ButtonSegment(value: 'reencode', label: Text(zh ? '重新编码' : 'Re-encode', style: const TextStyle(fontSize: 12))),
          ],
          selected: {mode},
          onSelectionChanged: (s) => update('mode', s.first),
        ),
        const SizedBox(height: 4),
        Text(zh ? '流复制速度快但要求所有文件格式一致' : 'Stream copy is fast but requires same format',
            style: TextStyle(fontSize: 10, color: cs.outline)),

        const SizedBox(height: 8),

        // 顺序
        Text(zh ? '合并顺序' : 'Order', style: TextStyle(fontSize: 12, color: cs.onSurface)),
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
          const SizedBox(height: 4),
          Builder(builder: (_) {
            final err = _validateOrder();
            if (err != null) return Text(err, style: TextStyle(fontSize: 10, color: cs.error));
            return Text(zh ? '编号有效' : 'Valid order', style: TextStyle(fontSize: 10, color: Colors.green));
          }),
        ],
      ],
    );
  }

  String? _validateOrder() {
    final order = p['manual_order'] as String? ?? '';
    if (order.trim().isEmpty) return widget.isZh ? '请输入编号' : 'Enter indices';
    final parts = order.split(',').map((s) => int.tryParse(s.trim())).toList();
    if (parts.any((p) => p == null)) return widget.isZh ? '包含无效数字' : 'Contains invalid numbers';
    final max = widget.containerFileCount;
    if (max > 0 && parts.any((p) => p! < 1 || p > max)) {
      return widget.isZh ? '编号超出范围 (1-$max)' : 'Index out of range (1-$max)';
    }
    // 重复编号会被后端静默去重，遗漏编号则文件被丢弃——给出明确提示
    final seen = <int>{};
    for (final p in parts) {
      if (p == null) continue;
      if (!seen.add(p)) return widget.isZh ? '编号重复: $p' : 'Duplicate index: $p';
    }
    if (max > 0 && parts.length != max) {
      return widget.isZh ? '共 $max 个文件，只指定了 ${parts.length} 个' : '$max files total, only ${parts.length} specified';
    }
    return null;
  }
}
