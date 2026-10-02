import 'dart:io';
import 'package:flutter/material.dart';
import 'glass_panel.dart';

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

  static List<(String, String)> get _builtinFonts => Platform.isWindows
      ? _windowsFonts
      : Platform.isMacOS
          ? _macFonts
          : _linuxFonts;

  static const _windowsFonts = <(String, String)>[
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

  static const _linuxFonts = <(String, String)>[
    ('Noto Sans CJK SC', 'Noto Sans CJK SC'), ('Noto Serif CJK SC', 'Noto Serif CJK SC'),
    ('Noto Sans CJK TC', 'Noto Sans CJK TC'), ('Noto Serif CJK TC', 'Noto Serif CJK TC'),
    ('思源黑体', 'Source Han Sans CN'), ('思源宋体', 'Source Han Serif CN'),
    ('文泉驿微米黑', 'WenQuanYi Micro Hei'), ('文泉驿等宽微米黑', 'WenQuanYi Micro Hei Mono'),
    ('文泉驿正黑', 'WenQuanYi Zen Hei'),
    ('DejaVu Sans', 'DejaVu Sans'), ('DejaVu Serif', 'DejaVu Serif'), ('DejaVu Sans Mono', 'DejaVu Sans Mono'),
    ('Liberation Sans', 'Liberation Sans'), ('Liberation Serif', 'Liberation Serif'), ('Liberation Mono', 'Liberation Mono'),
    ('Noto Sans', 'Noto Sans'), ('Noto Serif', 'Noto Serif'), ('Noto Mono', 'Noto Mono'),
    ('Ubuntu', 'Ubuntu'), ('Ubuntu Mono', 'Ubuntu Mono'),
    ('Roboto', 'Roboto'), ('Open Sans', 'Open Sans'),
    ('Lato', 'Lato'), ('Montserrat', 'Montserrat'),
    ('Fira Code', 'Fira Code'), ('JetBrains Mono', 'JetBrains Mono'),
    ('Droid Sans Fallback', 'Droid Sans Fallback'),
    ('Arial', 'Arial'), ('Times New Roman', 'Times New Roman'), ('Courier New', 'Courier New'),
  ];

  static const _macFonts = <(String, String)>[
    ('苹方-简', 'PingFang SC'), ('苹方-繁', 'PingFang TC'), ('苹方-港', 'PingFang HK'),
    ('华文黑体', 'STHeiti'), ('华文楷体', 'STKaiti'), ('华文宋体', 'STSong'),
    ('华文仿宋', 'STFangsong'), ('冬青黑体', 'Hiragino Sans GB'),
    ('Noto Sans CJK SC', 'Noto Sans CJK SC'), ('Noto Serif CJK SC', 'Noto Serif CJK SC'),
    ('思源黑体', 'Source Han Sans CN'), ('思源宋体', 'Source Han Serif CN'),
    ('SF Pro', 'SF Pro'), ('SF Mono', 'SF Mono'),
    ('Helvetica Neue', 'Helvetica Neue'), ('Helvetica', 'Helvetica'),
    ('Arial', 'Arial'), ('Georgia', 'Georgia'),
    ('Menlo', 'Menlo'), ('Monaco', 'Monaco'),
    ('Avenir', 'Avenir'), ('Avenir Next', 'Avenir Next'),
    ('Futura', 'Futura'), ('Gill Sans', 'Gill Sans'),
    ('Times New Roman', 'Times New Roman'), ('Courier New', 'Courier New'),
    ('Roboto', 'Roboto'), ('Open Sans', 'Open Sans'),
    ('Fira Code', 'Fira Code'), ('JetBrains Mono', 'JetBrains Mono'),
  ];

  static List<(String, String)>? _cachedFonts;

  /// 正在进行中的枚举 Future。
  /// 启动预热（preloadFonts）与「首次打开选择器」可能几乎同时触发枚举，
  /// 共享同一个 Future 可以避免并发跑两遍 reg query / fc-list / system_profiler。
  static Future<List<(String, String)>>? _loading;

  /// 启动预加载：提前枚举系统字体并缓存，避免首次打开字体选择器时卡顿。
  /// 幂等：已缓存直接返回；枚举进行中则复用同一个 Future。
  static Future<List<(String, String)>> preloadFonts() => _getAllFonts();

  static Future<List<(String, String)>> _getAllFonts() {
    final cached = _cachedFonts;
    if (cached != null) return Future.value(cached);
    // whenComplete 里清空在途标记：枚举失败后允许下次重试，
    // 否则一次异常会把后续所有调用都钉死在同一个失败的 Future 上。
    return _loading ??= _enumerateFonts().then((fonts) {
      _cachedFonts = fonts;
      return fonts;
    }).whenComplete(() => _loading = null);
  }

  static Future<List<(String, String)>> _enumerateFonts() async {
    final builtinFamilies = <String>{for (final (_, f) in _builtinFonts) f};
    final merged = <(String, String)>[..._builtinFonts];

    if (Platform.isWindows) {
      try {
        final result = await Process.run('reg', [
          'query',
          r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
        ]);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().split('\n');
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || trimmed.startsWith('HKEY_')) continue;
            final regMatch = RegExp(r'^(.+?)\s+REG_SZ\s+').firstMatch(trimmed);
            if (regMatch == null) continue;
            var displayName = regMatch.group(1)!.trim();
            displayName = displayName
                .replaceAll(RegExp(r'\s*\(TrueType\)', caseSensitive: false), '')
                .replaceAll(RegExp(r'\s*\(OpenType\)', caseSensitive: false), '')
                .replaceAll(RegExp(r'\s*\(TrueType Collection\)', caseSensitive: false), '')
                .trim();
            if (displayName.isEmpty) continue;
            if (!builtinFamilies.contains(displayName)) {
              builtinFamilies.add(displayName);
              merged.add((displayName, displayName));
            }
          }
        }
      } catch (_) {}
    } else if (Platform.isMacOS) {
      // macOS 没有 fc-list，用 system_profiler 枚举字体族
      try {
        final result = await Process.run('system_profiler', ['SPFontsDataType']);
        if (result.exitCode == 0) {
          final families = RegExp(r'Family:\s+(.+)')
              .allMatches(result.stdout.toString())
              .map((m) => m.group(1)!.trim())
              .where((s) => s.isNotEmpty);
          for (final family in families) {
            if (!builtinFamilies.contains(family)) {
              builtinFamilies.add(family);
              merged.add((family, family));
            }
          }
        }
      } catch (_) {}
      // 兜底：扫描系统字体目录
      try {
        for (final dirPath in ['/System/Library/Fonts', '/Library/Fonts']) {
          final dir = Directory(dirPath);
          if (!dir.existsSync()) continue;
          await for (final f in dir.list(recursive: true)) {
            if (f is! File) continue;
            if (!f.path.endsWith('.ttf') && !f.path.endsWith('.otf') && !f.path.endsWith('.ttc')) continue;
            final name = f.path.split('/').last
                .replaceAll(RegExp(r'\.[^.]+$'), '')
                .replaceAll(RegExp(r'\s+'), ' ');
            if (name.isNotEmpty && !builtinFamilies.contains(name)) {
              builtinFamilies.add(name);
              merged.add((name, name));
            }
          }
        }
      } catch (_) {}
    } else {
      // Linux: 使用 fc-list 枚举字体
      try {
        final result = await Process.run('fc-list', [':lang=zh', 'family']);
        if (result.exitCode == 0) {
          for (final line in result.stdout.toString().split('\n')) {
            final families = line.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
            for (final family in families) {
              if (!builtinFamilies.contains(family)) {
                builtinFamilies.add(family);
                merged.add((family, family));
              }
            }
          }
        }
        // 也获取非中文字体
        final result2 = await Process.run('fc-list', ['family']);
        if (result2.exitCode == 0) {
          for (final line in result2.stdout.toString().split('\n')) {
            final families = line.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
            for (final family in families) {
              if (!builtinFamilies.contains(family)) {
                builtinFamilies.add(family);
                merged.add((family, family));
              }
            }
          }
        }
      } catch (_) {}
    }

    merged.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    return merged;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String displayName = currentFont;
    for (final (label, family) in _builtinFonts) {
      if (family == currentFont) { displayName = label; break; }
    }

    return InkWell(
      onTap: () => _openPicker(context),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          // 与全局主题化输入框/下拉框一致：圆角 10 + 填充底色
          color: scheme.surfaceContainerHighest.withAlpha(90),
          border: Border.all(color: scheme.outlineVariant.withAlpha(160)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          // 长字体名（Source Han Serif CN / Palatino Linotype…）在字号调大时会
          // 折成两行，触发框被撑高、文字与右侧图标不再垂直居中对齐
          // （用户反馈的「字体与选择框不对称」）。这里固定单行 + 省略号。
          Expanded(child: Text(displayName,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
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
  List<(String, String)>? _fonts;
  bool _loading = true;
  // 枚举失败标记：用于给出「可重试」的失败态，而不是永久转圈或谎报无匹配
  bool _failed = false;
  // 悬停预览：鼠标停留的字体（null=未悬停，回退显示当前选中字体）
  String? _hoverFamily;

  /// 过滤结果缓存：只在字体列表或搜索词变化时重算一次。
  /// 之前是在 build 里现算，于是每次重建（包括鼠标在列表上移动触发的
  /// setState）都要对全量系统字体跑一遍 contains 并生成新 List。
  List<(String, String)> _filtered = const [];

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
    _loadFonts();
  }

  /// 触发一次字体枚举。失败时 FontPicker 不写缓存、并清掉在途标记，
  /// 所以「重试」能真正重跑一遍枚举。
  void _loadFonts() {
    FontPicker._getAllFonts().then((fonts) {
      if (!mounted) return;
      setState(() {
        _fonts = fonts;
        _failed = false;
        _loading = false;
        _applyFilter();
      });
    }, onError: (Object _) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
        _applyFilter();
      });
    });
  }

  /// 重算过滤结果（字体列表或 _filter 变化时调用一次）。
  void _applyFilter() {
    final all = _fonts ?? FontPicker._builtinFonts;
    final keyword = _filter.trim().toLowerCase();
    _filtered = keyword.isEmpty
        ? all
        : all
            .where((f) =>
                f.$1.toLowerCase().contains(keyword) ||
                f.$2.toLowerCase().contains(keyword))
            .toList(growable: false);
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

    final allFonts = _fonts ?? FontPicker._builtinFonts;
    // 过滤结果走缓存（见 _applyFilter）：build 只取值，不重跑全量筛选。
    final filtered = _filtered;

    // 预览条字体：优先悬停项，其次当前选中项
    final previewFamily = _hoverFamily ?? widget.currentFont;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GlassPanel(
        radius: 20,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 标题行：标题 + 字体数量徽标 + 关闭按钮
          Row(children: [
            Expanded(child: Text(isZh ? '选择字体' : 'Select Font',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface))),
            if (!_loading)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withAlpha(24),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('${allFonts.length}',
                    style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(width: 6),
            InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 18, color: scheme.outline),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          // 搜索框：主题化圆角填充样式
          TextField(
            controller: _ctrl,
            autofocus: true,
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
            decoration: InputDecoration(
              isDense: true,
              hintText: isZh ? '搜索字体...' : 'Search fonts...',
              hintStyle: TextStyle(fontSize: 12, color: scheme.outline),
              prefixIcon: Icon(Icons.search, size: 18, color: scheme.outline),
              suffixIcon: _filter.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(Icons.close, size: 16, color: scheme.outline),
                      onPressed: () {
                        _ctrl.clear();
                        setState(() { _filter = ''; _applyFilter(); });
                      },
                    ),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withAlpha(90),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: scheme.outlineVariant, width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(160), width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: scheme.primary, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            onChanged: (v) => setState(() { _filter = v; _applyFilter(); }),
          ),
          const SizedBox(height: 8),
          // 字体列表
          if (_loading)
            const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()))
          else if (_failed)
            // 枚举失败：给出可重试的失败态（既不永久转圈，也不谎报「无匹配字体」）
            SizedBox(height: 240, child: Center(child: Column(
                mainAxisSize: MainAxisSize.min, children: [
              Text(isZh ? '字体列表读取失败' : 'Failed to read the font list',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () {
                  setState(() { _loading = true; _failed = false; });
                  _loadFonts();
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(isZh ? '重试' : 'Retry'),
              ),
            ])))
          else if (filtered.isEmpty)
            SizedBox(height: 240, child: Center(child: Text(
                isZh ? '未找到匹配字体' : 'No matching fonts',
                style: TextStyle(fontSize: 12, color: scheme.outline))))
          else
            SizedBox(height: 240, child: ListView.builder(
              itemCount: filtered.length,
              // 列表项高度压缩：只占一行、更紧凑
              itemExtent: 34,
              itemBuilder: (_, i) {
                final (label, family) = filtered[i];
                final isSelected = family == widget.currentFont;
                final isHover = family == _hoverFamily;
                return MouseRegion(
                  // 只有悬停项真的变了才 setState：同一行的重复进入/离开
                  // 不该重建整个对话框（含搜索框和列表）
                  onEnter: (_) {
                    if (_hoverFamily != family) setState(() => _hoverFamily = family);
                  },
                  onExit: (_) {
                    if (_hoverFamily != null) setState(() => _hoverFamily = null);
                  },
                  child: InkWell(
                    onTap: () => widget.onSelected(family),
                    // 右键：放大预览
                    onSecondaryTap: () => _showFontPreview(context, label, family),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? scheme.primary.withAlpha(30)
                            : (isHover ? scheme.surfaceContainerHighest.withAlpha(120) : null),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(children: [
                        Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(
                          fontSize: 13,
                          // 列表项不加载字体（避免打开瞬间卡顿）；仅选中项用字体样式预览
                          fontFamily: isSelected && family.isNotEmpty ? family : null,
                          color: scheme.onSurface,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        ))),
                        if (family.isNotEmpty && family != label)
                          Flexible(child: Text(family, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10, color: scheme.outline))),
                        if (isSelected)
                          Icon(Icons.check_circle, size: 16, color: scheme.primary),
                      ]),
                    ),
                  ),
                );
              },
            )),
          const SizedBox(height: 10),
          // 实时预览条：悬停/选中的字体真实渲染
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(110),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant.withAlpha(90)),
            ),
            child: Row(children: [
              Expanded(child: Text('字体预览 Font Preview 123',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 17,
                      fontFamily: previewFamily.isNotEmpty ? previewFamily : null,
                      color: scheme.onSurface))),
              const SizedBox(width: 8),
              Icon(Icons.text_fields, size: 16, color: scheme.outline),
            ]),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Text(isZh ? '右键字体可放大预览' : 'Right-click a font to preview',
                style: TextStyle(fontSize: 10, color: scheme.outline)),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(context),
                child: Text(isZh ? '取消' : 'Cancel')),
          ]),
        ]),
      ),
    );
  }

  /// 右键字体：用该字体的真实样式渲染一段示例文字（其他字体不变）。
  void _showFontPreview(BuildContext context, String label, String family) {
    final scheme = Theme.of(context).colorScheme;
    final isZh = widget.language == 'zh';
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassPanel(
          radius: 18,
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
            const SizedBox(height: 14),
            // 用该字体真实渲染预览文字
            Container(
              width: 320,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withAlpha(90),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('字体预览 Font Preview',
                    style: TextStyle(fontSize: 24, fontFamily: family.isNotEmpty ? family : null, color: scheme.onSurface)),
                const SizedBox(height: 10),
                Text('ABCDEFG abcdefg 0123456789\n汉字测试：液态玻璃果冻效果',
                    style: TextStyle(fontSize: 15, height: 1.6, fontFamily: family.isNotEmpty ? family : null, color: scheme.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx),
                  child: Text(isZh ? '关闭' : 'Close')),
            ]),
          ]),
        ),
      ),
    );
  }
}
