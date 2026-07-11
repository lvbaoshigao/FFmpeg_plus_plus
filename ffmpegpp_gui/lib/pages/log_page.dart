import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../widgets/toast.dart';
import '../widgets/glass_panel.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});
  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final Set<int> _selectedIndices = {};
  String _filter = 'all';

  static const _filters = ['all', 'info', 'ffmpeg', 'progress', 'error'];

  String _filterLabel(String f, bool isZh) => switch (f) {
    'all'      => isZh ? '全部' : 'All',
    'info'     => isZh ? '信息' : 'Info',
    'ffmpeg'   => 'FFmpeg',
    'progress' => isZh ? '进度' : 'Progress',
    'error'    => isZh ? '错误' : 'Error',
    _          => f,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = context.watch<AppState>().config;
    final entries = context.watch<AppState>().logEntries;
    final isZh = cfg.language == 'zh';
    final filtered = _filter == 'all' ? entries : entries.where((e) => e.category == _filter).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        _toolbar(scheme, cfg, entries, filtered, isZh),
        _filterBar(scheme, isZh),
        Expanded(child: filtered.isEmpty
            ? Center(child: Text(isZh ? '暂无日志' : 'No logs yet',
                style: TextStyle(color: scheme.outline, fontSize: 13)))
            : _buildList(filtered, scheme, cfg, isZh)),
      ]),
    );
  }

  Widget _toolbar(ColorScheme scheme, AppConfig cfg, List<LogEntry> entries, List<LogEntry> filtered, bool isZh) {
    final hasSelection = _selectedIndices.isNotEmpty;
    return GlassTopBar(
      title: Row(children: [
        Text(isZh ? '日志' : 'Logs', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface)),
        const SizedBox(width: 12),
        Text('${filtered.length} ${isZh ? '条' : 'entries'}', style: TextStyle(fontSize: 11, color: scheme.outline)),
        if (hasSelection) ...[
          const SizedBox(width: 8),
          Text('${isZh ? '已选' : 'Selected'} ${_selectedIndices.length}', style: TextStyle(fontSize: 11, color: scheme.primary)),
        ],
      ]),
      actions: [
        if (hasSelection) IconButton(
          icon: const Icon(Icons.copy, size: 18), tooltip: isZh ? '复制选中' : 'Copy selected',
          onPressed: () {
            final selected = _selectedIndices.where((i) => i < filtered.length).map((i) => _fmt(filtered[i])).join('\n');
            Clipboard.setData(ClipboardData(text: selected));
            showToast(context, isZh ? '已复制 ${_selectedIndices.length} 条' : 'Copied ${_selectedIndices.length} entries');
          },
        ),
        IconButton(
          icon: const Icon(Icons.copy_all, size: 18), tooltip: isZh ? '复制全部' : 'Copy all',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: filtered.map(_fmt).join('\n')));
            showToast(context, isZh ? '已复制全部 ${filtered.length} 条' : 'Copied all ${filtered.length} entries');
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18), tooltip: isZh ? '清空' : 'Clear',
          onPressed: () { setState(() => _selectedIndices.clear()); context.read<AppState>().clearLogs(); },
        ),
      ],
    );
  }

  Widget _filterBar(ColorScheme scheme, bool isZh) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: _filters.map((f) {
        final sel = _filter == f;
        return Padding(padding: const EdgeInsets.only(right: 6), child: FilterChip(
          label: Text(_filterLabel(f, isZh), style: TextStyle(fontSize: 11, color: sel ? scheme.onPrimaryContainer : scheme.onSurface)),
          selected: sel,
          onSelected: (v) => setState(() => _filter = f),
          selectedColor: scheme.primaryContainer,
          backgroundColor: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          visualDensity: VisualDensity.compact,
          showCheckmark: false,
        ));
      }).toList())),
    );
  }

  Widget _buildList(List<LogEntry> filtered, ColorScheme scheme, AppConfig cfg, bool isZh) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final entry = filtered[i];
        final selected = _selectedIndices.contains(i);
        final catColor = _catColor(entry.category, scheme);

        final bgColor = selected
            ? scheme.primaryContainer.withAlpha(100)
            : scheme.primary.withAlpha(12);

        Widget row = GestureDetector(
          onTap: () => setState(() {
            if (_selectedIndices.contains(i)) { _selectedIndices.remove(i); }
            else { _selectedIndices.add(i); }
          }),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: _fmt(entry)));
            showToast(context, isZh ? '已复制' : 'Copied');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
              border: selected ? Border.all(color: scheme.primary.withAlpha(100), width: 1) : null,
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 5, right: 6),
                  decoration: BoxDecoration(color: catColor, shape: BoxShape.circle)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(color: catColor.withAlpha(30), borderRadius: BorderRadius.circular(3)),
                child: Text(entry.category.toUpperCase(), style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: catColor)),
              ),
              Text(_ts(entry.timestamp), style: TextStyle(fontSize: 10, fontFamily: Platform.isWindows ? 'Consolas' : 'monospace', color: scheme.outline)),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(entry.message, style: TextStyle(fontSize: 11, fontFamily: Platform.isWindows ? 'Consolas' : 'monospace',
                  color: entry.category == 'error' ? scheme.error : scheme.onSurface))),
            ]),
          ),
        );

        row = ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surface.withAlpha(60),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: scheme.outlineVariant.withAlpha(30), width: 0.5),
              ),
              child: row,
            ),
          ),
        );

        return Padding(padding: const EdgeInsets.only(bottom: 2), child: row);
      },
    );
  }

  String _fmt(LogEntry e) => '[${_ts(e.timestamp)}] [${e.category.toUpperCase()}] ${e.message}';
  String _ts(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
  Color _catColor(String cat, ColorScheme scheme) => switch (cat) {
    'info' => scheme.primary, 'ffmpeg' => Colors.teal, 'progress' => Colors.blue, 'error' => scheme.error, _ => scheme.outline,
  };
}
