import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

class OutputStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;
  final String sourceFilename;
  final String defaultOutputDir;

  const OutputStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
    this.sourceFilename = '',
    this.defaultOutputDir = '',
  });

  @override
  State<OutputStepEditor> createState() => _OutputStepEditorState();
}

class _OutputStepEditorState extends State<OutputStepEditor> {
  late TextEditingController _namingCtrl;
  late TextEditingController _dirCtrl;

  Map<String, dynamic> get p => widget.params;

  static const _formats = ['keep', 'mp4', 'mkv', 'mov', 'avi', 'webm'];
  static const _namingModes = ['keep', 'suffix', 'custom'];

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('format', () => 'keep');
    p.putIfAbsent('naming_mode', () => 'keep');
    p.putIfAbsent('naming_value', () => '_processed');
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

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label, isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );

  String _previewFilename() {
    final src = widget.sourceFilename;
    final base = src.replaceAll(RegExp(r'\.[^.]+$'), '');
    final srcExt = src.contains('.') ? src.split('.').last : '';
    final ext = p['format'] == 'keep' ? srcExt : (p['format'] as String? ?? srcExt);
    switch (p['naming_mode'] as String? ?? 'keep') {
      case 'suffix': return '$base${p['naming_value'] ?? '_processed'}.$ext';
      case 'custom':
        final custom = p['naming_value'] as String? ?? '';
        if (custom.contains('.')) return custom;
        return '$custom.$ext';
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
        const SizedBox(height: 12),
        _buildDropdown(label: zh ? '命名方式' : 'Naming', value: p['naming_mode'] as String, items: _namingModes,
          itemLabels: zh ? const ['保持原名', '添加后缀', '自定义名称'] : const ['Keep Original', 'Add Suffix', 'Custom Name'],
          cs: cs, onChanged: (v) {
            setState(() => p['naming_mode'] = v);
            if (v == 'suffix') _namingCtrl.text = p['naming_value'] as String? ?? '_processed';
            else if (v == 'custom') _namingCtrl.text = p['naming_value'] as String? ?? '';
            widget.onChanged();
          }),
        const SizedBox(height: 12),
        if (p['naming_mode'] == 'suffix' || p['naming_mode'] == 'custom')
          Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(
            controller: _namingCtrl,
            decoration: _dec(p['naming_mode'] == 'suffix' ? (zh ? '后缀' : 'Suffix') : (zh ? '文件名' : 'Filename')),
            onChanged: (v) { p['naming_value'] = v; setState(() {}); widget.onChanged(); },
          )),
        const Divider(),
        const SizedBox(height: 8),
        Text(zh ? '输出目录' : 'Output Directory', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(
            controller: _dirCtrl,
            decoration: _dec(zh ? '输出目录 (空=跟随设置)' : 'Output dir (empty=follow settings)'),
            style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: cs.onSurface),
            onChanged: (v) { p['output_dir'] = v; setState(() {}); widget.onChanged(); },
          )),
          const SizedBox(width: 8),
          IconButton(onPressed: _browseDir, icon: Icon(Icons.folder_open, size: 20, color: cs.primary)),
        ]),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
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
    return DropdownButtonFormField<String>(
      initialValue: safe, isExpanded: true, decoration: _dec(label),
      dropdownColor: cs.surface, style: TextStyle(fontSize: 13, color: cs.onSurface),
      items: List.generate(items.length, (i) => DropdownMenuItem(
        value: items[i], child: Text(itemLabels != null ? itemLabels[i] : items[i], style: TextStyle(fontSize: 13, color: cs.onSurface)),
      )),
      onChanged: (v) { if (v != null) onChanged(v); },
    );
  }
}
