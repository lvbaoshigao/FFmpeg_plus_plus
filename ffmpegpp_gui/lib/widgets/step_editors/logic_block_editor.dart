import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_control_size.dart';
import '../../theme/app_semantic_colors.dart';
import 'editor_kit.dart';

/// 逻辑块属性编辑器。
///
/// 覆盖四种类型的**全部**参数：
/// * 循环 / 选择性循环 —— 次数模式（固定 / 区间）、执行模式、手动勾选、
///   链式累积、失败策略与重试、迭代变量说明；
/// * 条件 —— 判断字段 / 比较方式 / 目标值 / 不满足时的行为；
/// * 分组 —— 仅组织用，无可调参数。
///
/// 参数的实际语义在别处落地（本文件只负责读写 `block.params`）：
/// * 打标：[GraphExecutor] 的 `_buildPlanForOutput`
/// * 展平：`AppState._expandLoopCalls`
/// * 判定：`GraphExecutor._evalCondition`（条件块）
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
  LogicBlock get b => widget.block;
  bool get zh => widget.isZh;

  static const _size = AppControlSize.regular;

  @override
  void initState() {
    super.initState();
    // 默认值按「用到才补」写入 —— 老工程里已存在的逻辑块只会带上 count，
    // 这里补的全是新参数，不会覆盖用户已经改过的值。
    p.putIfAbsent('countMode', () => 'fixed');
    p.putIfAbsent('count', () => 10);
    p.putIfAbsent('from', () => 1);
    p.putIfAbsent('to', () => 10);
    p.putIfAbsent('step', () => 1);
    p.putIfAbsent('accumulate', () => false);
    p.putIfAbsent('onError', () => 'stop');
    p.putIfAbsent('retries', () => 0);
    p.putIfAbsent('condField', () => LogicConditionField.extension.name);
    p.putIfAbsent('condOp', () => LogicConditionOp.eq.name);
    p.putIfAbsent('condValue', () => '');
    p.putIfAbsent('condElse', () => 'skip');
    if (b.type == LogicBlockType.selectiveLoop) {
      p.putIfAbsent('mode', () => 'random');
      p.putIfAbsent('selections', () => <Map<String, dynamic>>[]);
    }
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  // ---------- 通用小部件 ----------

  Widget _label(String text) => Text(
        text,
        style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface),
      );

  EdgeInsets get _fieldPad => _size.fieldPadding;

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: _fieldPad,
        visualDensity: AppControlSize.fieldDensity,
        suffixIconConstraints: AppControlSize.iconSlot,
      );

  /// 数字输入：越界值被钳到 [min]..[max]（负数 / 超大值直接落回边界，
  /// 而不是静默丢弃 —— 用户输错时能立刻看到被修正到的值）。
  Widget _numField({
    required String label,
    required String paramKey,
    required int fallback,
    required int min,
    required int max,
  }) {
    return TextFormField(
      initialValue: '${(p[paramKey] as num?)?.toInt() ?? fallback}',
      keyboardType: TextInputType.number,
      decoration: _dec(label),
      onChanged: (v) {
        final n = int.tryParse(v);
        if (n == null) return;
        _update(paramKey, n.clamp(min, max));
      },
    );
  }

  Widget _chipRow(List<int> values, String paramKey) => Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final n in values)
            ActionChip(
              label: Text('$n', style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              onPressed: () => _update(paramKey, n),
            ),
        ],
      );

  Widget _switchRow(String title, String subtitle, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline, height: 1.35)),
        value: value,
        onChanged: onChanged,
      );

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Divider(
            height: 1, color: Theme.of(context).colorScheme.outlineVariant.withAlpha(80)),
      );

  // ---------- 主体 ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRepeat = b.type == LogicBlockType.loop || b.type == LogicBlockType.selectiveLoop;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _header(cs),
        const SizedBox(height: 10),
        TextFormField(
          initialValue: b.name,
          decoration: _dec(zh ? '命名（可选）' : 'Name (optional)',
              hint: zh ? '给这个逻辑块取个名字' : 'Name this logic block'),
          onChanged: (v) {
            b.name = v;
            widget.onChanged();
          },
        ),

        if (isRepeat) ...[
          _divider(),
          ..._repeatBody(cs),
        ],
        if (b.type == LogicBlockType.selectiveLoop) ...[
          _divider(),
          ..._selectiveBody(cs),
        ],
        if (b.type == LogicBlockType.condition) ...[
          _divider(),
          ..._conditionBody(cs),
        ],
        if (b.type == LogicBlockType.group) ...[
          _divider(),
          EditorInfoBox(
            zh
                ? '分组不参与执行，只把画布上相关的节点归拢在一起：可以整体拖动、'
                    '一键删除，让大图更容易读。框内节点照常按连线执行一次。'
                : 'A group never repeats anything — it only bundles related nodes on the '
                    'canvas so they can be dragged or deleted together.',
          ),
        ],

        _divider(),
        _childList(cs),
        const SizedBox(height: 10),
        _footerBox(cs),
      ]),
    );
  }

  Widget _header(ColorScheme cs) {
    final (IconData icon, String title, String desc) = switch (b.type) {
      LogicBlockType.loop => (
          Icons.repeat,
          zh ? '循环' : 'Loop',
          zh
              ? '对同一输入重复执行框内操作，每次生成一个独立输出'
              : 'Repeat the enclosed operations — one output per iteration',
        ),
      LogicBlockType.selectiveLoop => (
          Icons.shuffle,
          zh ? '选择性循环' : 'Selective Loop',
          zh ? '每次循环可选择执行哪些操作' : 'Choose which operations run each iteration',
        ),
      LogicBlockType.group => (
          Icons.folder_special_outlined,
          zh ? '分组' : 'Group',
          zh
              ? '把相关节点归拢成一个可整体拖动的框，不重复执行'
              : 'Bundle related nodes into a movable frame — no repetition',
        ),
      LogicBlockType.condition => (
          Icons.rule,
          zh ? '条件' : 'Condition',
          zh
              ? '按输入文件的属性决定是否执行框内操作'
              : 'Run the enclosed operations only when the input matches a rule',
        ),
    };
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: cs.sem.danger),
      const SizedBox(width: 6),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 2),
          Text(desc, style: TextStyle(fontSize: 11, color: cs.outline, height: 1.35)),
        ]),
      ),
    ]);
  }

  // ---------- 循环 / 选择性循环：次数 ----------

  List<Widget> _repeatBody(ColorScheme cs) {
    final rangeMode = p['countMode'] == 'range';
    return [
      _label(zh ? '次数模式' : 'Count mode'),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        ChoiceChip(
          label: Text(zh ? '固定次数' : 'Fixed'),
          labelStyle: const TextStyle(fontSize: 12),
          selected: !rangeMode,
          visualDensity: VisualDensity.compact,
          onSelected: (_) => _update('countMode', 'fixed'),
        ),
        ChoiceChip(
          label: Text(zh ? '区间' : 'Range'),
          labelStyle: const TextStyle(fontSize: 12),
          selected: rangeMode,
          visualDensity: VisualDensity.compact,
          onSelected: (_) => _update('countMode', 'range'),
        ),
      ]),
      const SizedBox(height: 8),

      if (!rangeMode) ...[
        Row(children: [
          Expanded(
            child: _numField(
              label: zh ? '次数 (1-10000)' : 'Count (1-10000)',
              paramKey: 'count',
              fallback: 10,
              min: 1,
              max: 10000,
            ),
          ),
          const SizedBox(width: 8),
          _chipRow(const [5, 10, 50, 100], 'count'),
        ]),
      ] else ...[
        Row(children: [
          Expanded(
            child: _numField(
                label: zh ? '起始' : 'From', paramKey: 'from', fallback: 1, min: 0, max: 10000),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _numField(
                label: zh ? '结束' : 'To', paramKey: 'to', fallback: 10, min: 0, max: 10000),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _numField(
                label: zh ? '步长' : 'Step', paramKey: 'step', fallback: 1, min: 1, max: 1000),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          zh
              ? '迭代序号依次为 ${b.iterationNumber(0)}、${b.iterationNumber(1)}、${b.iterationNumber(2)}…'
                  '（共 ${b.effectiveCount} 轮，可用 {i} 取用）'
              : 'Iteration numbers: ${b.iterationNumber(0)}, ${b.iterationNumber(1)}, '
                  '${b.iterationNumber(2)}… (${b.effectiveCount} rounds, use {i})',
          style: TextStyle(fontSize: 11, color: cs.outline, height: 1.35),
        ),
      ],

      _divider(),

      // 迭代变量说明 —— 「输出到不同文件」是靠它实现的，必须让用户看到
      _label(zh ? '迭代变量' : 'Iteration variables'),
      const SizedBox(height: 6),
      EditorInfoBox(
        zh
            ? '{i} 当前轮序号 · {i0} 当前轮次(从0) · {n} 总轮数 · {i:03} 补零\n'
                '在第 5 步的参数里写 frame_{i:03}.jpg，就会得到 frame_001.jpg、frame_002.jpg…\n'
                '注意：一旦用了 {i}，输出名完全由你决定，程序不再自动追加 _loop_N 后缀。'
            : '{i} current number · {i0} zero-based round · {n} total · {i:03} padded\n'
                'Use frame_{i:03}.jpg to get frame_001.jpg, frame_002.jpg…\n'
                'Once {i} is used the output name is entirely yours — no _loop_N suffix is added.',
      ),

      _divider(),

      _switchRow(
        zh ? '链式累积' : 'Chained accumulation',
        zh
            ? '每一轮的输入用上一轮的输出（默认每轮都从原始输入开始）'
            : 'Feed each round with the previous round output (default: always the original input)',
        b.accumulate,
        (v) => _update('accumulate', v),
      ),

      _divider(),

      _label(zh ? '失败处理' : 'On failure'),
      const SizedBox(height: 6),
      EditorDropdown(
        label: zh ? '某一轮失败时' : 'When a round fails',
        value: b.errorPolicy,
        items: [
          ('stop', zh ? '中止整个任务' : 'Abort the task'),
          ('continue', zh ? '跳过该轮，继续后续步骤' : 'Skip and continue'),
        ],
        onChanged: (v) => _update('onError', v),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: _numField(
            label: zh ? '失败重试次数 (0-10)' : 'Retries (0-10)',
            paramKey: 'retries',
            fallback: 0,
            min: 0,
            max: 10,
          ),
        ),
        const SizedBox(width: 8),
        _chipRow(const [0, 1, 2, 3], 'retries'),
      ]),
    ];
  }

  // ---------- 选择性循环 ----------

  List<Widget> _selectiveBody(ColorScheme cs) {
    final mode = (p['mode'] as String? ?? 'random');
    return [
      _label(zh ? '执行模式' : 'Execution mode'),
      const SizedBox(height: 6),
      EditorDropdown(
        label: zh ? '模式' : 'Mode',
        value: mode,
        items: [
          ('random', zh ? '随机选择' : 'Random'),
          ('all', zh ? '全部执行' : 'Execute all'),
          ('manual', zh ? '手动选择' : 'Manual'),
        ],
        onChanged: (v) => _update('mode', v),
      ),
      const SizedBox(height: 6),
      Text(
        switch (mode) {
          'random' => zh ? '每次循环随机选择一个或多个框内操作执行' : 'Randomly picks operations per iteration',
          'all' => zh ? '每轮都执行全部框内操作' : 'Every iteration runs all enclosed operations',
          _ => zh ? '只执行下面勾选的操作' : 'Only the checked operations run',
        },
        style: TextStyle(fontSize: 11, color: cs.outline, height: 1.35),
      ),
      if (mode == 'manual') ...[
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
    ];
  }

  // ---------- 条件 ----------

  List<Widget> _conditionBody(ColorScheme cs) {
    final field = b.conditionField;
    final numeric = field == LogicConditionField.fileSize;
    // 字段类型与比较方式不匹配的组​​合（如「扩展名 大于」）在执行层恒为 false，
    // 这里直接给出可读的检查项，省得用户对着「条件总是不成立」猜。
    final opIsNumeric = b.conditionOp == LogicConditionOp.gt ||
        b.conditionOp == LogicConditionOp.lt ||
        b.conditionOp == LogicConditionOp.ge ||
        b.conditionOp == LogicConditionOp.le;

    return [
      _label(zh ? '判断条件' : 'Rule'),
      const SizedBox(height: 6),
      EditorDropdown(
        label: zh ? '字段' : 'Field',
        value: field.name,
        items: [
          for (final f in LogicConditionField.values) (f.name, logicConditionFieldLabel(f, zh)),
        ],
        onChanged: (v) => _update('condField', v),
      ),
      const SizedBox(height: 8),
      EditorDropdown(
        label: zh ? '比较' : 'Compare',
        value: b.conditionOp.name,
        items: [
          for (final o in LogicConditionOp.values) (o.name, logicConditionOpLabel(o, zh)),
        ],
        onChanged: (v) => _update('condOp', v),
      ),
      const SizedBox(height: 8),
      TextFormField(
        initialValue: b.conditionValue,
        decoration: _dec(
          zh ? '目标值' : 'Value',
          hint: switch (field) {
            LogicConditionField.extension => 'mp4',
            LogicConditionField.filename => zh ? '包含的文本' : 'substring',
            LogicConditionField.fileSize => '10485760',
            LogicConditionField.inputPath => zh ? '路径片段' : '/path/part',
            LogicConditionField.parentDir => zh ? '目录名' : 'folder',
          },
        ),
        onChanged: (v) => _update('condValue', v),
      ),
      // 字段与比较方式不匹配时提前告知（执行层此时恒为 false，不会有任何提示）
      if (opIsNumeric && !numeric) ...[
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: cs.sem.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              zh
                  ? '大小比较只对「文件大小」有意义，当前字段是文本，条件永远不成立'
                  : 'Numeric comparison only makes sense for file size — this rule will never match',
              style: TextStyle(fontSize: 11, color: cs.sem.warning, height: 1.35),
            ),
          ),
        ]),
      ],
      const SizedBox(height: 8),
      EditorDropdown(
        label: zh ? '不满足时' : 'When false',
        value: (p['condElse'] as String?) ?? 'skip',
        items: [
          ('skip', zh ? '跳过框内操作，继续后续步骤' : 'Skip enclosed steps'),
          ('stop', zh ? '中止整个任务（不产出）' : 'Abort the task (no output)'),
        ],
        onChanged: (v) => _update('condElse', v),
      ),
      const SizedBox(height: 8),
      EditorInfoBox(
        zh
            ? '判定用的是进入框内节点前的文件：扩展名 / 文件名 / 大小 / 路径，'
                '无需解码媒体，判定在入队时完成、不额外耗时。\n'
                '字符串比较忽略大小写；「以…开头 / 结尾 / 包含」留空时视为通过。'
            : 'The rule reads the file entering this block (extension / name / size / path) — '
                'no media decoding, evaluated when queuing.\nCase-insensitive; empty '
                '"contains/starts/ends" passes.',
      ),
    ];
  }

  // ---------- 框内元素 ----------

  Widget _childList(ColorScheme cs) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('${zh ? '框内元素' : 'Contained elements'} (${widget.childNodes.length})'),
      const SizedBox(height: 6),
      if (widget.childNodes.isEmpty)
        Text(zh ? '（空）在画布上把节点拖进这个框' : '(empty) drag nodes into this frame',
            style: TextStyle(fontSize: 11, color: cs.outline))
      else ...[
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
                Expanded(
                  child: Text(zh ? node.label : node.labelEn,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: cs.onSurface)),
                ),
              ]),
            ),
          ),
      ],
    ]);
  }

  Widget _footerBox(ColorScheme cs) {
    final count = b.effectiveCount;
    final text = switch (b.type) {
      LogicBlockType.loop => zh
          ? '循环 $count 次将生成 $count 个输出文件（中间产物会在任务结束时清理）'
          : 'Looping $count times produces $count output files (intermediates are cleaned up)',
      LogicBlockType.selectiveLoop => zh
          ? '共 $count 轮，每轮按「${(p['mode'] as String? ?? 'random')}」模式决定执行哪些操作'
          : '$count rounds, each picking operations per the selected mode',
      LogicBlockType.condition => zh
          ? '条件成立时执行框内 ${widget.childNodes.length} 个操作，否则${b.conditionSkipWhenFalse ? '跳过' : '中止任务'}'
          : 'Runs ${widget.childNodes.length} operation(s) when the rule matches',
      LogicBlockType.group => zh
          ? '分组框内的 ${widget.childNodes.length} 个节点按连线各执行一次'
          : 'The ${widget.childNodes.length} enclosed node(s) each run once',
    };
    return EditorInfoBox(
      text,
      color: cs.sem.onDangerContainer,
      background: cs.sem.dangerContainer.withAlpha(120),
      borderColor: cs.sem.danger.withAlpha(60),
    );
  }

  // ---------- 勾选 ----------

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
