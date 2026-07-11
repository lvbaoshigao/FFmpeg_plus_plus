import 'package:flutter/material.dart';
import '../../models/models.dart';

class LogicBlockEditor extends StatefulWidget {
  final LogicBlock block;
  final List<PipelineNode> childNodes;
  final VoidCallback onChanged;
  final bool isZh;

  const LogicBlockEditor({
    super.key,
    required this.block,
    required this.childNodes,
    required this.onChanged,
    this.isZh = true,
  });

  @override
  State<LogicBlockEditor> createState() => _LogicBlockEditorState();
}

class _LogicBlockEditorState extends State<LogicBlockEditor> {
  Map<String, dynamic> get p => widget.block.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('count', () => 10);
    if (widget.block.type == LogicBlockType.selectiveLoop) {
      p.putIfAbsent('mode', () => 'random');
      p.putIfAbsent('selections', () => <Map<String, dynamic>>[]);
    }
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.repeat, size: 18, color: Colors.red),
          const SizedBox(width: 6),
          Text(
            widget.block.type == LogicBlockType.loop
                ? (zh ? '循环' : 'Loop')
                : (zh ? '选择性循环' : 'Selective Loop'),
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
          widget.block.type == LogicBlockType.loop
              ? (zh ? '对同一输入重复执行框内操作，每次生成一个独立输出' : 'Repeat operations on same input, each iteration produces one output')
              : (zh ? '每次循环可选择执行哪些操作' : 'Choose which operations to run each iteration'),
          style: TextStyle(fontSize: 11, color: cs.outline),
        ),
        const SizedBox(height: 16),

        // 命名
        TextFormField(
          initialValue: widget.block.name,
          decoration: InputDecoration(
            labelText: zh ? '命名（可选）' : 'Name (optional)', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            hintText: zh ? '给这个逻辑块取个名字' : 'Name this logic block',
          ),
          onChanged: (v) {
            widget.block.name = v;
            widget.onChanged();
          },
        ),
        const SizedBox(height: 16),

        // 循环次数
        Row(children: [
          Text(zh ? '循环次数' : 'Loop Count', style: TextStyle(fontSize: 13, color: cs.onSurface)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextFormField(
            initialValue: '${(p['count'] as num?)?.toInt() ?? 10}',
            decoration: InputDecoration(
              labelText: zh ? '次数 (1-10000)' : 'Count (1-10000)', isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            keyboardType: TextInputType.number,
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n >= 1 && n <= 10000) _update('count', n);
            },
          )),
          const SizedBox(width: 8),
          ...[5, 10, 50, 100].map((n) => Padding(
            padding: const EdgeInsets.only(right: 4),
            child: ActionChip(
              label: Text('$n', style: const TextStyle(fontSize: 11)),
              onPressed: () => _update('count', n),
              visualDensity: VisualDensity.compact,
            ),
          )),
        ]),
        const SizedBox(height: 16),

        // 框内节点列表
        Text(zh ? '框内元素' : 'Contained Elements',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 8),
        for (final node in widget.childNodes)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withAlpha(60),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                Icon(Icons.widgets_outlined, size: 14, color: cs.outline),
                const SizedBox(width: 6),
                Text(zh ? node.label : node.labelEn,
                    style: TextStyle(fontSize: 12, color: cs.onSurface)),
              ]),
            ),
          ),

        // 选择性循环特有
        if (widget.block.type == LogicBlockType.selectiveLoop) ...[
          const SizedBox(height: 16),
          Text(zh ? '执行模式' : 'Execution Mode',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: p['mode'] as String? ?? 'random',
            isExpanded: true,
            decoration: InputDecoration(
              labelText: zh ? '模式' : 'Mode', isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            dropdownColor: cs.surface,
            style: TextStyle(fontSize: 13, color: cs.onSurface),
            items: [
              DropdownMenuItem(value: 'random', child: Text(zh ? '随机选择' : 'Random', style: TextStyle(fontSize: 13, color: cs.onSurface))),
              DropdownMenuItem(value: 'all', child: Text(zh ? '全部执行' : 'Execute All', style: TextStyle(fontSize: 13, color: cs.onSurface))),
              DropdownMenuItem(value: 'manual', child: Text(zh ? '手动选择' : 'Manual', style: TextStyle(fontSize: 13, color: cs.onSurface))),
            ],
            onChanged: (v) { if (v != null) _update('mode', v); },
          ),
          if ((p['mode'] as String? ?? 'random') == 'random') ...[
            const SizedBox(height: 8),
            Text(zh ? '每次循环随机选择一个或多个框内操作执行' : 'Randomly picks one or more operations per iteration',
                style: TextStyle(fontSize: 11, color: cs.outline)),
          ],
          if ((p['mode'] as String? ?? 'random') == 'manual') ...[
            const SizedBox(height: 12),
            Text(zh ? '选择每次循环执行的操作' : 'Select operations for each iteration',
                style: TextStyle(fontSize: 12, color: cs.onSurface)),
            const SizedBox(height: 8),
            for (final node in widget.childNodes)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(zh ? node.label : node.labelEn,
                    style: TextStyle(fontSize: 12, color: cs.onSurface)),
                value: _isNodeSelected(node.id),
                onChanged: (v) => _toggleNodeSelection(node.id, v ?? false),
              ),
          ],
        ],

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.red.withAlpha(20),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withAlpha(40)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14, color: Colors.red.shade300),
            const SizedBox(width: 8),
            Expanded(child: Text(
              zh ? '循环 ${p['count'] ?? 10} 次将生成 ${p['count'] ?? 10} 个输出文件。'
                 : 'Loop ${p['count'] ?? 10} times will generate ${p['count'] ?? 10} output files.',
              style: TextStyle(fontSize: 11, color: Colors.red.shade300, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }

  bool _isNodeSelected(String nodeId) {
    final selections = (p['selections'] as List?) ?? [];
    return selections.any((s) => s is Map && s['nodeId'] == nodeId);
  }

  void _toggleNodeSelection(String nodeId, bool selected) {
    setState(() {
      final selections = List<Map<String, dynamic>>.from((p['selections'] as List?) ?? []);
      if (selected) {
        if (!selections.any((s) => s['nodeId'] == nodeId)) {
          selections.add({'nodeId': nodeId});
        }
      } else {
        selections.removeWhere((s) => s['nodeId'] == nodeId);
      }
      p['selections'] = selections;
    });
    widget.onChanged();
  }
}
