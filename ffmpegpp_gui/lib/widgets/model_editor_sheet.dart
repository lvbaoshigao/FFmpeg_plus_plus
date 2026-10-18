import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_control_size.dart';
import '../theme/settings_typography.dart';
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
    final scheme = Theme.of(context).colorScheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final bool hasOverrides =
        _entry.contextWindow != null ||
        _entry.maxTokens != null ||
        _entry.temperature != null ||
        _entry.topP != null;
    final double maxHeight =
        (MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom)
            .clamp(240.0, double.infinity);
    final String title = widget.isNew
        ? (widget.isZh ? '添加自定义模型' : 'Add custom model')
        : (widget.isZh ? '编辑模型' : 'Edit model');

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight * 0.94),
        child: SafeArea(
          top: false,
          child: DecoratedBox(
            key: const ValueKey('model_editor_sheet'),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(26),
              ),
              border: Border(
                top: BorderSide(
                  color: scheme.outlineVariant.withAlpha(isDark ? 70 : 90),
                  width: 0.7,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: isDark ? 0.42 : 0.20),
                  blurRadius: 26,
                  offset: const Offset(0, -8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 2),
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 8, 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(
                              header: true,
                              child: Text(
                                title,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.isZh
                                  ? '仅对该模型生效；留空项继承提供商默认值'
                                  : 'Applies to this model only; empty fields inherit provider defaults',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: SettingsTypography.description.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hasOverrides)
                        IconButton(
                          tooltip: widget.isZh
                              ? '恢复继承默认'
                              : 'Inherit defaults',
                          icon: Icon(
                            Icons.restart_alt,
                            size: 19,
                            color: scheme.onSurfaceVariant,
                          ),
                          constraints: const BoxConstraints.tightFor(
                            width: 44,
                            height: 44,
                          ),
                          onPressed: _resetInherited,
                        ),
                      IconButton(
                        key: const ValueKey('model_sheet_close'),
                        tooltip: widget.isZh ? '取消' : 'Cancel',
                        icon: Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SheetSection(
                          cardStyle: widget.cardStyle,
                          title: widget.isZh ? '基本信息' : 'Basic info',
                          children: [
                            _LabeledField(
                              label: widget.isZh ? '显示名称' : 'Display name',
                              child: _SheetTextField(
                                key: const ValueKey(
                                  'model_sheet_display_name',
                                ),
                                controller: _displayName,
                                hint: widget.isZh
                                    ? '例如 GPT-6（留空显示 ID）'
                                    : 'e.g. GPT-6 (empty falls back to ID)',
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            _LabeledField(
                              label: widget.isZh ? '模型 ID' : 'Model ID',
                              error: _idError,
                              hint: widget.isZh
                                  ? '供应商提供的模型标识'
                                  : 'Model identifier from the provider',
                              child: _SheetTextField(
                                key: const ValueKey('model_sheet_id'),
                                controller: _id,
                                hint: 'gpt-6',
                                onChanged: (_) {
                                  if (_idError != null) {
                                    setState(() => _idError = null);
                                  }
                                },
                              ),
                            ),
                            _SwitchRow(
                              label: widget.isZh ? '是否启用' : 'Enabled',
                              description: widget.isZh
                                  ? '停用后不参与模型选择'
                                  : 'Disabled models stay hidden from selection',
                              value: _enabled,
                              onChanged: (value) =>
                                  setState(() => _enabled = value),
                            ),
                          ],
                        ),
                        _SheetSection(
                          cardStyle: widget.cardStyle,
                          title: widget.isZh ? '生成参数' : 'Generation',
                          children: [
                            _LabeledField(
                              label: widget.isZh ? '上下文' : 'Context',
                              hint: widget.isZh
                                  ? '继承默认：${widget.defaultContextWindow}'
                                  : 'Inherit default: ${widget.defaultContextWindow}',
                              child: _SheetTextField(
                                key: const ValueKey('model_sheet_context'),
                                controller: _context,
                                keyboardType: TextInputType.number,
                                hint: widget.defaultContextWindow.toString(),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            _LabeledField(
                              label: widget.isZh ? '最大输出' : 'Max output',
                              hint: widget.isZh
                                  ? '继承默认：${widget.defaultMaxTokens}'
                                  : 'Inherit default: ${widget.defaultMaxTokens}',
                              child: _SheetTextField(
                                key: const ValueKey(
                                  'model_sheet_max_tokens',
                                ),
                                controller: _maxTokens,
                                keyboardType: TextInputType.number,
                                hint: widget.defaultMaxTokens.toString(),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            _ParamSliderRow(
                              label: widget.isZh ? '温度' : 'Temperature',
                              value:
                                  _entry.temperature ??
                                  widget.defaultTemperature,
                              min: 0,
                              max: 2,
                              divisions: 20,
                              decimals: 1,
                              customized: _entry.temperature != null,
                              fallbackLabel: widget.defaultTemperature
                                  .toStringAsFixed(1),
                              resetLabel: widget.isZh ? '默认' : 'Default',
                              onReset: () =>
                                  setState(() => _entry.temperature = null),
                              onCommit: (value) =>
                                  setState(() => _entry.temperature = value),
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
                              onCommit: (value) =>
                                  setState(() => _entry.topP = value),
                              scheme: scheme,
                            ),
                          ],
                        ),
                        _SheetSection(
                          cardStyle: widget.cardStyle,
                          title: widget.isZh ? '支持输入' : 'Input',
                          subtitle: widget.isZh
                              ? '点击切换，长按拖动排序；至少保留一种'
                              : 'Tap to toggle, long press to reorder; keep at least one',
                          children: [
                            MobileGlassPill(
                              style: widget.pillStyle,
                              radius: 26,
                              padding: const EdgeInsets.all(4),
                              child: LiquidModalityPills(
                                key: const ValueKey('model_sheet_input'),
                                keyPrefix: 'model_sheet_input',
                                order: _inputOrder,
                                selected: _inputSelected,
                                isZh: widget.isZh,
                                labelOf: (value) =>
                                    _modalityLabel(value, widget.isZh).$1,
                                iconOf: (value) =>
                                    _modalityLabel(value, widget.isZh).$2,
                                onToggle: (value) => _toggleModality(
                                  input: true,
                                  value: value,
                                ),
                                onReorder: (from, to) => _reorderModality(
                                  input: true,
                                  oldIndex: from,
                                  newIndex: to,
                                ),
                              ),
                            ),
                          ],
                        ),
                        _SheetSection(
                          cardStyle: widget.cardStyle,
                          title: widget.isZh ? '支持输出' : 'Output',
                          subtitle: widget.isZh
                              ? '点击切换，长按拖动排序；至少保留一种'
                              : 'Tap to toggle, long press to reorder; keep at least one',
                          children: [
                            MobileGlassPill(
                              style: widget.pillStyle,
                              radius: 26,
                              padding: const EdgeInsets.all(4),
                              child: LiquidModalityPills(
                                key: const ValueKey('model_sheet_output'),
                                keyPrefix: 'model_sheet_output',
                                order: _outputOrder,
                                selected: _outputSelected,
                                isZh: widget.isZh,
                                labelOf: (value) =>
                                    _modalityLabel(value, widget.isZh).$1,
                                iconOf: (value) =>
                                    _modalityLabel(value, widget.isZh).$2,
                                onToggle: (value) => _toggleModality(
                                  input: false,
                                  value: value,
                                ),
                                onReorder: (from, to) => _reorderModality(
                                  input: false,
                                  oldIndex: from,
                                  newIndex: to,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
                          child: Text(
                            widget.isZh
                                ? '输入选「图像」会自动补上视觉能力；ID 不能与同提供商下的其它模型重复。'
                                : 'Selecting Image as input also enables the vision capability; IDs must be unique within this provider.',
                            style: SettingsTypography.description.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      TextButton(
                        key: const ValueKey('model_sheet_cancel'),
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: Text(widget.isZh ? '取消' : 'Cancel'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('model_sheet_done'),
                          style: AppControlSize.large.buttonStyle(filled: true),
                          onPressed: _done,
                          child: Text(widget.isZh ? '完成' : 'Done'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: SettingsTypography.sectionTitle.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          AppCard(
            style: cardStyle,
            radius: 20,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (subtitle != null) ...[
                    Text(
                      subtitle!,
                      style: SettingsTypography.description.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
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

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  final String? hint;
  final String? error;

  const _LabeledField({
    required this.label,
    required this.child,
    this.hint,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          child,
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(
              error!,
              style: TextStyle(fontSize: 10.5, color: scheme.error),
            ),
          ] else if (hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: scheme.outline,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SheetTextField extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  const _SheetTextField({
    super.key,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    const AppControlSize size = AppControlSize.large;
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      onChanged: onChanged,
      style: TextStyle(fontSize: 13.5, height: 1.2, color: scheme.onSurface),
      cursorColor: scheme.primary,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: 12.5,
          color: scheme.onSurfaceVariant.withAlpha(170),
        ),
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withAlpha(isDark ? 76 : 100),
        contentPadding: size.fieldPadding,
        visualDensity: AppControlSize.fieldDensity,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withAlpha(isDark ? 64 : 95),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withAlpha(isDark ? 64 : 95),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.primary.withAlpha(210),
            width: 1.4,
          ),
        ),
      ),
      onTapOutside: (_) => FocusScope.of(context).unfocus(),
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
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onChanged(!value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontSize: 13, color: scheme.onSurface),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        description!,
                        style: SettingsTypography.description.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                key: const ValueKey('model_sheet_enabled'),
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
      ),
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
                  style: TextStyle(
                    fontSize: 12,
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
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 40),
                  ),
                  child: Text(
                    widget.resetLabel,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
          AppSlider(
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
        ],
      ),
    );
  }
}

/// 模态显示名 / 图标（与 ai_settings_mobile.dart 中的模型行保持一致）。
(String, IconData) _modalityLabel(String modality, bool isZh) =>
    switch (modality) {
      LiquidModalities.text => (
        isZh ? '文本' : 'Text',
        Icons.text_fields_rounded,
      ),
      LiquidModalities.image => (isZh ? '图像' : 'Image', Icons.image_outlined),
      LiquidModalities.voice => (
        isZh ? '语音' : 'Voice',
        Icons.graphic_eq_rounded,
      ),
      _ => (modality, Icons.label_outline),
    };
