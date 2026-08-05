import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import 'glass_panel.dart';

class Sidebar extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  const Sidebar({super.key, required this.selectedIndex, required this.onSelected});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  static const _expandedWidth = 190.0;
  static const _collapsedWidth = 72.0;
  static const _anim = Duration(milliseconds: 200);
  static const _curve = Curves.easeOutCubic;

  bool _collapsed = false;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lang = context.watch<AppState>().config.language;
    final s = AppStrings.of(lang);
    final clr = scheme.onSurfaceVariant;

    final debug = context.watch<AppState>().config.debugMode;
    final items = <(IconData, String)>[
      (Icons.movie_outlined, s.navProjects),
      (Icons.list_alt_outlined, s.navQueue),
      (Icons.terminal_outlined, s.navCommand),
      (Icons.folder_copy_outlined, lang == 'zh' ? '配置库' : 'Configs'),
      (Icons.settings_outlined, s.navSettings),
      if (debug) (Icons.terminal, lang == 'zh' ? '日志' : 'Logs'),
    ];

    // 当 debug 模式关闭时，如果当前选中的是 Logs 页面，自动切回设置页面
    if (widget.selectedIndex >= items.length && items.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onSelected(items.length - 1);
      });
    }

    return AnimatedContainer(
      duration: _anim,
      curve: _curve,
      width: _collapsed ? _collapsedWidth : _expandedWidth,
      child: GlassPanel(
        radius: 20,
        blur: 18,
        child: Material(
          color: Colors.transparent,
          child: DefaultTextStyle(
            style: TextStyle(color: clr, fontFamily: theme.textTheme.bodyMedium?.fontFamily),
            // 宽度是动画过渡的，中途会短暂窄于展开态内容的理想宽度；
            // ClipRect + 下面各处的 Flexible/ellipsis 保证这期间不会抛 overflow。
            child: ClipRect(
              child: Column(children: [
                _header(scheme, s),
                Divider(color: scheme.outlineVariant.withAlpha(80), height: 1),
                const SizedBox(height: 8),
                ...List.generate(items.length, (i) => _navItem(scheme, clr, items[i], i)),
                const Spacer(),
                _status(scheme, clr, s, lang),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部品牌区，整行可点击用于折叠/展开
  Widget _header(ColorScheme scheme, AppStrings s) {
    return Tooltip(
      message: _collapsed ? s.navExpand : s.navCollapse,
      waitDuration: const Duration(milliseconds: 200),
      child: InkWell(
        onTap: _toggle,
        child: Padding(
          padding: EdgeInsets.fromLTRB(_collapsed ? 8 : 16, 20, _collapsed ? 8 : 12, 16),
          child: Row(
            mainAxisAlignment: _collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset('rele/icon.png', width: 28, height: 28, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        Icon(Icons.play_circle_fill, color: scheme.primary, size: 28)),
              ),
              if (!_collapsed) ...[
                const SizedBox(width: 10),
                Flexible(
                  child: Text('FFmpeg++',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16, color: scheme.primary)),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_left, size: 18, color: scheme.outline),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(ColorScheme scheme, Color clr, (IconData, String) item, int i) {
    final sel = i == widget.selectedIndex;
    final row = Padding(
      padding: EdgeInsets.symmetric(horizontal: _collapsed ? 6 : 12, vertical: 10),
      child: Row(
        mainAxisAlignment: _collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          Icon(item.$1, size: 20, color: sel ? scheme.onSecondaryContainer : clr),
          if (!_collapsed) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(item.$2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      color: sel ? scheme.onSecondaryContainer : clr)),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _collapsed ? 10 : 8, vertical: 2),
      child: AnimatedContainer(
        duration: _anim,
        curve: _curve,
        decoration: BoxDecoration(
          color: sel ? scheme.secondaryContainer.withAlpha(200) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => widget.onSelected(i),
            // 收起后没有文字，用 tooltip 补上名称
            child: _collapsed
                ? Tooltip(
                    message: item.$2,
                    waitDuration: const Duration(milliseconds: 200),
                    child: row,
                  )
                : row,
          ),
        ),
      ),
    );
  }

  Widget _status(ColorScheme scheme, Color clr, AppStrings s, String lang) {
    final running = context.watch<AppState>().pythonProcess.isRunning;
    final label = running ? s.backendConnected : (lang == 'zh' ? '后端已断开' : 'Backend disconnected');
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: running ? scheme.primary : scheme.error),
    );

    return Padding(
      padding: EdgeInsets.all(_collapsed ? 10 : 16),
      child: _maybeTooltip(
        // 展开时文字就在旁边，不需要 tooltip（空 message 会弹出一个空气泡）
        _collapsed ? label : null,
        Container(
          padding: EdgeInsets.symmetric(horizontal: _collapsed ? 8 : 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: scheme.surfaceContainerHighest.withAlpha(140),
          ),
          child: Row(
            mainAxisAlignment: _collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              dot,
              if (!_collapsed) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: clr)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// message 为 null 时不套 Tooltip —— 空字符串会弹出一个空气泡。
  static Widget _maybeTooltip(String? message, Widget child) => message == null
      ? child
      : Tooltip(
          message: message,
          waitDuration: const Duration(milliseconds: 200),
          child: child,
        );
}
