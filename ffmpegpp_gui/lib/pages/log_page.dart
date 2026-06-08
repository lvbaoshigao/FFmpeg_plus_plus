import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});
  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final Set<int> _selectedIndices = {};
  String _filter = 'all';

  static const _filters = ['all', 'info', 'ffmpeg', 'progress', 'error'];
  static const _filterLabels = {'all': '全部', 'info': '信息', 'ffmpeg': 'FFmpeg', 'progress': '进度', 'error': '错误'};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = context.watch<AppState>().config;
    final entries = context.watch<AppState>().logEntries;
    final glass = cfg.glassEffect;
    final filtered = _filter == 'all' ? entries : entries.where((e) => e.category == _filter).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(children: [
        _toolbar(scheme, cfg, entries, filtered),
        _filterBar(scheme, cfg),
        Expanded(child: filtered.isEmpty
            ? Center(child: Text(cfg.language == 'zh' ? '暂无日志' : 'No logs yet',
                style: TextStyle(color: scheme.outline, fontSize: 13)))
            : _buildList(filtered, scheme, glass, cfg)),
      ]),
    );
  }

  Widget _toolbar(ColorScheme scheme, AppConfig cfg, List<LogEntry> entries, List<LogEntry> filtered) {
    final hasSelection = _selectedIndices.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(children: [
        Text(cfg.language == 'zh' ? '日志' : 'Logs', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: scheme.onSurface)),
        const SizedBox(width: 12),
        Text('${filtered.length} ${cfg.language == 'zh' ? '条' : 'entries'}', style: TextStyle(fontSize: 11, color: scheme.outline)),
        if (hasSelection) ...[
          const SizedBox(width: 8),
          Text('已选 ${_selectedIndices.length} 条', style: TextStyle(fontSize: 11, color: scheme.primary)),
        ],
        const Spacer(),
        if (hasSelection) IconButton(
          icon: const Icon(Icons.copy, size: 18), tooltip: '复制选中',
          onPressed: () {
            final selected = _selectedIndices.where((i) => i < filtered.length).map((i) => _fmt(filtered[i])).join('\n');
            Clipboard.setData(ClipboardData(text: selected));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已复制 ${_selectedIndices.length} 条'), duration: const Duration(seconds: 2)));
          },
        ),
        IconButton(
          icon: const Icon(Icons.copy_all, size: 18), tooltip: '复制全部',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: filtered.map(_fmt).join('\n')));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已复制全部 ${filtered.length} 条'), duration: const Duration(seconds: 2)));
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18), tooltip: '清空',
          onPressed: () { setState(() => _selectedIndices.clear()); context.read<AppState>().clearLogs(); },
        ),
      ]),
    );
  }

  Widget _filterBar(ColorScheme scheme, AppConfig cfg) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: _filters.map((f) {
        final sel = _filter == f;
        return Padding(padding: const EdgeInsets.only(right: 6), child: FilterChip(
          label: Text(_filterLabels[f] ?? f, style: TextStyle(fontSize: 11, color: sel ? scheme.onPrimaryContainer : scheme.onSurface)),
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

  Widget _buildList(List<LogEntry> filtered, ColorScheme scheme, bool glass, AppConfig cfg) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final entry = filtered[i];
        final selected = _selectedIndices.contains(i);
        final catColor = _catColor(entry.category, scheme);

        // 主题色蒙版
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
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)));
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
              border: selected ? Border.all(color: scheme.primary.withAlpha(100), width: 1) : null,
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 5, right: 8),
                  decoration: BoxDecoration(color: catColor, shape: BoxShape.circle)),
              Text(_ts(entry.timestamp), style: TextStyle(fontSize: 10, fontFamily: 'Consolas', color: scheme.outline)),
              const SizedBox(width: 8),
              Expanded(child: Text(entry.message, style: TextStyle(fontSize: 11, fontFamily: 'Consolas',
                  color: entry.category == 'error' ? scheme.error : scheme.onSurface))),
            ]),
          ),
        );

        // 3D 效果：高斯模糊 + 玻璃质感
        if (glass) {
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
        }

        return Padding(padding: const EdgeInsets.only(bottom: 2), child: row);
      },
    );
  }

  String _fmt(LogEntry e) => '[${_ts(e.timestamp)}] ${e.message}';
  String _ts(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  Color _catColor(String cat, ColorScheme scheme) => switch (cat) {
    'info' => scheme.primary, 'ffmpeg' => Colors.teal, 'progress' => Colors.blue, 'error' => scheme.error, _ => scheme.outline,
  };
}
