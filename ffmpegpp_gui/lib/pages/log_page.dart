import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../widgets/toast.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_top_bar.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/wallpaper_background.dart';
import '../platform/app_platform.dart';

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

  /// 日志类别徽标的本地化展示（原先直接 toUpperCase 显示英文，
  /// 中文界面下残留 INFO/PROGRESS/AUDIT 等）。
  String _catLabel(String cat, bool isZh) => switch (cat) {
    'info'     => isZh ? '信息' : 'Info',
    'progress' => isZh ? '进度' : 'Progress',
    'error'    => isZh ? '错误' : 'Error',
    'ffmpeg'   => 'FFmpeg',
    'audit'    => isZh ? '审计' : 'Audit',
    _          => isZh ? '一般' : 'General',
  };

  @override
  Widget build(BuildContext context) {
    // 只用 Selector 订阅日志版本号：进度心跳/任务更新等无关通知不再重建本页。
    // （原实现两次 context.watch<AppState>() 会订阅整个 AppState，且 logEntries
    //  getter 每次读取都分配一个包装列表；现改为单次 Selector + 过滤结果缓存。）
    return Selector<AppState, (int, String)>(
      selector: (_, s) => (s.logVersion, s.config.language),
      builder: (context, key, _) {
        final (_, language) = key;
        final state = context.read<AppState>();
        final scheme = Theme.of(context).colorScheme;
        final cfg = state.config;
        final entries = state.logEntries;
        final isZh = language == 'zh';
        final filtered = _filter == 'all' ? entries : entries.where((e) => e.category == _filter).toList();

        // 日志页是通过 Navigator.push 推到根 Navigator 的新路由，不在 _buildRootStack
        // 的壁纸 Stack 里。统一交给 withWallpaper 铺「主题底色 + 壁纸 + 遮罩」，
        // 与其它二级页保持一致（内部只细粒度 select 壁纸路径/透明度）。
        return withWallpaper(context, Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(children: [
            _toolbar(scheme, cfg, entries, filtered, isZh),
            _filterBar(scheme, isZh),
            Expanded(child: filtered.isEmpty
                ? Center(child: Text(isZh ? '暂无日志' : 'No logs yet',
                    style: TextStyle(color: scheme.outline, fontSize: 13)))
                : _buildList(filtered, scheme, cfg, isZh)),
          ]),
        ));
      },
    );
  }

  Widget _toolbar(ColorScheme scheme, AppConfig cfg, List<LogEntry> entries, List<LogEntry> filtered, bool isZh) {
    final hasSelection = _selectedIndices.isNotEmpty;
    final titleRow = Row(mainAxisSize: MainAxisSize.min, children: [
      // 顶栏高度固定：标题单行省略，字号调大时不再折成两行顶出顶栏
      Text(isZh ? '日志' : 'Logs', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface)),
      const SizedBox(width: 12),
      // 变长文本用 Flexible + 省略号：标题药丸右侧还有操作药丸，宽度有限，
      // 条数/多选计数较长时不能溢出（顶栏整体 maxLines:1 + ellipsis 收尾）。
      Flexible(child: Text('${filtered.length} ${isZh ? '条' : 'entries'}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: scheme.outline))),
      if (hasSelection) ...[
        const SizedBox(width: 8),
        Flexible(child: Text('${isZh ? '已选' : 'Selected'} ${_selectedIndices.length}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.primary))),
      ],
    ]);
    final actionWidgets = <Widget>[
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
    ];

    if (isMobilePlatform) {
      // 操作药丸内统一用 34×34 紧凑圆形按钮（MobileGlassPillAction），
      // 不再用自带 48×48 最小尺寸、会撑高药丸的 Material IconButton。
      final mobileActions = <Widget>[
        if (hasSelection)
          MobileGlassPillAction(
            icon: Icons.copy, tooltip: isZh ? '复制选中' : 'Copy selected',
            color: scheme.onSurface, onTap: () {
              final selected = _selectedIndices.where((i) => i < filtered.length).map((i) => _fmt(filtered[i])).join('\n');
              Clipboard.setData(ClipboardData(text: selected));
              showToast(context, isZh ? '已复制 ${_selectedIndices.length} 条' : 'Copied ${_selectedIndices.length} entries');
            },
          ),
        MobileGlassPillAction(
          icon: Icons.copy_all, tooltip: isZh ? '复制全部' : 'Copy all',
          color: scheme.onSurface, onTap: () {
            Clipboard.setData(ClipboardData(text: filtered.map(_fmt).join('\n')));
            showToast(context, isZh ? '已复制全部 ${filtered.length} 条' : 'Copied all ${filtered.length} entries');
          },
        ),
        MobileGlassPillAction(
          icon: Icons.delete_outline, tooltip: isZh ? '清空' : 'Clear',
          color: scheme.error, onTap: () { setState(() => _selectedIndices.clear()); context.read<AppState>().clearLogs(); },
        ),
      ];
      // 与其它二级页一致：统一顶栏（返回圆钮 + 标题药丸 + 操作药丸）。
      return MobileSubPageTopBar(
        title: titleRow,
        actions: mobileActions,
        onBack: () => Navigator.of(context).maybePop(),
      );
    }
    return GlassTopBar(title: titleRow, actions: actionWidgets);
  }

  /// 过滤器：**移动端**改用统一分段药丸控件（原先用 Material FilterChip，
  /// 与应用药丸语言脱节）；桌面端保持原有 FilterChip 外观逐像素不变。
  Widget _filterBar(ColorScheme scheme, bool isZh) {
    if (!isMobilePlatform) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: _filters.map((f) {
            final sel = _filter == f;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(_filterLabel(f, isZh),
                    style: TextStyle(
                        fontSize: 11,
                        color: sel ? scheme.onPrimaryContainer : scheme.onSurface)),
                selected: sel,
                onSelected: (v) => setState(() { _filter = f; _selectedIndices.clear(); }),
                selectedColor: scheme.primaryContainer,
                backgroundColor: scheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
                showCheckmark: false,
              ),
            );
          }).toList()),
        ),
      );
    }
    return MobileSegmentedPills(
      tabs: [for (final f in _filters) MobilePillTab(_filterLabel(f, isZh))],
      selectedIndex: _filters.indexOf(_filter),
      onSelected: (i) => setState(() { _filter = _filters[i]; _selectedIndices.clear(); }),
      margin: EdgeInsets.fromLTRB(MobileUi.subPagePaddingH, 8, MobileUi.subPagePaddingH, 8),
    );
  }

  Widget _buildList(List<LogEntry> filtered, ColorScheme scheme, AppConfig cfg, bool isZh) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: GlassPanel(
        // 面板玻璃样式跟随「卡片样式」（用户反馈「日志面板的模糊样式好像跟随药丸的」）。
        // 不传 style 时 GlassPanel 会落到全局 `glassEffect`（那是「弹窗 / 面板」的
        // 通用设置），于是设置里改「卡片样式」时日志面板纹丝不动，观感上就跟错了对象。
        // 日志面板语义上属于内容面板，与设置页卡片、其它内容面板保持一致。
        style: cfg.cardStyle,
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                child: Text(_catLabel(entry.category, isZh), style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: catColor)),
              ),
              Text(_ts(entry.timestamp), style: TextStyle(fontSize: 10, fontFamily: AppTheme.monoFont, color: scheme.outline)),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(entry.message, style: TextStyle(fontSize: 11, fontFamily: AppTheme.monoFont,
                  color: entry.category == 'error' ? scheme.error : scheme.onSurface))),
            ]),
          ),
        );

        // 内存优化：原来每一行日志都套一个 BackdropFilter(σ8) + RepaintBoundary。
        // 列表已整体位于 GlassPanel 之上（背景已被模糊过一次），行级模糊视觉
        // 贡献极小，却要按「可见行数 × 行尺寸」多分配大量离屏纹理——日志页
        // 可见行数多时是隐藏内存大户。行外观由半透明底色 + 细边框承担即可。
        row = Container(
          decoration: BoxDecoration(
            color: scheme.surface.withAlpha(60),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: scheme.outlineVariant.withAlpha(30), width: 0.5),
          ),
          child: row,
        );

        return Padding(padding: const EdgeInsets.only(bottom: 2), child: row);
      },
        ),
      ),
    );
  }

  String _fmt(LogEntry e) => '[${_ts(e.timestamp)}] [${e.category.toUpperCase()}] ${e.message}';
  String _ts(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
  Color _catColor(String cat, ColorScheme scheme) => switch (cat) {
    'info' => scheme.primary, 'ffmpeg' => Colors.teal, 'progress' => Colors.blue, 'error' => scheme.error, _ => scheme.outline,
  };
}
