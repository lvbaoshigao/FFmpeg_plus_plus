import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../platform/app_platform.dart';
import '../providers/app_state.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/toast.dart';
import '../widgets/wallpaper_background.dart';
import '../widgets/window_chrome.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key, this.embedded = false});

  /// Whether the app shell already provides the wallpaper and window chrome.
  final bool embedded;

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  static const _filters = [
    'all',
    'info',
    'ffmpeg',
    'progress',
    'error',
    'trace',
  ];
  // Mobile pills are 40 dp tall plus 8 dp of margin on each side.
  static const double _filterBarExtent = 56;

  final Set<LogEntry> _selected = {};
  String _filter = 'all';

  String _filterLabel(String filter, bool zh) =>
      filter == 'all' ? (zh ? '全部' : 'All') : _categoryLabel(filter, zh);

  String _categoryLabel(String category, bool zh) => switch (category) {
    'info' => zh ? '信息' : 'Info',
    'progress' => zh ? '进度' : 'Progress',
    'error' => zh ? '错误' : 'Error',
    'ffmpeg' => 'FFmpeg',
    'audit' => zh ? '审计' : 'Audit',
    'warn' => zh ? '警告' : 'Warning',
    'trace' => zh ? '探针' : 'Trace',
    _ => zh ? '一般' : 'General',
  };

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, (int, String, String)>(
      selector: (_, state) =>
          (state.logVersion, state.config.language, state.config.cardStyle),
      builder: (context, key, _) {
        final (_, language, cardStyle) = key;
        final entries = context.read<AppState>().logEntries;
        final scheme = Theme.of(context).colorScheme;
        final zh = language == 'zh';
        final filtered = _filter == 'all'
            ? entries
            : entries.where((entry) => entry.category == _filter).toList();
        // The bounded log can evict old rows while users are selecting them.
        // Track entries by identity so eviction never selects a different row.
        final selection = _selected.isEmpty
            ? const <LogEntry>[]
            : filtered.where(_selected.contains).toList(growable: false);
        _selected.retainAll(selection);

        final toolbar = _toolbar(scheme, filtered, selection, zh);
        final filters = _filterBar(scheme, zh);
        final Widget list = filtered.isEmpty
            ? Center(
                child: Text(
                  _filter == 'trace'
                      ? (zh ? '暂无探针日志' : 'No trace entries yet')
                      : (zh ? '暂无日志' : 'No logs yet'),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              )
            : _buildList(
                filtered,
                scheme,
                cardStyle,
                zh,
                topInset: isMobilePlatform
                    ? ImmersiveTopBar.insetOf(context) + _filterBarExtent
                    : 0,
              );
        final content = Scaffold(
          backgroundColor: Colors.transparent,
          body: isMobilePlatform
              ? ImmersiveTopBar(
                  bar: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [toolbar, filters],
                  ),
                  child: list,
                )
              : Column(
                  children: [
                    toolbar,
                    filters,
                    Expanded(child: list),
                  ],
                ),
        );
        if (widget.embedded) return content;
        return withWallpaper(context, WindowChrome(child: content));
      },
    );
  }

  Widget _toolbar(
    ColorScheme scheme,
    List<LogEntry> filtered,
    List<LogEntry> selection,
    bool zh,
  ) {
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Text(
          zh ? '日志' : 'Logs',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        Flexible(
          child: Text(
            '${filtered.length} ${zh ? '条' : 'entries'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        if (selection.isNotEmpty)
          Flexible(
            child: Text(
              '${zh ? '已选' : 'Selected'} ${selection.length}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: scheme.primary),
            ),
          ),
      ],
    );
    final actions =
        <({IconData icon, String label, Color color, VoidCallback run})>[
          if (selection.isNotEmpty)
            (
              icon: Icons.copy,
              label: zh ? '复制选中' : 'Copy selected',
              color: scheme.onSurface,
              run: () => _copyEntries(selection, zh),
            ),
          (
            icon: Icons.copy_all,
            label: zh ? '复制全部' : 'Copy all',
            color: scheme.onSurface,
            run: () => _copyEntries(filtered, zh),
          ),
          (
            icon: Icons.delete_outline,
            label: zh ? '清空' : 'Clear',
            color: scheme.error,
            run: () {
              setState(_selected.clear);
              context.read<AppState>().clearLogs();
            },
          ),
        ];
    if (isMobilePlatform) {
      return MobileSubPageTopBar(
        title: title,
        actions: [
          for (final action in actions)
            MobileGlassPillAction(
              icon: action.icon,
              tooltip: action.label,
              color: action.color,
              onTap: action.run,
            ),
        ],
        onBack: () => Navigator.of(context).maybePop(),
      );
    }
    return GlassTopBar(
      title: title,
      actions: [
        for (final action in actions)
          IconButton(
            icon: Icon(action.icon, size: 18),
            tooltip: action.label,
            onPressed: action.run,
          ),
      ],
    );
  }

  void _copyEntries(List<LogEntry> entries, bool zh) {
    Clipboard.setData(
      ClipboardData(text: entries.map(_formatEntry).join('\n')),
    );
    showToast(
      context,
      zh ? '已复制 ${entries.length} 条' : 'Copied ${entries.length} entries',
    );
  }

  void _selectFilter(String category) => setState(() {
    _filter = category;
    _selected.clear();
  });

  Widget _filterBar(ColorScheme scheme, bool zh) {
    if (isMobilePlatform) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = MediaQuery.textScalerOf(context).scale(13) * 5.5;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(
                constraints.maxWidth,
                tabWidth * _filters.length + 2 * MobileUi.subPagePaddingH,
              ),
              child: MobileSegmentedPills(
                tabs: [
                  for (final filter in _filters)
                    MobilePillTab(_filterLabel(filter, zh)),
                ],
                selectedIndex: _filters.indexOf(_filter),
                onSelected: (i) => _selectFilter(_filters[i]),
                margin: const EdgeInsets.fromLTRB(
                  MobileUi.subPagePaddingH,
                  8,
                  MobileUi.subPagePaddingH,
                  8,
                ),
              ),
            ),
          );
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: 6,
          children: [
            for (final filter in _filters)
              FilterChip(
                label: Text(_filterLabel(filter, zh)),
                labelStyle: TextStyle(
                  fontSize: 11,
                  color: _filter == filter
                      ? scheme.onPrimaryContainer
                      : scheme.onSurface,
                ),
                selected: _filter == filter,
                onSelected: (_) => _selectFilter(filter),
                selectedColor: scheme.primaryContainer,
                backgroundColor: scheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    List<LogEntry> entries,
    ColorScheme scheme,
    String cardStyle,
    bool zh, {
    required double topInset,
  }) => isMobilePlatform
      ? _buildMobileList(entries, scheme, zh, topInset: topInset)
      : _buildDesktopList(entries, scheme, cardStyle, zh, topInset: topInset);

  /// 移动端日志列表：每条一张独立的小卡片，两行排版 ——
  /// 第一行「分类 · 时间」，第二行消息占满整宽（原先三列挤在一行，
  /// 手机上消息只剩一半宽度、长路径被拆成很多行）。
  /// 不再把整个列表包进一块铺满全屏、顶到顶栏后面的玻璃面板；
  /// 选中态用中性描边，不混入主题色。
  Widget _buildMobileList(
    List<LogEntry> entries,
    ColorScheme scheme,
    bool zh, {
    required double topInset,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    final bottom = MediaQuery.paddingOf(context).bottom + 16;
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        MobileUi.subPagePaddingH,
        topInset + 4,
        MobileUi.subPagePaddingH,
        bottom,
      ),
      itemCount: entries.length,
      itemBuilder: (_, index) {
        final entry = entries[index];
        final selected = _selected.contains(entry);
        final categoryColor = _categoryColor(entry.category, scheme);
        final surface = dark
            ? const Color(0xFF1A1A1A).withValues(alpha: selected ? 0.86 : 0.72)
            : const Color(0xFFFAFAFA).withValues(alpha: selected ? 0.92 : 0.80);
        return Padding(
          key: ObjectKey(entry),
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: scheme.onSurface.withValues(
                  alpha: selected ? 0.45 : 0.08,
                ),
                width: selected ? 1.2 : 0.7,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() {
                if (!_selected.add(entry)) _selected.remove(entry);
              }),
              onLongPress: () => _copyEntries([entry], zh),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      spacing: 8,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: categoryColor.withAlpha(36),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              _categoryLabel(entry.category, zh),
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: categoryColor,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            _timestamp(entry.timestamp),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: AppTheme.monoFont,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: scheme.onSurface,
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      entry.message,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        fontFamily: AppTheme.monoFont,
                        color: entry.category == 'error'
                            ? scheme.error
                            : scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDesktopList(
    List<LogEntry> entries,
    ColorScheme scheme,
    String cardStyle,
    bool zh, {
    required double topInset,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: GlassPanel(
      style: cardStyle,
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(12, topInset + 4, 12, 4),
        itemCount: entries.length,
        itemBuilder: (_, index) {
          final entry = entries[index];
          final selected = _selected.contains(entry);
          final categoryColor = _categoryColor(entry.category, scheme);
          return Padding(
            key: ObjectKey(entry),
            padding: const EdgeInsets.only(bottom: 2),
            child: GestureDetector(
              onTap: () => setState(() {
                if (!_selected.add(entry)) _selected.remove(entry);
              }),
              onLongPress: () => _copyEntries([entry], zh),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primaryContainer.withAlpha(100)
                      : scheme.surface.withAlpha(75),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: selected
                        ? scheme.primary.withAlpha(100)
                        : scheme.outlineVariant.withAlpha(30),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: categoryColor.withAlpha(30),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          child: Text(
                            _categoryLabel(entry.category, zh),
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: categoryColor,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        _timestamp(entry.timestamp),
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: AppTheme.monoFont,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          entry.message,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: AppTheme.monoFont,
                            color: entry.category == 'error'
                                ? scheme.error
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  String _formatEntry(LogEntry entry) =>
      '[${_timestamp(entry.timestamp)}] [${entry.category.toUpperCase()}] ${entry.message}';

  String _timestamp(DateTime time) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final millis = time.millisecond.toString().padLeft(3, '0');
    return '${twoDigits(time.hour)}:${twoDigits(time.minute)}:${twoDigits(time.second)}.$millis';
  }

  Color _categoryColor(String category, ColorScheme scheme) =>
      switch (category) {
        'info' => scheme.sem.info,
        'progress' => scheme.sem.success,
        'ffmpeg' => scheme.tertiary,
        'error' => scheme.sem.danger,
        'trace' => scheme.onSecondaryContainer,
        _ => scheme.sem.neutral,
      };
}
