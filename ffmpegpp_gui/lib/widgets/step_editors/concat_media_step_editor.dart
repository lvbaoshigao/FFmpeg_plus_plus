import 'package:flutter/material.dart';

class ConcatMediaStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;
  final int containerFileCount;
  const ConcatMediaStepEditor({super.key, required this.params, required this.onChanged, this.isZh = true, this.containerFileCount = 0});
  @override
  State<ConcatMediaStepEditor> createState() => _ConcatMediaStepEditorState();
}

class _ConcatMediaStepEditorState extends State<ConcatMediaStepEditor> {
  Map<String, dynamic> get p => widget.params;
  late TextEditingController _orderCtrl;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('mode', () => 'copy');
    p.putIfAbsent('order_mode', () => 'index');
    p.putIfAbsent('manual_order', () => '');
    _orderCtrl = TextEditingController(text: p['manual_order'] as String? ?? '');
  }

  @override
  void dispose() { _orderCtrl.dispose(); super.dispose(); }

  void _update(String key, dynamic value) { setState(() => p[key] = value); widget.onChanged(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mode = p['mode'] as String? ?? 'copy';
    final orderMode = p['order_mode'] as String? ?? 'index';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '合并媒体' : 'Concat Media',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        // 模式
        Text(zh ? '合并模式' : 'Mode', style: TextStyle(fontSize: 12, color: cs.onSurface)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'copy', label: Text(zh ? '流复制' : 'Stream Copy', style: const TextStyle(fontSize: 12))),
            ButtonSegment(value: 'reencode', label: Text(zh ? '重新编码' : 'Re-encode', style: const TextStyle(fontSize: 12))),
          ],
          selected: {mode},
          onSelectionChanged: (s) => _update('mode', s.first),
        ),
        const SizedBox(height: 4),
        Text(zh ? '流复制速度快但要求所有文件格式一致' : 'Stream copy is fast but requires same format',
            style: TextStyle(fontSize: 10, color: cs.outline)),

        const SizedBox(height: 16),

        // 顺序
        Text(zh ? '合并顺序' : 'Order', style: TextStyle(fontSize: 12, color: cs.onSurface)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'index', label: Text(zh ? '按编号' : 'By Index', style: const TextStyle(fontSize: 12))),
            ButtonSegment(value: 'manual', label: Text(zh ? '手动' : 'Manual', style: const TextStyle(fontSize: 12))),
          ],
          selected: {orderMode},
          onSelectionChanged: (s) => _update('order_mode', s.first),
        ),

        if (orderMode == 'manual') ...[
          const SizedBox(height: 12),
          TextField(
            controller: _orderCtrl,
            decoration: InputDecoration(
              labelText: zh ? '输入编号顺序' : 'Enter index order',
              hintText: zh ? '如: 1,3,2,4' : 'e.g. 1,3,2,4',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (v) => _update('manual_order', v),
          ),
          const SizedBox(height: 4),
          Builder(builder: (_) {
            final err = _validateOrder();
            if (err != null) return Text(err, style: TextStyle(fontSize: 10, color: cs.error));
            return Text(zh ? '编号有效' : 'Valid order', style: TextStyle(fontSize: 10, color: Colors.green));
          }),
        ],

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: cs.surfaceContainerHighest.withAlpha(60), borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14, color: cs.outline),
            const SizedBox(width: 8),
            Expanded(child: Text(
              zh ? '将容器内的所有文件按指定顺序合并为一个文件。\n流复制模式不重新编码，速度极快。\n重新编码模式可处理格式不同的文件。'
                 : 'Merges all files in container into one.\nStream copy is fastest but requires same codec.\nRe-encode handles different formats.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
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
    return null;
  }
}
