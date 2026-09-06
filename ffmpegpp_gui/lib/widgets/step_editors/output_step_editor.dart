import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'editor_kit.dart';

class OutputStepEditor extends ParamsStepEditor {
  final String sourceFilename;
  final String defaultOutputDir;

  const OutputStepEditor({
    super.key,
    required super.params,
    required super.onChanged,
    super.isZh = true,
    this.sourceFilename = '',
    this.defaultOutputDir = '',
  });

  @override
  State<OutputStepEditor> createState() => _OutputStepEditorState();
}

class _OutputStepEditorState extends State<OutputStepEditor> with StepEditorState<OutputStepEditor> {
  late TextEditingController _namingCtrl;
  late TextEditingController _dirCtrl;

  static const _namingModes = ['keep', 'suffix', 'custom'];

  @override
  void initState() {
    super.initState();
    initDefaults(const {'format': 'keep', 'naming_mode': 'keep', 'naming_value': '_processed'});
    // output_dir 默认值依赖 widget.defaultOutputDir，保持原 putIfAbsent 写法
    p.putIfAbsent('output_dir', () => widget.defaultOutputDir);
    _namingCtrl = TextEditingController(text: p['naming_value'] as String? ?? '_processed');
    _dirCtrl = TextEditingController(text: p['output_dir'] as String? ?? widget.defaultOutputDir);
  }

  @override
  void dispose() {
    _namingCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  static const _formats = ['keep', 'mp4', 'mkv', 'mov', 'avi', 'webm'];

  String _previewFilename() {
    final src = widget.sourceFilename;
    final base = src.replaceAll(RegExp(r'\.[^.]+$'), '');
    final srcExt = src.contains('.') ? src.split('.').last : '';
    final ext = p['format'] == 'keep' ? srcExt : (p['format'] as String? ?? srcExt);
    switch (p['naming_mode'] as String? ?? 'keep') {
      case 'suffix': return '$base${p['naming_value'] ?? '_processed'}.$ext';
      case 'custom':
        final custom = (p['naming_value'] as String? ?? '').trim();
        if (custom.contains('.')) return custom;
        // 空自定义名回退到原文件名（与执行端 resolveOutputPath 一致，避免 ".mp4" 隐藏文件）
        return custom.isEmpty ? '$base.$ext' : '$custom.$ext';
      default: return '$base.$ext';
    }
  }

  String _previewFullPath() {
    final dir = (p['output_dir'] as String? ?? '').isEmpty
        ? (widget.defaultOutputDir.isEmpty ? '(${widget.isZh ? "源文件目录" : "source dir"})' : widget.defaultOutputDir)
        : p['output_dir'] as String;
    final sep = Platform.pathSeparator;
    return '$dir$sep${_previewFilename()}';
  }

  Future<void> _browseDir() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      if (!mounted) return;
      _dirCtrl.text = result;
      p['output_dir'] = result;
      setState(() {});
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildDropdown(label: zh ? '输出格式' : 'Format', value: p['format'] as String, items: _formats,
          itemLabels: zh ? const ['保持原格式', 'MP4', 'MKV', 'MOV', 'AVI', 'WEBM'] : const ['Keep Original', 'MP4', 'MKV', 'MOV', 'AVI', 'WEBM'],
          cs: cs, onChanged: (v) { setState(() => p['format'] = v); widget.onChanged(); }),
        const SizedBox(height: 8),
        _buildDropdown(label: zh ? '命名方式' : 'Naming', value: p['naming_mode'] as String, items: _namingModes,
          itemLabels: zh ? const ['保持原名', '添加后缀', '自定义名称'] : const ['Keep Original', 'Add Suffix', 'Custom Name'],
          cs: cs, onChanged: (v) {
            setState(() => p['naming_mode'] = v);
            if (v == 'suffix') {
              _namingCtrl.text = p['naming_value'] as String? ?? '_processed';
            } else if (v == 'custom') {
              _namingCtrl.text = p['naming_value'] as String? ?? '';
            }
            widget.onChanged();
          }),
        const SizedBox(height: 8),
        if (p['naming_mode'] == 'suffix' || p['naming_mode'] == 'custom')
          Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(
            controller: _namingCtrl,
            decoration: InputDecoration(labelText: p['naming_mode'] == 'suffix' ? (zh ? '后缀' : 'Suffix') : (zh ? '文件名' : 'Filename')),
            onChanged: (v) { p['naming_value'] = v; setState(() {}); widget.onChanged(); },
          )),
        const Divider(),
        const SizedBox(height: 8),
        Text(zh ? '输出目录' : 'Output Directory', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(
            controller: _dirCtrl,
            decoration: InputDecoration(labelText: zh ? '输出目录 (空=跟随设置)' : 'Output dir (empty=follow settings)'),
            style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: cs.onSurface),
            onChanged: (v) { p['output_dir'] = v; setState(() {}); widget.onChanged(); },
          )),
          const SizedBox(width: 8),
          IconButton(onPressed: _browseDir, icon: Icon(Icons.folder_open, size: 20, color: cs.primary)),
        ]),
        const SizedBox(height: 8),
        Container(
          width: double.infinity, padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(zh ? '输出预览' : 'Output Preview', style: TextStyle(fontSize: 11, color: cs.outline)),
            const SizedBox(height: 4),
            Text(_previewFullPath(), style: TextStyle(fontSize: 12, color: cs.onSurface, fontFamily: 'monospace')),
          ]),
        ),
      ]),
    );
  }

  Widget _buildDropdown({required String label, required String value, required List<String> items,
      List<String>? itemLabels, required ColorScheme cs, required ValueChanged<String> onChanged}) {
    final safe = items.contains(value) ? value : items.first;
    return EditorDropdown(
      label: label,
      value: safe,
      dense: false,
      items: List.generate(items.length, (i) => (items[i], itemLabels != null ? itemLabels[i] : items[i])),
      onChanged: onChanged,
    );
  }
}
