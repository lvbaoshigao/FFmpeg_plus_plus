import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

class SubtitleStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;
  final List<dynamic> embeddedSubtitles;

  const SubtitleStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
    this.embeddedSubtitles = const [],
  });

  @override
  State<SubtitleStepEditor> createState() => _SubtitleStepEditorState();
}

class _SubtitleStepEditorState extends State<SubtitleStepEditor> {
  Map<String, dynamic> get p => widget.params;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('source', () => 'external');
    p.putIfAbsent('subtitle_index', () => 0);
    p.putIfAbsent('font_name', () => 'Arial');
    p.putIfAbsent('font_size', () => 24);
    p.putIfAbsent('font_color', () => '#FFFFFF');
    p.putIfAbsent('outline_width', () => 2);
    p.putIfAbsent('outline_color', () => '#000000');
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  InputDecoration _dec(String label) => InputDecoration(
    labelText: label, isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  Color _hexToColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.tryParse(hex, radix: 16) ?? 0xFFFFFFFF);
  }

  String _colorToHex(Color c) =>
      '#${c.red.toRadixString(16).padLeft(2, '0')}${c.green.toRadixString(16).padLeft(2, '0')}${c.blue.toRadixString(16).padLeft(2, '0')}'.toUpperCase();

  Future<void> _pickSubtitleFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt', 'ass', 'ssa', 'sub', 'vtt'],
    );
    if (result != null && result.files.isNotEmpty && result.files.first.path != null) {
      _update('subtitle_file', result.files.first.path!);
    }
  }

  void _pickColor(String key) {
    final current = _hexToColor(p[key] as String? ?? '#FFFFFF');
    showDialog(
      context: context,
      builder: (ctx) => _ColorPickerDialog(initialColor: current, onPicked: (color) {
        _update(key, _colorToHex(color));
      }),
    );
  }

  void _pickFont() async {
    final fonts = await _getSystemFonts();
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _FontPickerDialog(fonts: fonts, current: p['font_name'] as String? ?? 'Arial', isZh: widget.isZh),
    );
    if (result != null) _update('font_name', result);
  }

  Future<List<String>> _getSystemFonts() async {
    final fonts = <String>[];
    try {
      final fontDir = Directory('C:\\Windows\\Fonts');
      if (fontDir.existsSync()) {
        for (final f in fontDir.listSync()) {
          if (f is File) {
            final name = f.uri.pathSegments.last;
            if (name.endsWith('.ttf') || name.endsWith('.otf') || name.endsWith('.ttc')) {
              fonts.add(name.replaceAll(RegExp(r'\.[^.]+$'), ''));
            }
          }
        }
      }
    } catch (_) {}
    if (fonts.isEmpty) {
      fonts.addAll(['Arial', 'Microsoft YaHei', 'SimSun', 'SimHei', 'KaiTi', 'FangSong',
          'Times New Roman', 'Consolas', 'Segoe UI', 'Tahoma', 'Verdana', 'Calibri']);
    }
    fonts.sort();
    return fonts.toSet().toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final subs = widget.embeddedSubtitles;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildDropdown(label: zh ? '字幕来源' : 'Source', value: p['source'] as String,
            items: const ['external', 'embedded'],
            itemLabels: zh ? const ['外挂字幕', '内嵌字幕'] : const ['External', 'Embedded'],
            cs: cs, onChanged: (v) {
              p['source'] = v;
              if (v == 'embedded' && subs.isNotEmpty) p['subtitle_index'] = 0;
              setState(() {}); widget.onChanged();
            }),
          const SizedBox(height: 12),

          if (p['source'] == 'external') ...[
            Row(children: [
              Expanded(child: Text(
                (p['subtitle_file'] as String?)?.split(RegExp(r'[/\\]')).last ?? (zh ? '未选择文件' : 'No file selected'),
                style: TextStyle(fontSize: 13, color: cs.onSurface), overflow: TextOverflow.ellipsis,
              )),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(onPressed: _pickSubtitleFile, icon: const Icon(Icons.folder_open, size: 18), label: Text(zh ? '选择' : 'Browse')),
            ]),
            const SizedBox(height: 12),
          ],

          if (p['source'] == 'embedded') ...[
            if (subs.isEmpty)
              Text(zh ? '此视频无内嵌字幕轨道' : 'No embedded subtitle tracks', style: TextStyle(fontSize: 13, color: cs.error))
            else
              _buildDropdown(label: zh ? '字幕轨道' : 'Track', value: '${p['subtitle_index'] ?? 0}',
                items: List.generate(subs.length, (i) => '$i'),
                itemLabels: List.generate(subs.length, (i) {
                  final s = subs[i];
                  if (s is Map) return '#${s['index'] ?? i} [${s['codec'] ?? ''}] ${s['language'] ?? ''}';
                  return '#$i';
                }), cs: cs, onChanged: (v) => _update('subtitle_index', int.tryParse(v) ?? 0)),
            const SizedBox(height: 12),
          ],

          const Divider(),
          const SizedBox(height: 8),
          Text(zh ? '字幕样式' : 'Subtitle Style', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 12),

          // 字体选择
          Row(children: [
            Expanded(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: cs.outline.withAlpha(120)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(p['font_name'] as String? ?? 'Arial', style: TextStyle(fontSize: 13, color: cs.onSurface)),
            )),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(onPressed: _pickFont, icon: const Icon(Icons.font_download, size: 16), label: Text(zh ? '选择字体' : 'Font')),
          ]),
          const SizedBox(height: 8),

          // 字体+字号预览
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              zh ? '字幕预览 Subtitle Preview 123' : 'Subtitle Preview 字幕预览 123',
              style: TextStyle(
                fontFamily: p['font_name'] as String? ?? 'Arial',
                fontSize: (p['font_size'] as int? ?? 24).toDouble() * 0.6,
                color: _hexToColor(p['font_color'] as String? ?? '#FFFFFF'),
                shadows: [
                  Shadow(
                    color: _hexToColor(p['outline_color'] as String? ?? '#000000'),
                    blurRadius: (p['outline_width'] as int? ?? 2).toDouble(),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),

          // 字号
          Row(children: [
            Text('${zh ? "字号" : "Size"}: ${p['font_size']}', style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: (p['font_size'] as int).toDouble(), min: 12, max: 72, divisions: 60, label: '${p['font_size']}',
              onChanged: (v) => _update('font_size', v.round()),
            )),
          ]),
          const SizedBox(height: 12),

          // 描边宽度
          Row(children: [
            Text('${zh ? "描边" : "Outline"}: ${p['outline_width']}', style: TextStyle(fontSize: 13, color: cs.onSurface)),
            Expanded(child: Slider(
              value: (p['outline_width'] as int).toDouble(), min: 0, max: 8, divisions: 8, label: '${p['outline_width']}',
              onChanged: (v) => _update('outline_width', v.round()),
            )),
          ]),
          const SizedBox(height: 12),

          // 字体颜色
          _colorRow(zh ? '字体颜色' : 'Font Color', 'font_color', cs),
          const SizedBox(height: 12),

          // 描边颜色
          _colorRow(zh ? '描边颜色' : 'Outline Color', 'outline_color', cs),
        ]),
      ),
    );
  }

  Widget _colorRow(String label, String key, ColorScheme cs) {
    final hex = p[key] as String? ?? '#FFFFFF';
    return Row(children: [
      Text(label, style: TextStyle(fontSize: 13, color: cs.onSurface)),
      const Spacer(),
      Text(hex, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, fontFamily: 'monospace')),
      const SizedBox(width: 8),
      GestureDetector(
        onTap: () => _pickColor(key),
        child: Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: _hexToColor(hex),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: cs.outline),
          ),
          child: const Icon(Icons.colorize, size: 14, color: Colors.white54),
        ),
      ),
    ]);
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

// ── 拾色器对话框 ──

class _ColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onPicked;
  const _ColorPickerDialog({required this.initialColor, required this.onPicked});
  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late double _hue, _sat, _val;
  late TextEditingController _hexCtrl;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initialColor);
    _hue = hsv.hue; _sat = hsv.saturation; _val = hsv.value;
    _hexCtrl = TextEditingController(text: _currentHex());
  }

  @override
  void dispose() { _hexCtrl.dispose(); super.dispose(); }

  Color get _color => HSVColor.fromAHSV(1, _hue, _sat, _val).toColor();
  String _currentHex() {
    final c = _color;
    return '#${c.red.toRadixString(16).padLeft(2, '0')}${c.green.toRadixString(16).padLeft(2, '0')}${c.blue.toRadixString(16).padLeft(2, '0')}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('选择颜色', style: TextStyle(fontSize: 16, color: cs.onSurface)),
      content: SizedBox(
        width: 280,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // 色相条
          SizedBox(height: 24, child: SliderTheme(
            data: SliderThemeData(trackHeight: 16, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10)),
            child: Slider(
              value: _hue, min: 0, max: 360,
              activeColor: HSVColor.fromAHSV(1, _hue, 1, 1).toColor(),
              onChanged: (v) => setState(() { _hue = v; _hexCtrl.text = _currentHex(); }),
            ),
          )),
          const SizedBox(height: 12),
          Row(children: [
            Text('饱和度', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            Expanded(child: Slider(value: _sat, min: 0, max: 1, activeColor: _color,
              onChanged: (v) => setState(() { _sat = v; _hexCtrl.text = _currentHex(); }))),
          ]),
          Row(children: [
            Text('亮度', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            Expanded(child: Slider(value: _val, min: 0, max: 1, activeColor: _color,
              onChanged: (v) => setState(() { _val = v; _hexCtrl.text = _currentHex(); }))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Container(width: 40, height: 40, decoration: BoxDecoration(
              color: _color, borderRadius: BorderRadius.circular(8), border: Border.all(color: cs.outline),
            )),
            const SizedBox(width: 12),
            Expanded(child: TextField(
              controller: _hexCtrl, decoration: const InputDecoration(isDense: true, labelText: 'HEX',
                border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              onChanged: (v) {
                var hex = v.replaceAll('#', '');
                if (hex.length == 6) {
                  final c = Color(int.tryParse('FF$hex', radix: 16) ?? 0xFFFFFFFF);
                  final hsv = HSVColor.fromColor(c);
                  setState(() { _hue = hsv.hue; _sat = hsv.saturation; _val = hsv.value; });
                }
              },
            )),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () { widget.onPicked(_color); Navigator.pop(context); }, child: const Text('确定')),
      ],
    );
  }
}

// ── 字体选择对话框 ──

class _FontPickerDialog extends StatefulWidget {
  final List<String> fonts;
  final String current;
  final bool isZh;
  const _FontPickerDialog({required this.fonts, required this.current, required this.isZh});
  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  late TextEditingController _searchCtrl;
  late List<String> _filtered;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    _filtered = widget.fonts;
  }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  void _filter(String q) {
    setState(() {
      _filtered = q.isEmpty ? widget.fonts : widget.fonts.where((f) => f.toLowerCase().contains(q.toLowerCase())).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(widget.isZh ? '选择字体' : 'Select Font', style: TextStyle(fontSize: 16, color: cs.onSurface)),
      content: SizedBox(
        width: 320, height: 400,
        child: Column(children: [
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: widget.isZh ? '搜索字体...' : 'Search fonts...',
              prefixIcon: const Icon(Icons.search, size: 18), isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: _filter,
          ),
          const SizedBox(height: 8),
          Expanded(child: ListView.builder(
            itemCount: _filtered.length,
            itemBuilder: (ctx, i) {
              final name = _filtered[i];
              final selected = name == widget.current;
              return ListTile(
                dense: true, visualDensity: VisualDensity.compact,
                selected: selected,
                selectedTileColor: cs.primaryContainer.withAlpha(80),
                title: Text(name, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                subtitle: Text('AaBbCc 你好世界 123', style: TextStyle(fontSize: 12, fontFamily: name, color: cs.onSurfaceVariant)),
                trailing: selected ? Icon(Icons.check, size: 16, color: cs.primary) : null,
                onTap: () => Navigator.pop(context, name),
              );
            },
          )),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(widget.isZh ? '取消' : 'Cancel')),
      ],
    );
  }
}
