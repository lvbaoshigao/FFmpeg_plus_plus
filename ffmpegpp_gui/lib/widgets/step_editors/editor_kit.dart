import 'package:flutter/material.dart';

/// 步骤编辑器公共组件库（editor_kit）。
///
/// 抽取各 `*_step_editor.dart` 中逐字重复的脚手架代码：
/// - [ParamsStepEditor] + [StepEditorState]：`params`/`isZh` 字段、`p` 参数表、
///   `update`（原 `_update`）、`initDefaults`（原 initState 里的 putIfAbsent 排）
/// - [StepEditorScaffold]：标题 + 内容 + 底部信息框（[EditorInfoBox]）骨架
/// - [EditorDropdown]：统一样式的 `DropdownButtonFormField<String>`（dense / 普通两种形态）
/// - [NumberRangeFields]：「最小值/最大值」双数字输入行
/// - [LabeledSlider]：「标签: 值」文本 + 滑杆行
/// - [editorDenseField]：统一的高密度 InputDecoration
///
/// 迁移原则：行为完全等价 —— 默认值键序、onChanged 触发时机、文本样式、间距均不变。

/// 带参数表的步骤编辑器 widget 基类。
///
/// 各编辑器 widget 改为继承本类并转发构造参数：
/// `const XxxStepEditor({super.key, required super.params, required super.onChanged, super.isZh});`
/// 外部调用点（pipeline_editor_page.dart 等）使用命名参数，签名保持不变。
abstract class ParamsStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;

  const ParamsStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
  });
}

/// 步骤编辑器 State 公共 mixin。
///
/// 用法：`class _XxxState extends State<Xxx> with StepEditorState<Xxx> { ... }`
mixin StepEditorState<W extends ParamsStepEditor> on State<W> {
  /// 参数表（等价原各编辑器逐字重复的 `Map<String, dynamic> get p => widget.params;`）
  Map<String, dynamic> get p => widget.params;

  /// 中英文开关（等价原 build 里逐文件重复的 `final zh = widget.isZh;`）
  bool get zh => widget.isZh;

  /// initState 中批量写入默认值（putIfAbsent 语义）。
  ///
  /// 等价原 initState 里的一排 `p.putIfAbsent(key, () => value);`，
  /// Map 字面量按插入序遍历，与原逐条 putIfAbsent 的键序一致。
  /// 依赖 widget 字段的默认值（如 `() => widget.videoDuration`）请保持原写法，不要塞进这里。
  void initDefaults(Map<String, dynamic> defaults) {
    defaults.forEach((key, value) => p.putIfAbsent(key, () => value));
  }

  /// 更新参数并通知外部（等价原逐字重复的：
  /// `void _update(String key, dynamic value) { setState(() => p[key] = value); widget.onChanged(); }`）
  void update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }
}

/// 步骤编辑器统一骨架：外边距 16 + 标题 + 内容 + 底部信息框。
///
/// - [title]：顶部标题（fontSize 14 / w600 / onSurface），可省略（如无标题的裁剪编辑器）
/// - [infoText]：底部说明文字，非空时在内容后追加 8px 间距 + [EditorInfoBox]
/// - [scrollable]：true 时整体包 SingleChildScrollView（extract_audio / subtitle 等长表单）
class StepEditorScaffold extends StatelessWidget {
  const StepEditorScaffold({
    super.key,
    this.title,
    required this.children,
    this.infoText,
    this.scrollable = false,
  });

  final String? title;
  final List<Widget> children;
  final String? infoText;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final column = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (title != null) ...[
        Text(title!, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 8),
      ],
      ...children,
      if (infoText != null) ...[
        const SizedBox(height: 8),
        EditorInfoBox(infoText!),
      ],
    ]);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: scrollable ? SingleChildScrollView(child: column) : column,
    );
  }
}

/// 底部说明信息框（原 19 个编辑器逐字重复的整段 Container widget 树）。
///
/// 默认样式：padding 10、背景 surfaceContainerHighest.withAlpha(60)、圆角 8、
/// info_outline 图标 14px、间距 8、文字 fontSize 11 / height 1.4，均为 outline 色。
/// [color]/[background]/[borderColor] 供特殊变体使用（如 logic_block 的红色警示框）。
class EditorInfoBox extends StatelessWidget {
  const EditorInfoBox(this.text, {super.key, this.color, this.background, this.borderColor});

  final String text;
  final Color? color;
  final Color? background;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = color ?? cs.outline;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background ?? cs.surfaceContainerHighest.withAlpha(60),
        borderRadius: BorderRadius.circular(8),
        border: borderColor == null ? null : Border.all(color: borderColor!),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, size: 14, color: fg),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(fontSize: 11, color: fg, height: 1.4))),
      ]),
    );
  }
}

/// 统一的字符串下拉选择框。
///
/// [items] 为 `(参数值, 显示文本)` 列表；[onChanged] 收到的值已做 null 保护。
/// 两种原样形态（均保留 dropdownColor: cs.surface、style fontSize 13、
/// borderRadius 12、isExpanded）：
/// - [dense] = true（默认）：isDense + 圆角 8 OutlineInputBorder + contentPadding h12 v10
/// - [dense] = false：仅 `InputDecoration(labelText: label)`
/// [labelColor] 供个别带自定义 labelStyle 的变体（image_to_video 格式/编码器行）。
class EditorDropdown extends StatelessWidget {
  const EditorDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    this.onChanged,
    this.dense = true,
    this.labelColor,
  });

  final String label;
  final String value;
  final List<(String, String)> items;
  final ValueChanged<String>? onChanged;
  final bool dense;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final decoration = dense
        ? InputDecoration(
            labelText: label,
            isDense: true,
            labelStyle: labelColor == null ? null : TextStyle(color: labelColor),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          )
        : InputDecoration(labelText: label);
    return DropdownButtonFormField<String>(
      borderRadius: BorderRadius.circular(12),
      initialValue: value,
      isExpanded: true,
      decoration: decoration,
      dropdownColor: cs.surface,
      style: TextStyle(fontSize: 13, color: cs.onSurface),
      items: [
        for (final (v, text) in items)
          DropdownMenuItem(value: v, child: Text(text, style: TextStyle(fontSize: 13, color: cs.onSurface))),
      ],
      onChanged: (v) { if (v != null) onChanged?.call(v); },
    );
  }
}

/// 「最小值/最大值」双数字输入行（原 12 个编辑器逐字重复的模式）。
///
/// 每个字段均为：isDense + 圆角 8 边框 + contentPadding h12 v10 的
/// TextFormField，keyboardType number；[integer] 为 true 时按 int.tryParse
/// 解析（写入 int），否则按 double.tryParse（写入 double），解析失败不触发回调，
/// 与原 `onChanged: (v) { final d = ...tryParse(v); if (d != null) _update(...); }` 一致。
/// [minText]/[maxText] 为 initialValue 字符串，由调用方按原格式拼接。
class NumberRangeFields extends StatelessWidget {
  const NumberRangeFields({
    super.key,
    required this.minLabel,
    required this.maxLabel,
    required this.minText,
    required this.maxText,
    required this.onMinChanged,
    required this.onMaxChanged,
    this.integer = false,
  });

  final String minLabel;
  final String maxLabel;
  final String minText;
  final String maxText;
  final ValueChanged<num> onMinChanged;
  final ValueChanged<num> onMaxChanged;
  final bool integer;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: TextFormField(
        initialValue: minText,
        decoration: editorDenseField(minLabel),
        keyboardType: TextInputType.number,
        onChanged: (v) { final d = integer ? int.tryParse(v) : double.tryParse(v); if (d != null) onMinChanged(d); },
      )),
      const SizedBox(width: 8),
      Expanded(child: TextFormField(
        initialValue: maxText,
        decoration: editorDenseField(maxLabel),
        keyboardType: TextInputType.number,
        onChanged: (v) { final d = integer ? int.tryParse(v) : double.tryParse(v); if (d != null) onMaxChanged(d); },
      )),
    ]);
  }
}

/// 「标签: 值」文本 + 滑杆行（原 13 个编辑器重复的模式）。
///
/// 左侧文本 fontSize [fontSize]（默认 13）/ onSurface，右侧 Expanded(Slider)。
/// [text] 为完整文本（含当前值，如 `'亮度: 0.30'`），由调用方拼接。
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.text,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.sliderLabel,
    this.fontSize = 13,
  });

  final String text;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final String? sliderLabel;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(children: [
      Text(text, style: TextStyle(fontSize: fontSize, color: cs.onSurface)),
      Expanded(child: Slider(
        value: value, min: min, max: max, divisions: divisions, label: sliderLabel,
        onChanged: onChanged,
      )),
    ]);
  }
}

/// 统一的高密度输入框装饰（isDense + 圆角 8 边框 + contentPadding h12 v10）。
InputDecoration editorDenseField(String label, {String? hint, String? suffixText}) => InputDecoration(
  labelText: label,
  isDense: true,
  hintText: hint,
  suffixText: suffixText,
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
);
