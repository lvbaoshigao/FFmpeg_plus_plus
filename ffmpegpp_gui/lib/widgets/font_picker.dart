import 'package:flutter/material.dart';

/// 通用字体选择器 — 点击弹出字体列表对话框
class FontPicker extends StatelessWidget {
  final String currentFont;
  final ValueChanged<String> onSelected;
  final bool showImport;
  final VoidCallback? onImport;
  final String language;

  const FontPicker({
    super.key,
    required this.currentFont,
    required this.onSelected,
    this.showImport = false,
    this.onImport,
    this.language = 'zh',
  });

  // Windows 常见已安装字体
  static const _fonts = [
    ('微软雅黑', 'Microsoft YaHei'), ('黑体', 'SimHei'), ('宋体', 'SimSun'),
    ('楷体', 'KaiTi'), ('仿宋', 'FangSong'), ('微軟正黑體', 'Microsoft JhengHei'),
    ('新細明體', 'MingLiU'), ('新宋体', 'NSimSun'), ('標楷體', 'DFKai-SB'),
    ('华文中宋', 'STZhongsong'), ('华文彩云', 'STCaiyun'), ('华文行楷', 'STXingkai'),
    ('华文细黑', 'STXihei'), ('隶书', 'LiSu'), ('幼圆', 'YouYuan'),
    ('Arial', 'Arial'), ('Arial Black', 'Arial Black'), ('Bahnschrift', 'Bahnschrift'),
    ('Calibri', 'Calibri'), ('Calibri Light', 'Calibri Light'),
    ('Cambria', 'Cambria'), ('Candara', 'Candara'),
    ('Consolas', 'Consolas'), ('Constantia', 'Constantia'),
    ('Corbel', 'Corbel'), ('Courier New', 'Courier New'),
    ('Ebrima', 'Ebrima'), ('Georgia', 'Georgia'),
    ('Impact', 'Impact'), ('Ink Free', 'Ink Free'),
    ('Lucida Console', 'Lucida Console'), ('Malgun Gothic', 'Malgun Gothic'),
    ('MS Gothic', 'MS Gothic'), ('Nirmala UI', 'Nirmala UI'),
    ('Palatino Linotype', 'Palatino Linotype'),
    ('Segoe Print', 'Segoe Print'), ('Segoe Script', 'Segoe Script'),
    ('Segoe UI', 'Segoe UI'), ('Segoe UI Black', 'Segoe UI Black'),
    ('Segoe UI Light', 'Segoe UI Light'), ('Segoe UI Semibold', 'Segoe UI Semibold'),
    ('Sitka', 'Sitka'), ('Sylfaen', 'Sylfaen'), ('Tahoma', 'Tahoma'),
    ('Times New Roman', 'Times New Roman'), ('Trebuchet MS', 'Trebuchet MS'),
    ('Verdana', 'Verdana'),
    ('Yu Gothic', 'Yu Gothic'), ('Yu Gothic UI', 'Yu Gothic UI'),
    ('Noto Sans', 'Noto Sans'), ('Noto Serif', 'Noto Serif'),
    ('Noto Sans CJK SC', 'Noto Sans CJK SC'), ('Noto Serif CJK SC', 'Noto Serif CJK SC'),
    ('Source Han Sans CN', 'Source Han Sans CN'), ('Source Han Serif CN', 'Source Han Serif CN'),
    ('思源黑体', 'Source Han Sans CN'), ('思源宋体', 'Source Han Serif CN'),
    ('Roboto', 'Roboto'), ('Open Sans', 'Open Sans'),
    ('Lato', 'Lato'), ('Montserrat', 'Montserrat'), ('Oswald', 'Oswald'),
    ('Raleway', 'Raleway'), ('Ubuntu', 'Ubuntu'), ('Fira Code', 'Fira Code'),
    ('JetBrains Mono', 'JetBrains Mono'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 找到当前字体的显示名
    String displayName = currentFont;
    for (final (label, family) in _fonts) {
      if (family == currentFont) { displayName = label; break; }
    }

    return InkWell(
      onTap: () => _openPicker(context),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline.withAlpha(120)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Expanded(child: Text(displayName, style: TextStyle(
            fontSize: 13, fontFamily: currentFont, color: scheme.onSurface,
          ))),
          Icon(Icons.arrow_drop_down, size: 20, color: scheme.outline),
          if (showImport && onImport != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onImport,
              child: Icon(Icons.file_open, size: 18, color: scheme.primary),
            ),
          ],
        ]),
      ),
    );
  }

  void _openPicker(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _FontPickerDialog(
        currentFont: currentFont,
        language: language,
        onSelected: (v) {
          onSelected(v);
          Navigator.pop(context);
        },
      ),
    );
  }
}

class _FontPickerDialog extends StatefulWidget {
  final String currentFont;
  final String language;
  final ValueChanged<String> onSelected;
  const _FontPickerDialog({required this.currentFont, required this.language, required this.onSelected});
  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  String _filter = '';
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isZh = widget.language == 'zh';

    final filtered = _filter.isEmpty
        ? FontPicker._fonts
        : FontPicker._fonts.where((f) =>
            f.$1.toLowerCase().contains(_filter.toLowerCase()) ||
            f.$2.toLowerCase().contains(_filter.toLowerCase())).toList();

    return AlertDialog(
      title: Text(isZh ? '选择字体' : 'Select Font', style: TextStyle(fontSize: 16, color: scheme.onSurface)),
      content: SizedBox(width: 320, height: 380, child: Column(children: [
        // 搜索框
        TextField(
          controller: _ctrl,
          autofocus: true,
          style: TextStyle(fontSize: 13, color: scheme.onSurface),
          decoration: InputDecoration(
            isDense: true,
            hintText: isZh ? '搜索字体...' : 'Search fonts...',
            hintStyle: TextStyle(fontSize: 12, color: scheme.outline),
            prefixIcon: Icon(Icons.search, size: 18, color: scheme.outline),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          onChanged: (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: 8),
        // 字体列表
        Expanded(child: ListView.builder(
          itemCount: filtered.length,
          itemBuilder: (_, i) {
            final (label, family) = filtered[i];
            final isSelected = family == widget.currentFont;
            return InkWell(
              onTap: () => widget.onSelected(family),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                color: isSelected ? scheme.primary.withAlpha(30) : null,
                child: Row(children: [
                  Expanded(child: Text(label, style: TextStyle(
                    fontSize: 13,
                    fontFamily: family.isNotEmpty ? family : null,
                    color: scheme.onSurface,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ))),
                  if (family.isNotEmpty && family != label)
                    Text(family, style: TextStyle(fontSize: 10, color: scheme.outline)),
                  if (isSelected)
                    Icon(Icons.check, size: 16, color: scheme.primary),
                ]),
              ),
            );
          },
        )),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: Text(isZh ? '取消' : 'Cancel')),
      ],
    );
  }
}
