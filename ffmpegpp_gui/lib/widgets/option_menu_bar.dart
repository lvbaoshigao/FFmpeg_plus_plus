import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;

import '../theme/app_text_scale.dart';

/// 统一的「菜单栏选项」控件 —— 融合两处参考样式：
/// * 触发按钮：设置→任务卡片下拉菜单的外观（圆角描边、紧凑高度、展开/收起动画）；
/// * 选项条目：设置页左侧主菜单条目（图标+文字，选中为主题色药丸，
///   AnimatedContainer 变色过渡 + AnimatedSwitcher 图标淡入淡出）。
///
/// 两种形态（同一组件，按 [expandable] 切换）：
/// * expandable: false —— 行内分段药丸（替代 SegmentedButton），适合 2~4 个短选项；
/// * expandable: true  —— 一个按钮，点开在 Overlay 上展开选项列表
///   （替代 DropdownMenu / RadioListTile 单选组），选中即回调并收起。
///
/// 浮层动效（用户要求「缩放展开」而不是老式下拉）：
/// 面板从锚点角 0.86 → 1.0 缩放 + 淡入，200ms easeOutBack（轻微过冲），
/// 收起 140ms 反向。条目本身沿用设置页左侧菜单的选中药丸动画。
class OptionItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;

  /// 自定义前置控件（品牌 SVG logo 之类）—— 有它时优先于 [icon]。
  final Widget? leading;

  /// 危险操作（删除等）：文字/图标用 error 色。
  final bool danger;

  /// 额外的搜索关键词（label/subtitle 之外，例如英文名、别名）。
  final String? keywords;

  const OptionItem(
    this.value,
    this.label, {
    this.subtitle,
    this.icon,
    this.leading,
    this.danger = false,
    this.keywords,
  });

  /// 搜索匹配：忽略空格/连字符/下划线/点/斜杠/冒号，避免
  /// 「deepseek chat」搜不到「deepseek-chat」。
  bool matchesQuery(String query) {
    final needle = _normalizeForSearch(query);
    if (needle.isEmpty) return true;
    return _normalizeForSearch(label).contains(needle) ||
        _normalizeForSearch(subtitle ?? '').contains(needle) ||
        _normalizeForSearch(keywords ?? '').contains(needle);
  }
}

String _normalizeForSearch(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s\-_./:（）()]'), '');

/// 浮层面板的公共外观（Material 卡片）。OptionMenuBar 与 ScaleMenuButton 共用，
/// 保证「所有下拉/弹出菜单」视觉统一。
Widget _menuPanelShell({
  required ColorScheme scheme,
  required Widget child,
  double radius = 14,
}) {
  return Material(
    elevation: 10,
    color: scheme.surface,
    borderRadius: BorderRadius.circular(radius),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// 展开列表行（菜单模式条目）—— 设置页左侧主菜单条目的同款动画。
///
/// [highlighted] 只在键盘导航时生效（鼠标用户看到的样式与以前完全一致）。
/// [OptionItem.icon] 为 null 时**不占位**：旧实现用 Icons.circle_outlined 兜底，
/// 导致「模型选择框左边一直有个圆圈」（用户反馈），这里彻底去掉兜底图标。
Widget _optionRow<T>({
  required BuildContext context,
  required OptionItem<T> item,
  required bool selected,
  required bool highlighted,
  required VoidCallback onTap,
  int labelMaxLines = 1,
}) {
  final scheme = Theme.of(context).colorScheme;
  final weight =
      Theme.of(context).textTheme.bodyMedium?.fontWeight ?? FontWeight.w400;
  final accent = item.danger ? scheme.error : scheme.primary;
  return Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          // 选中 = 主题色药丸；键盘高亮 = 同色更淡的一档（弱于选中，避免混淆）
          color: selected
              ? accent.withAlpha(34)
              : (highlighted ? accent.withAlpha(16) : Colors.transparent),
          border: Border.all(
            color: selected
                ? accent.withAlpha(90)
                : (highlighted ? accent.withAlpha(44) : Colors.transparent),
          ),
        ),
        child: Row(
          children: [
            if (item.leading != null) ...[
              item.leading!,
              const SizedBox(width: 10),
            ] else if (item.icon != null) ...[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: Icon(
                  item.icon,
                  key: ValueKey(item.value.toString() + selected.toString()),
                  size: 15,
                  color: item.danger
                      ? scheme.error
                      : (selected ? scheme.primary : scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    maxLines: labelMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected
                          ? FontWeight.values[(weight.value ~/ 100).clamp(0, 8)]
                          : weight,
                      color: item.danger
                          ? scheme.error
                          : (selected
                                ? scheme.primary
                                : scheme.onSurfaceVariant),
                    ),
                  ),
                  if (item.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: scheme.outline),
                    ),
                  ],
                ],
              ),
            ),
            // 选中标记：淡入淡出（与图标同一动画语言）
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: selected
                  ? Icon(
                      Icons.check_rounded,
                      key: const ValueKey('check'),
                      size: 16,
                      color: accent,
                    )
                  : const SizedBox.shrink(key: ValueKey('none')),
            ),
          ],
        ),
      ),
    ),
  );
}

class OptionMenuBar<T> extends StatefulWidget {
  final List<OptionItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;

  /// expandable（按钮+展开列表）模式：触发按钮左侧的说明文字（可空）
  final String? label;
  final IconData? leadingIcon;

  /// 触发按钮上的自定义前置控件（例如当前模型对应的品牌 SVG logo）。
  final Widget? leadingWidget;

  /// false = 行内分段药丸；true = 按钮 + 展开选项列表
  final bool expandable;
  final double triggerHeight;

  /// 浮层内显示搜索框（条目多时用，例如模型列表）。
  ///
  /// 只对「条目多 / 名称长」的菜单开启；2~4 个短选项的菜单不加搜索框
  /// （用户要求：选项少的下拉菜单不要搜索框）。
  final bool searchable;
  final String? searchHint;

  /// 搜索无结果时的提示文案（null = 中文默认「无匹配项」）。
  ///
  /// 共享控件不写死语言：英文界面由调用点传 "No matches"。
  final String? emptyLabel;

  /// 浮层固定宽度（null = 跟随触发按钮宽度）。
  ///
  /// 模型选择这类「触发按钮很窄、条目很长」的场景传 320~360，
  /// 让长模型名不再被 200px 截断成省略号。
  final double? menuWidth;

  const OptionMenuBar({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.label,
    this.leadingIcon,
    this.leadingWidget,
    this.expandable = true,
    this.triggerHeight = 38,
    this.searchable = false,
    this.searchHint,
    this.emptyLabel,
    this.menuWidth,
  });

  @override
  State<OptionMenuBar<T>> createState() => _OptionMenuBarState<T>();
}

class _OptionMenuBarState<T> extends State<OptionMenuBar<T>>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  /// 浮层控制器：展开的选项列表挂在 Overlay 上（不参与宿主卡的布局）。
  final OverlayPortalController _portal = OverlayPortalController();

  /// 触发按钮与浮层之间的定位链接（滚动时浮层自动跟随按钮）。
  final LayerLink _link = LayerLink();

  /// 触发按钮宽度：浮层与按钮等宽（由 LayoutBuilder 写入）。
  double _triggerWidth = 200;

  /// 下方空间不足时改为向上弹出。
  bool _openUp = false;

  /// 键盘高亮项下标（null = 还没开始键盘导航，例如纯鼠标打开）。
  int? _highlightIndex;

  /// 搜索关键字（仅 OptionMenuBar.searchable 生效）。
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// 每一行一个 GlobalKey：键盘高亮行滚出可视区时用 Scrollable.ensureVisible
  /// 把它滚回来（浮层高度上限 320，条目多时确实会滚）。
  List<GlobalKey> _rowKeys = const [];

  /// 浮层展开/收起动画（淡入 + 从锚点方向缩放，200ms）。
  ///
  /// 必须是 late final + 在 initState 里赋值：若写成 late final ... =
  /// AnimationController(...) 的惰性初始化，从未展开过的实例会在 dispose
  /// 里才第一次建 Ticker —— 那时 element 已 defunct，
  /// TickerMode.getNotifier(context) 的 dependOnInheritedWidgetOfExactType
  /// 会直接抛断言。
  late final AnimationController _ovCtrl;

  /// 浮层收起动画结束后再真正卸载的宽限时长（略大于动画时长，避免尾帧被截断）。
  static const Duration _overlayHideDelay = Duration(milliseconds: 240);

  @override
  void initState() {
    super.initState();
    _ovCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 140),
    );
    _syncRowKeys();
  }

  @override
  void didUpdateWidget(covariant OptionMenuBar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) _syncRowKeys();
  }

  @override
  void dispose() {
    _ovCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _syncRowKeys([int? count]) {
    _rowKeys = List<GlobalKey>.generate(
      count ?? widget.items.length,
      (i) => GlobalKey(debugLabel: 'OptionMenuBar.row$i'),
    );
  }

  /// 当前可见条目（开启搜索且有输入时按关键字过滤）。
  List<OptionItem<T>> get _visibleItems {
    if (!widget.searchable || _query.trim().isEmpty) return widget.items;
    return widget.items.where((it) => it.matchesQuery(_query)).toList();
  }

  /// 当前选中项下标（没有匹配项时为 -1）。
  int _selectedIndex([List<OptionItem<T>>? items]) =>
      (items ?? _visibleItems).indexWhere(_selected);

  /// 展开浮层（箭头旋转动画由 _expanded 驱动，浮层本身由 _ovCtrl 驱动）。
  void _open() {
    _openUp = _shouldOpenUp();
    _portal.show();
    _query = '';
    _searchCtrl.clear();
    final items = _visibleItems;
    // 打开时键盘高亮默认落在当前选中项：先看清「现在选的是什么」，
    // 之后按 ↑/↓ 才真正移动。
    setState(() {
      _expanded = true;
      _highlightIndex = _selectedIndex(items);
      _syncRowKeys(items.length);
    });
    _ovCtrl.forward(from: 0);
    // 选中项可能在滚动区之外：等浮层首帧布局完成后把它滚进可视区，
    // 否则长列表里「默认高亮当前选中项」根本看不见。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureHighlightVisible();
    });
  }

  /// 展开/收起浮层。
  ///
  /// 判定用 _expanded 而不是 _portal.isShowing：收起动画期间浮层仍在
  /// Overlay 上（等动画播完才 hide），此时用户再点一下应当「重新展开」，
  /// 而不是被当成第二次收起。
  void _toggle() {
    if (_expanded) {
      _close();
      return;
    }
    _open();
  }

  /// 把键盘高亮行滚进可视区（面板高度上限 320，条目多时会滚）。
  void _ensureHighlightVisible() {
    final index = _highlightIndex;
    if (index == null || index < 0 || index >= _rowKeys.length) return;
    final rowContext = _rowKeys[index].currentContext;
    if (rowContext != null) {
      Scrollable.ensureVisible(rowContext, alignment: 0.5);
    }
  }

  /// 收起（先播收起动画，动画结束才真正把浮层从 Overlay 上卸载）。
  void _close() {
    if (!mounted) return;
    if (_expanded || _highlightIndex != null) {
      setState(() {
        _expanded = false;
        _highlightIndex = null;
      });
    }
    if (!_portal.isShowing) {
      _resetSearch();
      return;
    }
    _ovCtrl.reverse();
    // 不用 TickerFuture.whenComplete：动画被打断（用户马上又点开）时
    // TickerFuture 会以 TickerCanceled 结束，未处理的错误会冒泡到 Zone。
    // 用一个延迟回调 + 状态复查，既能等到动画播完，又天然支持「打断」。
    Future.delayed(_overlayHideDelay, () {
      if (!mounted || _expanded) return; // 已被重新展开
      if (_portal.isShowing) _portal.hide();
      // 搜索词必须等收起动画播完再清：清得太早，浮层还在淡出，
      // 列表会从「过滤结果」闪回全量（且 _rowKeys 数量与行数错位）。
      _resetSearch();
    });
  }

  /// 清空搜索态。收起动画结束后调用；_open() 里也会重置一次。
  void _resetSearch() {
    if (!mounted) return;
    if (_query.isEmpty && _highlightIndex == null) return;
    setState(() {
      _query = '';
      _highlightIndex = null;
      _syncRowKeys(widget.items.length);
    });
    _searchCtrl.clear();
  }

  /// PC 键盘导航：↑/↓ 移动高亮、Enter/Space 选中、Esc 关闭。
  ///
  /// Esc 必须返回 handled：否则按键会继续冒泡到 App 级的 DismissIntent，
  /// 把整个设置子页/对话框关掉，而不是只关这个浮层。
  KeyEventResult _onPanelKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    // 搜索模式下 Enter / Space 归搜索框：Space 是普通字符（要能打出
    // "deepseek chat" 这种带空格的词），Enter 交给 TextField.onSubmitted
    // 选中高亮项。这里必须放行 —— 面板的 Focus 是搜索框的**祖先**，而
    // 按键派发是「叶子 → 根」，不放行就会比 IME 更早吃掉按键：
    //   * Space → 静默选中第一条搜索结果并收起菜单；
    //   * Enter → 先按高亮项选中一次，再被 onSubmitted 用「清空过滤后的
    //     首项」覆盖一次，配置被改两次且最终值不是搜到的那条。
    if (widget.searchable &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.space)) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final items = _visibleItems;
      final index = _highlightIndex;
      if (items.isEmpty) return KeyEventResult.handled;
      _pick(
        items[(index == null || index < 0 || index >= items.length) ? 0 : index],
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 移动键盘高亮；首次按键只把高亮显示出来（落在选中项上）。
  void _moveHighlight(int delta) {
    final items = _visibleItems;
    final count = items.length;
    if (count == 0) return;
    final selected = _selectedIndex(items);
    // 没有选中项时：↓ 从首项开始，↑ 从末项开始
    final start = selected >= 0 ? selected : (delta > 0 ? 0 : count - 1);
    final next = _highlightIndex == null
        ? start
        : (((_highlightIndex! + delta) % count) + count) % count;
    setState(() => _highlightIndex = next);
    // 高亮行可能在滚动区之外：等这一帧布局完成再把它滚进可视区。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureHighlightVisible();
    });
  }

  /// 触发按钮下方剩余空间不足（< 320px）且上方更宽裕 → 向上弹出。
  bool _shouldOpenUp() {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return false;
    final top = ro.localToGlobal(Offset.zero).dy;
    final bottom = top + ro.size.height;
    final screenH = MediaQuery.of(context).size.height;
    final below = screenH - bottom;
    return below < 320 && top > below;
  }

  bool _selected(OptionItem<T> it) => it.value == widget.value;

  void _pick(OptionItem<T> it) {
    if (_selected(it)) {
      if (widget.expandable) _close();
      return;
    }
    widget.onChanged(it.value);
    if (widget.expandable) _close();
  }

  @override
  Widget build(BuildContext context) {
    // 「字体大小的调整不要应用于选项文字」（用户要求）：下拉按钮与分段药丸的宽度
    // 是固定的（设置页 _kMenuWidth = 116），字号一大框内文字就只剩省略号，
    // 而且「选中了什么」本身也会被字号变化搅乱。整棵控件退回到「只跟系统字号」：
    // 系统字体大小设置照旧生效（见 theme/app_text_scale.dart）。
    return withoutAppTextScale(context, _buildControl(context));
  }

  Widget _buildControl(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = widget.items.where(_selected).firstOrNull;
    final trigger = BoxDecoration(
      color: scheme.surface.withAlpha(60),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: scheme.outlineVariant.withAlpha(90)),
    );

    if (!widget.expandable) {
      // ── 行内分段药丸：同一套选中动画，2~4 个短选项 ──
      return Container(
        decoration: trigger.copyWith(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < widget.items.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(child: _pill(context, widget.items[i], compact: true)),
            ],
          ],
        ),
      );
    }

    // ── 按钮 + 浮层选项列表 ──
    //
    // 展开的选项列表不再用 AnimatedSize 在**行内**撑开（那会把宿主卡片一起撑高），
    // 而是用 OverlayPortal 弹出一层浮层 —— 宿主卡片高度在展开/收起时完全不变。
    // 浮层用 CompositedTransformFollower 绑定触发按钮：滚动时自动跟随，
    // 点浮层外 / Esc / 选中某项都会关闭；下方空间不足时自动向上弹出。
    return LayoutBuilder(
      builder: (context, cons) {
        _triggerWidth = cons.maxWidth.isFinite ? cons.maxWidth : 200;
        return CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _portal,
            overlayChildBuilder: _buildOverlay,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _toggle,
                child: Container(
                  height: widget.triggerHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: trigger,
                  child: Row(
                    children: [
                      if (widget.leadingWidget != null) ...[
                        widget.leadingWidget!,
                        const SizedBox(width: 7),
                      ] else if (widget.leadingIcon != null) ...[
                        Icon(
                          widget.leadingIcon,
                          size: 15,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 7),
                      ],
                      if (widget.label != null) ...[
                        Flexible(
                          child: Text(
                            widget.label!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // 当前值：独占全部剩余宽度（Expanded），不与任何 Spacer 平分。
                      //
                      // 旧写法是 [const Spacer(), Flexible(Text)]，两者 flex 都是 1，
                      // 剩余宽度被平分成两半 —— 文字只拿到一半，于是 132px 的框里
                      // 「跟随主题色（纯色）」被截成「跟随 ...」。这里没有 label 时
                      // 只有一个弹性子项，文字自然占满整行；箭头固定在右端。
                      Expanded(
                        child: Text(
                          current?.label ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 展开时箭头旋转 180°，与设置页二级菜单同一动画语言
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Icons.expand_more,
                          size: 16,
                          color: scheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 浮层宽度：显式 OptionMenuBar.menuWidth 优先（模型列表要更宽），
  /// 否则跟随触发按钮；两者都夹在「屏幕宽度 - 24」以内。
  double _panelWidth(BuildContext overlayContext) {
    final screenW = MediaQuery.sizeOf(overlayContext).width;
    final maxW = math.max(120.0, screenW - 24);
    if (widget.menuWidth != null) {
      return math.min(widget.menuWidth!, maxW);
    }
    final minW = math.min(widget.searchable ? 240.0 : 140.0, maxW);
    return _triggerWidth.clamp(minW, math.min(320.0, maxW));
  }

  /// 浮层水平平移量：锚点恒为「触发钮左缘」，浮层向右铺 menuWidth。
  ///
  /// 触发钮本身靠右时（移动端 AI 设置的下拉是右对齐、浮层 220~260 宽），
  /// 右缘会跑出屏幕，勾选标记与长文案被裁掉。这里把浮层整体左移到屏幕内：
  /// 只平移、不翻转锚点方向（翻转会改变「从哪个角放大」的观感）。
  double _panelDx(BuildContext overlayContext, double panelW) {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return 0;
    final left = ro.localToGlobal(Offset.zero).dx;
    final screenW = MediaQuery.sizeOf(overlayContext).width;
    const margin = 12.0;
    final overflow = left + panelW + margin - screenW;
    if (overflow <= 0) return 0;
    // 面板比「屏幕 - 左右边距」还宽时，最多推到贴左边距，别把左缘推出屏幕。
    return -math.min(overflow, math.max(0.0, left - margin));
  }

  /// 浮层选项列表：挂在 Overlay 上，因此**不会**撑高宿主卡片。
  /// 高度上限 320 可滚动；点面板外（全屏透明遮罩）/ Esc / 选中某项都会关闭。
  Widget _buildOverlay(BuildContext overlayContext) {
    final scheme = Theme.of(overlayContext).colorScheme;
    final items = _visibleItems;
    final panel = _menuPanelShell(
      scheme: scheme,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.searchable) _buildSearchField(overlayContext, scheme),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                child: Text(
                  widget.emptyLabel ?? '无匹配项',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < items.length; i++)
                        KeyedSubtree(
                          key: i < _rowKeys.length ? _rowKeys[i] : null,
                          child: _optionRow<T>(
                            context: overlayContext,
                            item: items[i],
                            selected: _selected(items[i]),
                            highlighted: _highlightIndex == i,
                            onTap: () => _pick(items[i]),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Positioned.fill(
      // 浮层挂在 Overlay 上（不在宿主卡片里），同样要退回到「只跟系统字号」，
      // 否则展开后的选项列表字号会和触发按钮对不上。
      // 注意：MediaQuery 必须包在 Stack **里面** —— Positioned 必须是 Overlay
      // 那个 Stack 的直接子节点，中间夹一层会触发 ParentDataWidget 报错。
      child: withoutAppTextScale(
        overlayContext,
        Stack(
          children: [
            // 全屏透明遮罩：点浮层以外任意位置关闭。用 opaque 命中，
            // 避免误触到底层控件（与系统下拉菜单的行为一致）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const SizedBox.expand(),
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: _openUp ? Alignment.topLeft : Alignment.bottomLeft,
              followerAnchor: _openUp
                  ? Alignment.bottomLeft
                  : Alignment.topLeft,
              offset: Offset(
                _panelDx(overlayContext, _panelWidth(overlayContext)),
                _openUp ? -4 : 4,
              ),
              child: Align(
                alignment: _openUp ? Alignment.bottomLeft : Alignment.topLeft,
                child: SizedBox(
                  width: _panelWidth(overlayContext),
                  child: Focus(
                    // 搜索模式下焦点归搜索框，这里只负责 Esc / 方向键兜底
                    canRequestFocus: !widget.searchable,
                    autofocus: !widget.searchable,
                    // PC 键盘：↑/↓ 移动高亮、Enter/Space 选中、Esc 关闭
                    onKeyEvent: _onPanelKey,
                    // 展开 / 收起动画：淡入 + 从锚点角缩放（200ms easeOutBack，
                    // 轻微过冲 = 用户要求的「缩放展开」而不是老式瞬时下拉）。
                    child: FadeTransition(
                      opacity: CurvedAnimation(
                        parent: _ovCtrl,
                        curve: Curves.easeOut,
                      ),
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.86, end: 1.0).animate(
                          CurvedAnimation(
                            parent: _ovCtrl,
                            curve: Curves.easeOutBack,
                          ),
                        ),
                        // 锚点与弹出方向一致：向下弹从左上角放大，向上弹从左下角放大
                        alignment: _openUp
                            ? Alignment.bottomLeft
                            : Alignment.topLeft,
                        child: panel,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 浮层内的搜索框（仅条目多的菜单开启）。
  Widget _buildSearchField(BuildContext context, ColorScheme scheme) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: scheme.outlineVariant.withAlpha(90)),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
      child: TextField(
        controller: _searchCtrl,
        autofocus: true,
        style: const TextStyle(fontSize: 12.5),
        cursorHeight: 15,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withAlpha(120),
          hintText: widget.searchHint ?? '搜索',
          hintStyle: TextStyle(fontSize: 12.5, color: scheme.outline),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 16,
            color: scheme.outline,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除',
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() {
                      _query = '';
                      _highlightIndex = 0;
                      _syncRowKeys(widget.items.length);
                    });
                  },
                  icon: Icon(Icons.close_rounded, color: scheme.outline),
                ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 30,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          border: border,
          enabledBorder: border,
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.primary.withAlpha(140)),
          ),
        ),
        onChanged: (value) {
          setState(() {
            _query = value;
            _highlightIndex = 0;
            _syncRowKeys(_visibleItems.length);
          });
        },
        onSubmitted: (_) {
          // 收起后（Esc / 点遮罩 / 选中项）迟到的 IME 提交不应再改配置：
          // 此时 _query 已被清空，_visibleItems 是全量列表，会误选第一项。
          if (!_expanded) return;
          final items = _visibleItems;
          if (items.isEmpty) return;
          final index = _highlightIndex;
          _pick(
            items[(index == null || index < 0 || index >= items.length)
                ? 0
                : index],
          );
        },
      ),
    );
  }

  /// 行内药丸（bar 模式条目）
  Widget _pill(BuildContext context, OptionItem<T> it, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected(it);
    final weight =
        Theme.of(context).textTheme.bodyMedium?.fontWeight ?? FontWeight.w400;
    return Semantics(
      selected: sel,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _pick(it),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 6 : 10,
            vertical: compact ? 5 : 7,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: sel ? scheme.primary.withAlpha(34) : Colors.transparent,
            border: Border.all(
              color: sel ? scheme.primary.withAlpha(90) : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (it.leading != null) ...[
                it.leading!,
                const SizedBox(width: 4),
              ] else
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: it.icon == null
                    ? const SizedBox.shrink()
                    : Icon(
                        it.icon,
                        key: ValueKey(it.value.toString() + sel.toString()),
                        size: 14,
                        color: sel ? scheme.primary : scheme.onSurfaceVariant,
                      ),
              ),
              if (it.icon != null) const SizedBox(width: 4),
              Flexible(
                child: Text(
                  it.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: sel
                        ? FontWeight.values[(weight.value ~/ 100).clamp(0, 8)]
                        : weight,
                    color: sel ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 图标触发的「动作菜单」按钮 —— 替代 PopupMenuButton。
///
/// 为什么不用 PopupMenuButton：系统菜单是「瞬间弹出 + 直角 + 阴影」，在玻璃主题
/// 里显得古老（用户反馈「单个模型右边的更多选项展开样式仍旧过于古老」）。
/// 这里复用 OptionMenuBar 的浮层面板外观：同一套圆角、选中药丸、180ms
/// 缩放展开动画、danger 色，并且**不受** App 字体缩放影响。
///
/// 用法示例（伪代码）：
///   ScaleMenuButton（泛型 T）(
///     icon: Icons.more_vert,
///     tooltip: '更多操作',
///     items: [OptionItem(Action.use, '设为当前模型'), ...],
///     onSelected: (a) => handle(a),
///   )
class ScaleMenuButton<T> extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final double iconSize;

  /// 触发按钮边长（默认 30，与 IconButton 视觉一致）。
  final double size;
  final List<OptionItem<T>> items;
  final ValueChanged<T> onSelected;

  /// 浮层宽度（null = 220）。
  final double? menuWidth;
  final EdgeInsetsGeometry padding;

  const ScaleMenuButton({
    super.key,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
    this.iconSize = 18,
    this.size = 30,
    this.menuWidth,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<ScaleMenuButton<T>> createState() => _ScaleMenuButtonState<T>();
}

class _ScaleMenuButtonState<T> extends State<ScaleMenuButton<T>>
    with SingleTickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  bool _expanded = false;

  /// 按钮靠近屏幕底部时改为向上弹出（见 _shouldOpenUp）。
  bool _openUp = false;

  /// 键盘高亮行下标（null = 还没开始键盘导航）。
  ///
  /// 被替换掉的 PopupMenuButton 支持 Esc / ↑↓ / Enter；这里补齐同样的能力，
  /// 否则键盘用户在菜单打开后只能靠鼠标点空白处关闭。
  int? _highlightIndex;
  late final AnimationController _ctrl;

  static const Duration _hideDelay = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 130),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _open() {
    if (widget.items.isEmpty) return;
    _openUp = _shouldOpenUp();
    _portal.show();
    setState(() {
      _expanded = true;
      _highlightIndex = 0;
    });
    _ctrl.forward(from: 0);
  }

  /// PC 键盘：Esc 关闭、↑/↓ 移动高亮、Enter/Space 选中。
  KeyEventResult _onPanelKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final count = widget.items.length;
      if (count == 0) return KeyEventResult.handled;
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = _highlightIndex == null
          ? (delta > 0 ? 0 : count - 1)
          : (((_highlightIndex! + delta) % count) + count) % count;
      setState(() => _highlightIndex = next);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final index = _highlightIndex;
      if (index == null || index < 0 || index >= widget.items.length) {
        return KeyEventResult.handled;
      }
      final item = widget.items[index];
      _close();
      widget.onSelected(item.value);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 触发按钮下方剩余空间不足、上方更宽裕 → 向上弹出。
  ///
  /// 模型行末尾的 ⋮ 在可滚动列表里，滚到底部时按钮就贴着屏幕下沿：
  /// 浮层恒向下弹会被 Overlay 的 Stack 裁掉，「删除模型」等末项点不到
  /// （被替换掉的 PopupMenuButton 会自动上移）。
  bool _shouldOpenUp() {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return false;
    final top = ro.localToGlobal(Offset.zero).dy;
    final bottom = top + ro.size.height;
    final screenH = MediaQuery.of(context).size.height;
    final below = screenH - bottom;
    return below < 240 && top > below;
  }

  void _close() {
    if (!mounted) return;
    if (_expanded || _highlightIndex != null) {
      setState(() {
        _expanded = false;
        _highlightIndex = null;
      });
    }
    if (!_portal.isShowing) return;
    _ctrl.reverse();
    Future.delayed(_hideDelay, () {
      if (!mounted || _expanded) return;
      if (_portal.isShowing) _portal.hide();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return withoutAppTextScale(
      context,
      CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _buildOverlay,
          child: Tooltip(
            message: widget.tooltip ?? '',
            waitDuration: const Duration(milliseconds: 500),
            child: InkWell(
              borderRadius: BorderRadius.circular(widget.size / 2),
              onTap: _expanded ? _close : _open,
              child: Padding(
                padding: widget.padding,
                child: SizedBox(
                  width: widget.size,
                  height: widget.size,
                  child: Center(
                    child: Icon(
                      widget.icon,
                      size: widget.iconSize,
                      color: _expanded
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 浮层水平平移量：浮层右缘对齐触发钮右缘、向左铺 width。
  ///
  /// 按钮贴着屏幕左边时（行内 ⋮ 靠左的布局），左缘会跑出屏幕。
  double _panelDx(BuildContext overlayContext, double panelW) {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return 0;
    final right = ro.localToGlobal(Offset.zero).dx + ro.size.width;
    final screenW = MediaQuery.sizeOf(overlayContext).width;
    const margin = 12.0;
    final needed = panelW + margin - right;
    if (needed <= 0) return 0;
    return math.min(needed, math.max(0.0, screenW - margin - right));
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final scheme = Theme.of(overlayContext).colorScheme;
    final media = MediaQuery.sizeOf(overlayContext);
    final width = math.min(
      widget.menuWidth ?? 220.0,
      math.max(140.0, media.width - 24),
    );
    // 浮层高度上限：屏幕够高时给 320（条目多时可滚），靠近屏幕上下沿时
    // 按实际可用空间收紧 —— 否则条目会被 Overlay 的 Stack 直接裁掉。
    final ro = context.findRenderObject();
    final hasBox = ro is RenderBox && ro.hasSize;
    final triggerTop = hasBox ? ro.localToGlobal(Offset.zero).dy : 0.0;
    final triggerBottom = triggerTop + (hasBox ? ro.size.height : 0.0);
    final available = _openUp
        ? triggerTop - 16
        : media.height - triggerBottom - 16;
    final maxHeight = math.max(96.0, math.min(320.0, available));
    final panel = _menuPanelShell(
      scheme: scheme,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.items.length; i++)
                _optionRow<T>(
                  context: overlayContext,
                  item: widget.items[i],
                  selected: false,
                  highlighted: _highlightIndex == i,
                  labelMaxLines: 2,
                  onTap: () {
                    _close();
                    widget.onSelected(widget.items[i].value);
                  },
                ),
            ],
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: withoutAppTextScale(
        overlayContext,
        Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const SizedBox.expand(),
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              // 触发按钮在右端：浮层右上角对齐按钮右下角；按钮贴底时改为
              // 向上弹（浮层右下角对齐按钮右上角）。
              targetAnchor: _openUp
                  ? Alignment.topRight
                  : Alignment.bottomRight,
              followerAnchor: _openUp
                  ? Alignment.bottomRight
                  : Alignment.topRight,
              offset: Offset(
                _panelDx(overlayContext, width),
                _openUp ? -4 : 4,
              ),
              child: Align(
                alignment: _openUp ? Alignment.bottomRight : Alignment.topRight,
                child: SizedBox(
                  width: width,
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _ctrl,
                      curve: Curves.easeOut,
                    ),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.86, end: 1.0).animate(
                        CurvedAnimation(
                          parent: _ctrl,
                          curve: Curves.easeOutBack,
                        ),
                      ),
                      alignment: _openUp
                          ? Alignment.bottomRight
                          : Alignment.topRight,
                      // 键盘焦点落在浮层上：Esc / ↑↓ / Enter 都能用
                      // （被替换掉的 PopupMenuButton 本来就有这些能力）。
                      child: Focus(
                        autofocus: true,
                        onKeyEvent: _onPanelKey,
                        child: panel,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
