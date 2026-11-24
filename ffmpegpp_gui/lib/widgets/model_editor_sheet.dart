import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../models/models.dart';
import '../theme/app_control_size.dart';
import 'app_alert_dialog.dart';
import 'app_card.dart';
import 'app_slider.dart';
import 'liquid_modality_pills.dart';
import 'mobile_glass_pill.dart';

/// Page2.1 的模型编辑底部面板（替代旧的全屏 MobileModelSettingsPage）。
///
/// 字段与 AiModelEntry 的新增字段一一对应：
/// 显示名称 / ID / 是否启用 / 上下文 / 最大输出 / 温度 / Top_P /
/// 支持输入 / 支持输出（text·image·voice 液态拉伸药丸，可拖动排序）。
///
/// 交互约定：
/// * 所有修改先落在本地副本，点「完成」才通过 Navigator.pop 返回新条目；
///   ID 为空或与同提供商其它模型重复时不会关闭面板，而是在字段下方提示。
/// * 输入模态选中 image 时自动补 vision 能力；取消 image 时移除 vision，
///   保证新旧能力字段兼容（capabilities 仍会被序列化）。
/// * 输出模态与能力字段没有既定映射，仅保存到 outputModalities。
class ModelEditorSheet extends StatefulWidget {
  final AiModelEntry entry;
  final bool isNew;
  final int defaultContextWindow;
  final int defaultMaxTokens;
  final double defaultTemperature;
  final bool isZh;
  final String cardStyle;
  final String pillStyle;
  final Set<String> takenIds;

  const ModelEditorSheet({
    super.key,
    required this.entry,
    required this.isNew,
    required this.defaultContextWindow,
    required this.defaultMaxTokens,
    required this.defaultTemperature,
    required this.isZh,
    required this.cardStyle,
    required this.pillStyle,
    this.takenIds = const <String>{},
  });

  @override
  State<ModelEditorSheet> createState() => _ModelEditorSheetState();
}

class _ModelEditorSheetState extends State<ModelEditorSheet> {
  late final AiModelEntry _entry = widget.entry.copy();
  late final TextEditingController _displayName = TextEditingController(
    text: _entry.displayName,
  );
  late final TextEditingController _id = TextEditingController(text: _entry.id);
  final FocusNode _idFocus = FocusNode();
  late final TextEditingController _context = TextEditingController(
    text: _entry.contextWindow?.toString() ?? '',
  );
  late final TextEditingController _maxTokens = TextEditingController(
    text: _entry.maxTokens?.toString() ?? '',
  );
  late final List<String> _inputOrder;
  late final List<String> _outputOrder;
  late final Set<String> _inputSelected;
  late final Set<String> _outputSelected;
  bool _enabled = true;
  String? _idError;

  /// 保留已保存的模态顺序（拖动排序后重开面板仍然生效），未出现的补齐到末尾。
  static List<String> _orderFor(List<String> values) {
    final order = <String>[];
    for (final value in values) {
      if (LiquidModalities.all.contains(value) && !order.contains(value)) {
        order.add(value);
      }
    }
    for (final value in LiquidModalities.all) {
      if (!order.contains(value)) order.add(value);
    }
    return order;
  }

  @override
  void initState() {
    super.initState();
    _enabled = _entry.enabled;
    _inputOrder = _orderFor(_entry.inputModalities);
    _outputOrder = _orderFor(_entry.outputModalities);
    _inputSelected = {..._entry.inputModalities};
    // 旧配置只有 capabilities.vision、没有 inputModalities：把 image 补进输入，
    // 避免打开面板后一保存就把视觉能力丢掉。
    if (_entry.capabilities.contains(AiModelCapability.vision)) {
      _inputSelected.add(LiquidModalities.image);
    }
    if (_inputSelected.isEmpty) _inputSelected.add(LiquidModalities.text);
    _outputSelected = {..._entry.outputModalities};
    if (_outputSelected.isEmpty) _outputSelected.add(LiquidModalities.text);
    _commitModalities();
  }

  @override
  void dispose() {
    _displayName.dispose();
    _id.dispose();
    _idFocus.dispose();
    _context.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  List<String> _selectedInOrder(Set<String> selected, List<String> order) => [
    for (final value in order)
      if (selected.contains(value)) value,
  ];

  void _commitModalities() {
    _entry.inputModalities = _selectedInOrder(_inputSelected, _inputOrder);
    _entry.outputModalities = _selectedInOrder(_outputSelected, _outputOrder);
    final caps = _entry.capabilities;
    final wantsVision = _inputSelected.contains(LiquidModalities.image);
    if (wantsVision) {
      if (!caps.contains(AiModelCapability.vision)) {
        caps.add(AiModelCapability.vision);
      }
    } else {
      caps.remove(AiModelCapability.vision);
    }
    if (caps.isEmpty) caps.add(AiModelCapability.chat);
  }

  void _toggleModality({required bool input, required String value}) {
    final set = input ? _inputSelected : _outputSelected;
    if (set.contains(value) && set.length <= 1) return;
    setState(() {
      if (!set.remove(value)) set.add(value);
      _commitModalities();
    });
  }

  void _reorderModality({
    required bool input,
    required int oldIndex,
    required int newIndex,
  }) {
    final order = input ? _inputOrder : _outputOrder;
    if (oldIndex < 0 || oldIndex >= order.length) return;
    setState(() {
      final item = order.removeAt(oldIndex);
      order.insert(newIndex.clamp(0, order.length), item);
      _commitModalities();
    });
  }

  String? _validateId(String raw) {
    final id = raw.trim();
    if (id.isEmpty) {
      return widget.isZh ? '模型 ID 不能为空' : 'Model ID is required';
    }
    if (widget.takenIds.contains(id)) {
      return widget.isZh ? '该模型已存在' : 'Model already exists';
    }
    return null;
  }

  void _done() {
    final error = _validateId(_id.text);
    if (error != null) {
      setState(() => _idError = error);
      _idFocus.requestFocus();
      return;
    }
    _entry
      ..id = _id.text.trim()
      ..displayName = _displayName.text.trim()
      ..enabled = _enabled
      ..contextWindow = _positiveInt(_context.text)
      ..maxTokens = _positiveInt(_maxTokens.text);
    _commitModalities();
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop<AiModelEntry>(_entry.copy());
  }

  void _resetInherited() {
    setState(() {
      _entry
        ..contextWindow = null
        ..maxTokens = null
        ..temperature = null
        ..topP = null;
      _context.clear();
      _maxTokens.clear();
    });
  }

  static int? _positiveInt(String raw) {
    final value = int.tryParse(raw.trim());
    return value != null && value > 0 ? value : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sheetTheme = theme.bottomSheetTheme;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final title = widget.isNew
        ? (widget.isZh ? '添加自定义模型' : 'Add custom model')
        : (widget.isZh ? '编辑模型' : 'Edit model');
    final actionMinimum = const WidgetStatePropertyAll(Size(48, 48));
    final cancelActionStyle = AppDialogAction.styleOf(
      context,
      AppDialogActionRole.cancel,
    ).copyWith(minimumSize: actionMinimum);
    final primaryActionStyle = AppDialogAction.styleOf(
      context,
      AppDialogActionRole.primary,
    ).copyWith(minimumSize: actionMinimum);

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = (constraints.maxHeight - keyboardInset).clamp(
          0.0,
          MediaQuery.sizeOf(context).height,
        );
        return Padding(
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: availableHeight * 0.96),
            child: Material(
              key: const ValueKey('model_editor_sheet'),
              color: sheetTheme.backgroundColor ?? scheme.surface,
              surfaceTintColor: sheetTheme.surfaceTintColor,
              shape:
                  sheetTheme.shape ??
                  const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 4),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color:
                              sheetTheme.dragHandleColor ??
                              scheme.onSurfaceVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: SizedBox.fromSize(
                          size: sheetTheme.dragHandleSize ?? const Size(36, 4),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 8, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Semantics(
                              header: true,
                              child: Text(
                                title,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          key: const ValueKey('model_sheet_close'),
                          tooltip: widget.isZh ? '取消' : 'Cancel',
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded, size: 22),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      key: const ValueKey('model_sheet_scroll'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildDetails(),
                          _buildCapabilities(),
                          _buildAdvanced(scheme),
                        ],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    key: const ValueKey('model_sheet_footer'),
                    decoration: BoxDecoration(
                      color: sheetTheme.backgroundColor ?? scheme.surface,
                      border: Border(
                        top: BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        20,
                        12,
                        20,
                        12 + MediaQuery.paddingOf(context).bottom,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              key: const ValueKey('model_sheet_cancel'),
                              style: cancelActionStyle,
                              onPressed: () => Navigator.of(context).maybePop(),
                              child: Text(widget.isZh ? '取消' : 'Cancel'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              key: const ValueKey('model_sheet_done'),
                              style: primaryActionStyle,
                              onPressed: _done,
                              child: Text(widget.isZh ? '完成' : 'Done'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetails() => _SheetSection(
    cardStyle: widget.cardStyle,
    title: widget.isZh ? '模型信息' : 'Model details',
    subtitle: widget.isZh
        ? '名称便于识别，模型 ID 用于发送请求。'
        : 'The name is for you. The model ID is sent to the provider.',
    children: [
      _SheetTextField(
        key: const ValueKey('model_sheet_display_name'),
        label: widget.isZh ? '显示名称' : 'Display name',
        controller: _displayName,
        hint: widget.isZh ? '例如 GPT-6' : 'e.g. GPT-6',
        helper: widget.isZh
            ? '选填，留空时显示模型 ID'
            : 'Optional; uses the model ID when empty',
      ),
      _SheetTextField(
        key: const ValueKey('model_sheet_id'),
        label: widget.isZh ? '模型 ID' : 'Model ID',
        controller: _id,
        focusNode: _idFocus,
        hint: 'gpt-6',
        helper: widget.isZh
            ? '必填，与供应商提供的标识一致；同一提供商内不可重复。'
            : 'Required. Use the provider’s exact identifier; it must be unique here.',
        error: _idError,
        onChanged: (_) {
          if (_idError != null) {
            setState(() => _idError = null);
          }
        },
      ),
      _SwitchRow(
        label: widget.isZh ? '是否启用' : 'Enabled',
        description: widget.isZh
            ? '停用后不参与模型选择'
            : 'Disabled models stay hidden from selection',
        value: _enabled,
        onChanged: (value) => setState(() => _enabled = value),
      ),
    ],
  );

  Widget _buildCapabilities() => _SheetSection(
    cardStyle: widget.cardStyle,
    title: widget.isZh ? '模型能力' : 'Capabilities',
    subtitle: widget.isZh
        ? '选择支持的输入与输出类型；每项至少保留一种。'
        : 'Choose the supported input and output types. Keep at least one of each.',
    children: [
      _SheetModalities(
        keyPrefix: 'model_sheet_input',
        label: widget.isZh ? '支持输入' : 'Input',
        order: _inputOrder,
        selected: _inputSelected,
        isZh: widget.isZh,
        pillStyle: widget.pillStyle,
        onToggle: (value) => _toggleModality(input: true, value: value),
        onReorder: (from, to) =>
            _reorderModality(input: true, oldIndex: from, newIndex: to),
      ),
      const SizedBox(height: 20),
      _SheetModalities(
        keyPrefix: 'model_sheet_output',
        label: widget.isZh ? '支持输出' : 'Output',
        order: _outputOrder,
        selected: _outputSelected,
        isZh: widget.isZh,
        pillStyle: widget.pillStyle,
        onToggle: (value) => _toggleModality(input: false, value: value),
        onReorder: (from, to) =>
            _reorderModality(input: false, oldIndex: from, newIndex: to),
      ),
      const SizedBox(height: 12),
      Text(
        widget.isZh
            ? '点击切换，长按拖动排序。图像输入会同时启用视觉能力。'
            : 'Tap to toggle; hold and drag to reorder. Image input also enables vision.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _buildAdvanced(ColorScheme scheme) {
    final hasOverrides =
        _context.text.isNotEmpty ||
        _maxTokens.text.isNotEmpty ||
        _entry.temperature != null ||
        _entry.topP != null;
    return _SheetSection(
      cardStyle: widget.cardStyle,
      title: widget.isZh ? '高级参数' : 'Advanced parameters',
      subtitle: widget.isZh
          ? '仅对该模型生效。留空或恢复默认，即继承提供商设置。'
          : 'Applies to this model only. Leave fields empty or reset to inherit provider defaults.',
      children: [
        _SheetTextField(
          key: const ValueKey('model_sheet_context'),
          label: widget.isZh ? '上下文' : 'Context',
          controller: _context,
          keyboardType: TextInputType.number,
          hint: widget.defaultContextWindow.toString(),
          helper: widget.isZh
              ? '继承默认：${widget.defaultContextWindow} tokens'
              : 'Provider default: ${widget.defaultContextWindow} tokens',
          onChanged: (_) => setState(() {}),
        ),
        _SheetTextField(
          key: const ValueKey('model_sheet_max_tokens'),
          label: widget.isZh ? '最大输出' : 'Max output',
          controller: _maxTokens,
          keyboardType: TextInputType.number,
          hint: widget.defaultMaxTokens.toString(),
          helper: widget.isZh
              ? '继承默认：${widget.defaultMaxTokens} tokens'
              : 'Provider default: ${widget.defaultMaxTokens} tokens',
          onChanged: (_) => setState(() {}),
        ),
        _ParamSliderRow(
          label: widget.isZh ? '温度' : 'Temperature',
          value: _entry.temperature ?? widget.defaultTemperature,
          min: 0,
          max: 2,
          divisions: 20,
          decimals: 1,
          customized: _entry.temperature != null,
          fallbackLabel: widget.defaultTemperature.toStringAsFixed(1),
          resetLabel: widget.isZh ? '默认' : 'Default',
          onReset: () => setState(() => _entry.temperature = null),
          onCommit: (value) => setState(() => _entry.temperature = value),
          scheme: scheme,
        ),
        _ParamSliderRow(
          label: 'Top_P',
          value: _entry.topP ?? 1.0,
          min: 0,
          max: 1,
          divisions: 20,
          decimals: 2,
          customized: _entry.topP != null,
          fallbackLabel: '1.00',
          resetLabel: widget.isZh ? '默认' : 'Default',
          onReset: () => setState(() => _entry.topP = null),
          onCommit: (value) => setState(() => _entry.topP = value),
          scheme: scheme,
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('model_sheet_reset_defaults'),
            onPressed: hasOverrides ? _resetInherited : null,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              alignment: AlignmentDirectional.centerStart,
            ),
            icon: const Icon(Icons.restart_alt_rounded, size: 20),
            label: Text(widget.isZh ? '恢复继承默认' : 'Use provider defaults'),
          ),
        ),
      ],
    );
  }
}

class _SheetSection extends StatelessWidget {
  final String cardStyle;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const _SheetSection({
    required this.cardStyle,
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          AppCard(
            style: cardStyle,
            radius: 20,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (subtitle != null) ...[
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  ...children,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps the existing liquid control where labels fit, and reflows at large text.
class _SheetModalities extends StatelessWidget {
  final String keyPrefix;
  final String label;
  final List<String> order;
  final Set<String> selected;
  final bool isZh;
  final String pillStyle;
  final ValueChanged<String> onToggle;
  final void Function(int, int) onReorder;

  const _SheetModalities({
    required this.keyPrefix,
    required this.label,
    required this.order,
    required this.selected,
    required this.isZh,
    required this.pillStyle,
    required this.onToggle,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: theme.textTheme.titleSmall),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
            // LiquidModalityPills distributes a single row by selection weight.
            // Give every label enough room rather than shrinking system text.
            if (constraints.maxWidth >= 280 && textScale <= 1.2) {
              return MobileGlassPill(
                style: pillStyle,
                radius: 28,
                padding: const EdgeInsets.all(4),
                child: LiquidModalityPills(
                  key: ValueKey(keyPrefix),
                  keyPrefix: keyPrefix,
                  height: 48,
                  order: order,
                  selected: selected,
                  isZh: isZh,
                  labelOf: (value) => _modalityLabel(value, isZh).$1,
                  iconOf: (value) => _modalityLabel(value, isZh).$2,
                  onToggle: onToggle,
                  onReorder: onReorder,
                ),
              );
            }
            return Wrap(
              key: ValueKey(keyPrefix),
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var index = 0; index < order.length; index++)
                  _wrappedModality(context, order[index], index),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _wrappedModality(BuildContext context, String value, int index) {
    final (label, icon) = _modalityLabel(value, isZh);
    Widget chip({bool feedback = false}) => FilterChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      selected: selected.contains(value),
      onSelected: feedback ? null : (_) => onToggle(value),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    );
    return Semantics(
      key: ValueKey('${keyPrefix}_$value'),
      hint: isZh ? '长按拖动可排序' : 'Hold and drag to reorder',
      customSemanticsActions: {
        if (index > 0)
          CustomSemanticsAction(label: isZh ? '左移' : 'Move left'): () =>
              onReorder(index, index - 1),
        if (index < order.length - 1)
          CustomSemanticsAction(label: isZh ? '右移' : 'Move right'): () =>
              onReorder(index, index + 1),
      },
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) =>
            details.data != value && order.contains(details.data),
        onAcceptWithDetails: (details) =>
            onReorder(order.indexOf(details.data), index),
        builder: (context, candidateData, rejectedData) =>
            LongPressDraggable<String>(
              data: value,
              feedback: Material(
                color: Colors.transparent,
                child: chip(feedback: true),
              ),
              childWhenDragging: Opacity(opacity: 0.4, child: chip()),
              child: chip(),
            ),
      ),
    );
  }
}

class _SheetTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final String? error;
  final TextInputType? keyboardType;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;

  const _SheetTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.error,
    this.keyboardType,
    this.focusNode,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: Text(label, style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: 8),
          Semantics(
            label: label,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: keyboardType,
              textInputAction: TextInputAction.next,
              onChanged: onChanged,
              style: theme.textTheme.bodyLarge,
              textAlignVertical: TextAlignVertical.center,
              scrollPadding: const EdgeInsets.all(24),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                helperText: helper,
                helperMaxLines: 5,
                helperStyle: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                errorText: error,
                errorMaxLines: 5,
                errorStyle: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.error,
                ),
                constraints: const BoxConstraints(minHeight: 48),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                visualDensity: AppControlSize.fieldDensity,
              ),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SwitchListTile(
      key: const ValueKey('model_sheet_enabled'),
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: theme.textTheme.titleSmall),
      subtitle: description == null
          ? null
          : Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    );
  }
}

class _ParamSliderRow extends StatefulWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final int decimals;
  final bool customized;
  final String fallbackLabel;
  final String resetLabel;
  final VoidCallback onReset;
  final ValueChanged<double> onCommit;
  final ColorScheme scheme;

  const _ParamSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.decimals,
    required this.customized,
    required this.fallbackLabel,
    required this.resetLabel,
    required this.onReset,
    required this.onCommit,
    required this.scheme,
  });

  @override
  State<_ParamSliderRow> createState() => _ParamSliderRowState();
}

class _ParamSliderRowState extends State<_ParamSliderRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final double effective = (_drag ?? widget.value).clamp(
      widget.min,
      widget.max,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.customized
                      ? '${widget.label}: ${effective.toStringAsFixed(widget.decimals)}'
                      : '${widget.label}: ${widget.fallbackLabel}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: widget.scheme.onSurface,
                  ),
                ),
              ),
              if (widget.customized)
                TextButton(
                  onPressed: () {
                    setState(() => _drag = null);
                    widget.onReset();
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(48, 48),
                  ),
                  child: Text(widget.resetLabel),
                ),
            ],
          ),
          Semantics(
            label: widget.label,
            child: AppSlider(
              value: effective,
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              onChanged: (value) => setState(() => _drag = value),
              onChangeEnd: (value) {
                widget.onCommit(value);
                setState(() => _drag = null);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 模态显示名 / 图标（与 ai_settings_mobile.dart 中的模型行保持一致）。
(String, IconData) _modalityLabel(
  String modality,
  bool isZh,
) => switch (modality) {
  LiquidModalities.text => (isZh ? '文本' : 'Text', Icons.text_fields_rounded),
  LiquidModalities.image => (isZh ? '图像' : 'Image', Icons.image_outlined),
  LiquidModalities.voice => (isZh ? '语音' : 'Voice', Icons.graphic_eq_rounded),
  _ => (modality, Icons.label_outline),
};
