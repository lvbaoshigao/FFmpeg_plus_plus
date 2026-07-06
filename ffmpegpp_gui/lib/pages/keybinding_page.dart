import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

Future<void> showKeybindingDialog(BuildContext context, {required bool isZh}) {
  return showDialog(
    context: context,
    builder: (_) => _KeybindingDialog(isZh: isZh),
  );
}

const _basicActionIds = [
  'project_select_all',
  'queue_add_all',
  'queue_start_all',
  'project_clear_all',
  'queue_stop_all',
];

const _canvasActionIds = [
  'canvas_select_all',
  'canvas_delete_selected',
];

String _normalizeBinding(List<String> keys) {
  final sorted = List<String>.from(keys)..sort();
  return sorted.join('+').toLowerCase();
}

Set<String> _findConflictsInGroup(List<String> group, Map<String, List<String>> bindings) {
  final seen = <String, String>{};
  final conflicts = <String>{};
  for (final id in group) {
    final keys = bindings[id];
    if (keys == null || keys.isEmpty) continue;
    final norm = _normalizeBinding(keys);
    if (seen.containsKey(norm)) {
      conflicts.add(id);
      conflicts.add(seen[norm]!);
    } else {
      seen[norm] = id;
    }
  }
  return conflicts;
}

Set<String> _findAllConflicts(Map<String, List<String>> bindings) {
  return {
    ..._findConflictsInGroup(_basicActionIds, bindings),
    ..._findConflictsInGroup(_canvasActionIds, bindings),
  };
}

List<String> _groupOf(String actionId) {
  if (_basicActionIds.contains(actionId)) return _basicActionIds;
  if (_canvasActionIds.contains(actionId)) return _canvasActionIds;
  return [];
}

class _KeybindingDialog extends StatefulWidget {
  final bool isZh;
  const _KeybindingDialog({required this.isZh});

  @override
  State<_KeybindingDialog> createState() => _KeybindingDialogState();
}

class _KeybindingDialogState extends State<_KeybindingDialog> {
  bool get isZh => widget.isZh;

  String _formatBinding(List<String> keys) => keys.isEmpty ? (isZh ? '(未设置)' : '(none)') : keys.join(' + ');

  Future<void> _editBinding(String actionId, String actionLabel) async {
    final state = context.read<AppState>();
    final config = state.config;
    final current = config.keyBindings[actionId] ?? [];

    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _KeyCaptureDialog(
        isZh: isZh,
        currentKeys: current,
        actionLabel: actionLabel,
        actionId: actionId,
        allBindings: config.keyBindings,
        conflictGroup: _groupOf(actionId),
      ),
    );

    if (result != null) {
      state.updateConfig((c) => c..keyBindings[actionId] = result);
      setState(() {});
    }
  }

  void _clearBinding(String actionId) {
    context.read<AppState>().updateConfig((c) => c..keyBindings[actionId] = []);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.config;
    final scheme = Theme.of(context).colorScheme;
    final clr = scheme.onSurface;

    final panButton = config.keyBindings['canvas_pan_button'] ?? ['right'];
    final selectButton = config.keyBindings['canvas_select_button'] ?? ['left'];

    final conflicts = _findAllConflicts(config.keyBindings);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        Icon(Icons.keyboard, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Text(isZh ? '快捷键配置' : 'Keyboard Shortcuts',
            style: TextStyle(fontSize: 16, color: scheme.onSurface)),
      ]),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (conflicts.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      isZh ? '存在快捷键冲突，请修改重复的快捷键' : 'Shortcut conflicts detected, please fix duplicates',
                      style: TextStyle(fontSize: 12, color: scheme.error, fontWeight: FontWeight.w600),
                    )),
                  ]),
                ),
              ],

              _sectionHeader(Icons.keyboard, isZh ? '基本' : 'Basic', scheme),
              const SizedBox(height: 4),
              _shortcutTile(actionId: 'project_select_all', label: isZh ? '全选视频' : 'Select All Videos',
                  keys: config.keyBindings['project_select_all'] ?? [], scheme: scheme, clr: clr, conflicts: conflicts),
              _shortcutTile(actionId: 'queue_add_all', label: isZh ? '快速添加所有到队列' : 'Add All to Queue',
                  keys: config.keyBindings['queue_add_all'] ?? [], scheme: scheme, clr: clr, conflicts: conflicts),
              _shortcutTile(actionId: 'queue_start_all', label: isZh ? '快速开始所有任务' : 'Start All Tasks',
                  keys: config.keyBindings['queue_start_all'] ?? [], scheme: scheme, clr: clr, conflicts: conflicts),
              _shortcutTile(actionId: 'project_clear_all', label: isZh ? '删除所有项目' : 'Delete All Projects',
                  keys: config.keyBindings['project_clear_all'] ?? [], scheme: scheme, clr: clr, conflicts: conflicts),
              _shortcutTile(actionId: 'queue_stop_all', label: isZh ? '停止所有任务' : 'Stop All Tasks',
                  keys: config.keyBindings['queue_stop_all'] ?? [], scheme: scheme, clr: clr, conflicts: conflicts),
              const SizedBox(height: 16),

              _sectionHeader(Icons.gesture, isZh ? '画布' : 'Canvas', scheme),
              const SizedBox(height: 4),

              ListTile(
                dense: true,
                title: Text(isZh ? '拖动画布按键' : 'Pan Canvas Button', style: TextStyle(color: clr, fontSize: 13)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SegmentedButton<String>(
                    segments: [
                      ButtonSegment(value: 'left', label: Text(isZh ? '左键' : 'Left')),
                      ButtonSegment(value: 'right', label: Text(isZh ? '右键' : 'Right')),
                    ],
                    selected: {panButton.first},
                    onSelectionChanged: (v) {
                      final newPan = v.first;
                      final newSelect = newPan == 'left' ? 'right' : 'left';
                      state.updateConfig((c) => c
                        ..keyBindings['canvas_pan_button'] = [newPan]
                        ..keyBindings['canvas_select_button'] = [newSelect]);
                      setState(() {});
                    },
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  ),
                ),
              ),

              ListTile(
                dense: true,
                title: Text(isZh ? '框选按键' : 'Box Select Button', style: TextStyle(color: clr, fontSize: 13)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SegmentedButton<String>(
                    segments: [
                      ButtonSegment(value: 'left', label: Text(isZh ? '左键' : 'Left')),
                      ButtonSegment(value: 'right', label: Text(isZh ? '右键' : 'Right')),
                    ],
                    selected: {selectButton.first},
                    onSelectionChanged: (v) {
                      final newSelect = v.first;
                      final newPan = newSelect == 'left' ? 'right' : 'left';
                      state.updateConfig((c) => c
                        ..keyBindings['canvas_select_button'] = [newSelect]
                        ..keyBindings['canvas_pan_button'] = [newPan]);
                      setState(() {});
                    },
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  ),
                ),
              ),

              _shortcutTile(actionId: 'canvas_select_all', label: isZh ? '选中所有元素' : 'Select All Elements',
                  keys: config.keyBindings['canvas_select_all'] ?? [], scheme: scheme, clr: clr, conflicts: conflicts),
              _shortcutTile(actionId: 'canvas_delete_selected', label: isZh ? '删除选中元素' : 'Delete Selected Elements',
                  keys: config.keyBindings['canvas_delete_selected'] ?? [], scheme: scheme, clr: clr, conflicts: conflicts),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isZh ? '关闭' : 'Close'),
        ),
      ],
    );
  }

  Widget _sectionHeader(IconData icon, String title, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
      ]),
    );
  }

  Widget _shortcutTile({
    required String actionId,
    required String label,
    required List<String> keys,
    required ColorScheme scheme,
    required Color clr,
    required Set<String> conflicts,
  }) {
    final hasConflict = conflicts.contains(actionId);
    return ListTile(
      title: Text(label, style: TextStyle(
        color: hasConflict ? scheme.error : clr,
        fontSize: 13,
        fontWeight: hasConflict ? FontWeight.w600 : null,
      )),
      subtitle: Text(
        hasConflict
            ? '${_formatBinding(keys)}  ${isZh ? "(冲突!)" : "(conflict!)"}'
            : _formatBinding(keys),
        style: TextStyle(fontSize: 12, color: hasConflict ? scheme.error : scheme.outline),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (keys.isNotEmpty)
          IconButton(
            icon: Icon(Icons.close, size: 14, color: scheme.outline),
            tooltip: isZh ? '清空' : 'Clear',
            onPressed: () => _clearBinding(actionId),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
          ),
        IconButton(
          icon: Icon(Icons.edit, size: 14, color: hasConflict ? scheme.error : scheme.outline),
          tooltip: isZh ? '编辑' : 'Edit',
          onPressed: () => _editBinding(actionId, label),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: EdgeInsets.zero,
        ),
      ]),
      onTap: () => _editBinding(actionId, label),
    );
  }
}

// ═══════════════════════════════════════════
// Key capture dialog
// ═══════════════════════════════════════════

const _actionLabelsZh = {
  'project_select_all': '全选视频',
  'queue_add_all': '快速添加所有到队列',
  'queue_start_all': '快速开始所有任务',
  'project_clear_all': '删除所有项目',
  'queue_stop_all': '停止所有任务',
  'canvas_select_all': '选中所有元素',
  'canvas_delete_selected': '删除选中元素',
};
const _actionLabelsEn = {
  'project_select_all': 'Select All Videos',
  'queue_add_all': 'Add All to Queue',
  'queue_start_all': 'Start All Tasks',
  'project_clear_all': 'Delete All Projects',
  'queue_stop_all': 'Stop All Tasks',
  'canvas_select_all': 'Select All Elements',
  'canvas_delete_selected': 'Delete Selected Elements',
};

class _KeyCaptureDialog extends StatefulWidget {
  final bool isZh;
  final List<String> currentKeys;
  final String actionLabel;
  final String actionId;
  final Map<String, List<String>> allBindings;
  final List<String> conflictGroup;
  const _KeyCaptureDialog({
    required this.isZh,
    required this.currentKeys,
    required this.actionLabel,
    required this.actionId,
    required this.allBindings,
    required this.conflictGroup,
  });

  @override
  State<_KeyCaptureDialog> createState() => _KeyCaptureDialogState();
}

class _KeyCaptureDialogState extends State<_KeyCaptureDialog> {
  final Set<LogicalKeyboardKey> _heldKeys = {};
  List<String> _capturedLabels = [];
  bool _tooMany = false;
  String? _conflictWith;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _capturedLabels = List.from(widget.currentKeys);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  String _keyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.controlLeft || key == LogicalKeyboardKey.controlRight) return 'Control';
    if (key == LogicalKeyboardKey.shiftLeft || key == LogicalKeyboardKey.shiftRight) return 'Shift';
    if (key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight) return 'Alt';
    if (key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight) return 'Meta';
    return key.keyLabel.isNotEmpty ? key.keyLabel : key.debugName ?? '?';
  }

  void _checkConflict() {
    if (_capturedLabels.isEmpty) {
      _conflictWith = null;
      return;
    }
    final norm = _normalizeBinding(_capturedLabels);
    for (final id in widget.conflictGroup) {
      if (id == widget.actionId) continue;
      final other = widget.allBindings[id];
      if (other == null || other.isEmpty) continue;
      if (_normalizeBinding(other) == norm) {
        final labels = widget.isZh ? _actionLabelsZh : _actionLabelsEn;
        _conflictWith = labels[id] ?? id;
        return;
      }
    }
    _conflictWith = null;
  }

  void _onKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (_heldKeys.length >= 5) {
        setState(() => _tooMany = true);
        return;
      }
      setState(() {
        _tooMany = false;
        _heldKeys.add(event.logicalKey);
        final seen = <String>{};
        _capturedLabels = [];
        for (final k in _heldKeys) {
          final label = _keyLabel(k);
          if (seen.add(label)) _capturedLabels.add(label);
        }
        _checkConflict();
      });
    } else if (event is KeyUpEvent) {
      _heldKeys.remove(event.logicalKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasConflict = _conflictWith != null;

    return AlertDialog(
      title: Text(widget.isZh ? '按下快捷键...' : 'Press shortcut...', style: TextStyle(fontSize: 16, color: scheme.onSurface)),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.actionLabel, style: TextStyle(fontSize: 13, color: scheme.outline)),
            const SizedBox(height: 16),
            KeyboardListener(
              focusNode: _focusNode,
              autofocus: true,
              onKeyEvent: _onKey,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: hasConflict ? scheme.error : scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                  color: hasConflict
                      ? scheme.errorContainer.withAlpha(60)
                      : scheme.surfaceContainerHighest.withAlpha(60),
                ),
                child: _capturedLabels.isEmpty
                    ? Text(
                        widget.isZh ? '等待按键输入...' : 'Waiting for key input...',
                        style: TextStyle(color: scheme.outline, fontSize: 13),
                        textAlign: TextAlign.center,
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.center,
                        children: _capturedLabels.map((label) => Chip(
                          label: Text(label, style: TextStyle(fontSize: 12,
                              color: hasConflict ? scheme.error : null)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          side: hasConflict ? BorderSide(color: scheme.error) : null,
                        )).toList(),
                      ),
              ),
            ),
            if (_tooMany) ...[
              const SizedBox(height: 8),
              Text(widget.isZh ? '最多5个按键' : 'Max 5 keys',
                style: TextStyle(fontSize: 12, color: scheme.error)),
            ],
            if (hasConflict) ...[
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.warning_amber_rounded, size: 14, color: scheme.error),
                const SizedBox(width: 4),
                Expanded(child: Text(
                  widget.isZh ? '与「$_conflictWith」冲突' : 'Conflicts with "$_conflictWith"',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                )),
              ]),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, <String>[]),
          child: Text(widget.isZh ? '清空' : 'Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.isZh ? '取消' : 'Cancel'),
        ),
        FilledButton(
          onPressed: (_capturedLabels.isEmpty || hasConflict) ? null : () => Navigator.pop(context, _capturedLabels),
          child: Text(widget.isZh ? '确认' : 'Confirm'),
        ),
      ],
    );
  }
}
