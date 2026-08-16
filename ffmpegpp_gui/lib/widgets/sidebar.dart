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
  static const _anim = Duration(milliseconds: 260);
  static const _curve = Curves.easeInOutCubic;

  bool _collapsed = false;
  // 遮罩拖动：拖动中的临时 top 偏移（null = 未拖动）
  double? _maskDragTop;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  /// 遮罩拖动结束：吸附到最近的导航项并跳转。
  void _endMaskDrag(int count, double dragTop) {
    final idx = (dragTop / _itemH).round().clamp(0, count - 1);
    setState(() => _maskDragTop = null);
    if (idx != widget.selectedIndex) {
      widget.onSelected(idx);
    }
  }

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
                // 导航项：底部滑动遮罩按像素精确定位（从选中项滑到新选中项）
                Stack(children: [
                  // 滑动遮罩：默认随选中项动画滑动；按住可拖动，松开吸附到最近项并跳转
                  AnimatedPositioned(
                    duration: _maskDragTop == null ? _anim : Duration.zero,
                    curve: _curve,
                    top: (_maskDragTop ?? (widget.selectedIndex.clamp(0, items.length - 1)).toDouble() * _itemH)
                        .clamp(0.0, ((items.length - 1) * _itemH).toDouble()),
                    left: 0,
                    right: 0,
                    height: _itemH,
                    // 遮罩保留边距：与侧边栏左右边缘留 8px 缝隙（不贴合），
                    // 同时比 150 内容区宽，图标/文字四周各留 ~12px 间距
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer.withAlpha(200),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  Column(children: [
                    for (var i = 0; i < items.length; i++) _navItem(scheme, clr, items[i], i),
                  ]),
                  // 拖动层：覆盖整个导航区域，捕获垂直拖动（遮罩跟随鼠标）；
                  // 点击仍由下方 nav item 的 InkWell 处理（手势竞技场自动区分 tap/drag）。
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragStart: (d) => setState(() {
                        _maskDragTop =
                            (widget.selectedIndex.clamp(0, items.length - 1)).toDouble() * _itemH +
                            d.localPosition.dy.clamp(0.0, _itemH);
                      }),
                      onVerticalDragUpdate: (d) => setState(() {
                        _maskDragTop = (_maskDragTop ?? 0) + d.delta.dy;
                      }),
                      onVerticalDragEnd: (_) {
                        final t = _maskDragTop;
                        if (t != null) _endMaskDrag(items.length, t);
                      },
                      onVerticalDragCancel: () => setState(() => _maskDragTop = null),
                    ),
                  ),
                ]),
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
        // LayoutBuilder 依据动画中的实际宽度决定是否显示文字：
        // 宽度不足 90px 时只显示图标（收起过渡期不溢出，不再出现红底白字）
        child: LayoutBuilder(builder: (ctx, cons) {
          final showText = cons.maxWidth > 90;
          return Padding(
            padding: EdgeInsets.fromLTRB(showText ? 16 : 8, 20, showText ? 12 : 8, 16),
            child: Row(
              mainAxisAlignment: showText ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.asset('rele/icon.png', width: 28, height: 28, fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Icon(Icons.play_circle_fill, color: scheme.primary, size: 28)),
                ),
                if (showText) ...[
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
          );
        }),
      ),
    );
  }

  // 每个导航项的高度（图标 20 + 上下 padding 10*2 = 40），遮罩与之严格等高
  static const double _itemH = 40;

  Widget _navItem(ColorScheme scheme, Color clr, (IconData, String) item, int i) {
    final sel = i == widget.selectedIndex;
    // 选中态只由滑动遮罩表达；图标/文字瞬时变色（无多余动画，避免卡顿与尺寸不一致）
    // 固定宽度内容（图标 + 固定间距 + 文字），所有项图标/文字首字对齐，
    // 整个单元在导航项内水平居中，遮罩固定宽度与其一致。
    // LayoutBuilder 依据动画实际宽度显示文字，避免过渡期固定宽内容溢出
    return SizedBox(
      height: _itemH,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onTap: () => widget.onSelected(i),
          child: LayoutBuilder(builder: (ctx, cons) {
            final showText = cons.maxWidth > 90;
            // 首字对齐优先：固定内容宽 150，图标固定在最左侧起点，
            // 文字用 Expanded 强制撑满剩余（无论文字长短，图标/文字首字恒对齐）
            final contentW = showText ? 150.0 : 48.0;
            final row = Center(
              child: SizedBox(
                width: contentW.clamp(0.0, cons.maxWidth),
                height: _itemH,
                child: showText
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          Icon(item.$1, size: 20, color: sel ? scheme.primary : clr),
                          const SizedBox(width: 12),
                          // Expanded 撑满：文字长短不影响图标起点
                          Expanded(
                            child: Text(item.$2,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                                    color: sel ? scheme.onSecondaryContainer : clr)),
                          ),
                        ],
                      )
                    // 收起态：仅图标，水平居中
                    : Center(
                        child: Icon(item.$1, size: 20, color: sel ? scheme.primary : clr),
                      ),
              ),
            );
            // 收起（无文字）时用 tooltip 补上名称
            return !showText
                ? Tooltip(
                    message: item.$2,
                    waitDuration: const Duration(milliseconds: 200),
                    child: row,
                  )
                : row;
          }),
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

    // LayoutBuilder 依据动画实际宽度决定是否显示文字，避免过渡期溢出
    return LayoutBuilder(builder: (ctx, cons) {
      final showText = cons.maxWidth > 90;
      return Padding(
        padding: EdgeInsets.all(showText ? 16 : 10),
        child: _maybeTooltip(
          // 展开时文字就在旁边，不需要 tooltip（空 message 会弹出一个空气泡）
          !showText ? label : null,
          Container(
            padding: EdgeInsets.symmetric(horizontal: showText ? 12 : 8, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: scheme.surfaceContainerHighest.withAlpha(140),
            ),
            child: Row(
              mainAxisAlignment: showText ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                dot,
                if (showText) ...[
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
    });
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
