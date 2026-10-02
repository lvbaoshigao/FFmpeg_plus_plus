import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;

import '../theme/app_text_scale.dart';

/// 统一的「菜单栏选项」控件 —— 融合两处参考样式：
/// * 触发按钮：设置→任务卡片下拉菜单的外观（圆角描边、紧凑高度、展开/收起动画）；
/// * 选项条目：设置页左侧主菜单条目（图标+文字，选中为主题色药丸，
///   AnimatedContainer 变色过渡 + AnimatedSwitcher 图标淡入淡出）。
///
/// 两种形态（同一组件，按 [expandable] 切换）：
/// * `expandable: false` —— 行内分段药丸（替代 SegmentedButton），适合 2~4 个短选项；
/// * `expandable: true`  —— 一个按钮，点开在 Overlay 上展开选项列表
///   （替代 DropdownMenu / RadioListTile 单选组），选中即回调并收起。
///
/// 供设置页所有枚举型选项控件统一使用；数值型数量选择（并发数/线程数）
/// 仍用任务卡片的下拉菜单，不在此列。
class OptionItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  const OptionItem(this.value, this.label, {this.subtitle, this.icon});
}

class OptionMenuBar<T> extends StatefulWidget {
  final List<OptionItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;

  /// expandable（按钮+展开列表）模式：触发按钮左侧的说明文字（可空）
  final String? label;
  final IconData? leadingIcon;

  /// false = 行内分段药丸；true = 按钮 + 展开选项列表
  final bool expandable;
  final double triggerHeight;

  const OptionMenuBar({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.label,
    this.leadingIcon,
    this.expandable = true,
    this.triggerHeight = 38,
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
  /// 每一行一个 GlobalKey：键盘高亮行滚出可视区时用 Scrollable.ensureVisible
  /// 把它滚回来（浮层高度上限 300，条目多时确实会滚）。
  List<GlobalKey> _rowKeys = const [];

  /// 浮层展开/收起动画（淡入 + 从锚点方向缩放，170ms）。
  ///
  /// 此前浮层是「瞬间出现」的：`_portal.show()` 后直接重绘，没有任何过渡，
  /// 用户反馈「展开没有动画」。这里用一个控制器把「展开 + 收起」都做成
  /// 连续动画：展开时 0→1；收起时先 1→0 再 `hide()`（见 [_close]），
  /// 因此收起也是动画而不是瞬间消失。
  ///
  /// 必须是 `late final` + 在 [initState] 里赋值：若写成 `late final ... =
  /// AnimationController(...)` 的惰性初始化，从未展开过的实例会在 [dispose]
  /// 里才第一次建 Ticker —— 那时 element 已 defunct，
  /// `TickerMode.getNotifier(context)` 的 `dependOnInheritedWidgetOfExactType`
  /// 会直接抛断言。
  late final AnimationController _ovCtrl;

  /// 浮层收起动画结束后再真正卸载的宽限时长（略大于动画时长，避免尾帧被截断）。
  static const Duration _overlayHideDelay = Duration(milliseconds: 210);

  @override
  void initState() {
    super.initState();
    _ovCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 170),
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
    super.dispose();
  }

  void _syncRowKeys() {
    _rowKeys = List<GlobalKey>.generate(
        widget.items.length, (i) => GlobalKey(debugLabel: 'OptionMenuBar.row$i'));
  }

  /// 当前选中项下标（没有匹配项时为 -1）。
  int _selectedIndex() => widget.items.indexWhere(_selected);

  /// 展开浮层（箭头旋转动画由 _expanded 驱动，浮层本身由 _ovCtrl 驱动）。
  void _open() {
    _openUp = _shouldOpenUp();
    _portal.show();
    // 打开时键盘高亮默认落在当前选中项：先看清「现在选的是什么」，
    // 之后按 ↑/↓ 才真正移动。
    setState(() {
      _expanded = true;
      _highlightIndex = _selectedIndex();
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
  /// 判定用 [_expanded] 而不是 `_portal.isShowing`：收起动画期间浮层仍在
  /// Overlay 上（等动画播完才 hide），此时用户再点一下应当「重新展开」，
  /// 而不是被当成第二次收起。
  void _toggle() {
    if (_expanded) {
      _close();
      return;
    }
    _open();
  }

  /// 把键盘高亮行滚进可视区（面板高度上限 300，条目多时会滚）。
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
    if (!_portal.isShowing) return;
    _ovCtrl.reverse();
    // 不用 TickerFuture.whenComplete：动画被打断（用户马上又点开）时
    // TickerFuture 会以 TickerCanceled 结束，未处理的错误会冒泡到 Zone。
    // 用一个延迟回调 + 状态复查，既能等到动画播完，又天然支持「打断」。
    Future.delayed(_overlayHideDelay, () {
      if (!mounted || _expanded) return; // 已被重新展开
      if (_portal.isShowing) _portal.hide();
    });
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
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final index = _highlightIndex;
      if (index == null || index < 0 || index >= widget.items.length) {
        return KeyEventResult.ignored;
      }
      _pick(widget.items[index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 移动键盘高亮；首次按键只把高亮显示出来（落在选中项上）。
  void _moveHighlight(int delta) {
    final count = widget.items.length;
    if (count == 0) return;
    final selected = _selectedIndex();
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

  /// 触发按钮下方剩余空间不足（< 300px）且上方更宽裕 → 向上弹出。
  bool _shouldOpenUp() {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return false;
    final top = ro.localToGlobal(Offset.zero).dy;
    final bottom = top + ro.size.height;
    final screenH = MediaQuery.of(context).size.height;
    final below = screenH - bottom;
    return below < 300 && top > below;
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
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < widget.items.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(child: _pill(context, widget.items[i], compact: true)),
          ],
        ]),
      );
    }

    // ── 按钮 + 浮层选项列表 ──
    //
    // 关键改动（用户反馈「设置-样式 / 字体里的选择框展开后卡片也跟着变长」）：
    // 展开的选项列表不再用 AnimatedSize 在**行内**撑开（那会把宿主卡片一起撑高），
    // 而是用 OverlayPortal 弹出一层浮层 —— 宿主卡片高度在展开/收起时完全不变。
    // 浮层用 CompositedTransformFollower 绑定触发按钮：滚动时自动跟随，
    // 点浮层外 / Esc / 选中某项都会关闭；下方空间不足时自动向上弹出。
    return LayoutBuilder(builder: (context, cons) {
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
            child: Row(children: [
              if (widget.leadingIcon != null) ...[
                Icon(widget.leadingIcon, size: 15, color: scheme.primary),
                const SizedBox(width: 7),
              ],
              if (widget.label != null) ...[
                Flexible(child: Text(widget.label!,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurface))),
                const SizedBox(width: 8),
              ],
              // 当前值：独占全部剩余宽度（Expanded），不与任何 Spacer 平分。
              //
              // 旧写法是 [const Spacer(), Flexible(Text)]，两者 flex 都是 1，
              // 剩余宽度被平分成两半 —— 文字只拿到一半，于是 132px 的框里
              // 「跟随主题色（纯色）」被截成「跟随 ...」，就是用户反馈的
              // 「右侧选项框内的文字显示不全」。这里没有 label 时只有一个
              // 弹性子项，文字自然占满整行；箭头固定在右端。
              Expanded(
                child: Text(current?.label ?? '',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                        color: scheme.onSurface)),
              ),
              const SizedBox(width: 4),
              // 展开时箭头旋转 180°，与设置页二级菜单同一动画语言
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(Icons.expand_more, size: 16, color: scheme.outline),
              ),
            ]),
          ),
        ),
      ),
        ),
      );
    });
  }

  /// 浮层选项列表：挂在 Overlay 上，因此**不会**撑高宿主卡片。
  /// 面板与触发按钮等宽（140~320 之间），高度上限 300 可滚动；
  /// 点面板外（全屏透明遮罩）/ Esc / 选中某项都会关闭。
  Widget _buildOverlay(BuildContext overlayContext) {
    final scheme = Theme.of(overlayContext).colorScheme;
    final panel = Material(
      elevation: 10,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < widget.items.length; i++)
              KeyedSubtree(
                key: i < _rowKeys.length ? _rowKeys[i] : null,
                child: _menuRow(overlayContext, widget.items[i],
                    highlighted: _highlightIndex == i),
              ),
          ]),
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
        Stack(children: [
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
          followerAnchor: _openUp ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(0, _openUp ? -4 : 4),
          child: Align(
            alignment: _openUp ? Alignment.bottomLeft : Alignment.topLeft,
            child: SizedBox(
              width: _triggerWidth.clamp(140.0, 320.0),
              child: Focus(
                autofocus: true,
                // PC 键盘：↑/↓ 移动高亮、Enter/Space 选中、Esc 关闭
                onKeyEvent: _onPanelKey,
                // 展开 / 收起动画：淡入 + 从锚点角缩放（170ms）。
                // 旧实现是 `_portal.show()` 后直接出现，没有任何过渡，
                // 用户反馈「展开没有动画」。
                child: FadeTransition(
                  opacity:
                      CurvedAnimation(parent: _ovCtrl, curve: Curves.easeOut),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.94, end: 1.0).animate(
                        CurvedAnimation(
                            parent: _ovCtrl, curve: Curves.easeOutCubic)),
                    // 锚点与弹出方向一致：向下弹从左上角放大，向上弹从左下角放大
                    alignment:
                        _openUp ? Alignment.bottomLeft : Alignment.topLeft,
                    child: panel,
                  ),
                ),
              ),
            ),
          ),
        ),
        ]),
      ),
    );
  }
  /// 行内药丸（bar 模式条目）
  Widget _pill(BuildContext context, OptionItem<T> it, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected(it);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _pick(it),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: compact ? 5 : 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: sel ? scheme.primary.withAlpha(34) : Colors.transparent,
          border: Border.all(
              color: sel ? scheme.primary.withAlpha(90) : Colors.transparent),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center,
            children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: it.icon == null
                ? const SizedBox.shrink()
                : Icon(it.icon,
                    key: ValueKey('${it.value}_$sel'),
                    size: 14,
                    color: sel ? scheme.primary : scheme.onSurfaceVariant),
          ),
          if (it.icon != null) const SizedBox(width: 4),
          Flexible(
            child: Text(it.label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? scheme.primary : scheme.onSurfaceVariant,
                )),
          ),
        ]),
      ),
    );
  }

  /// 展开列表行（menu 模式条目）—— 设置页左侧主菜单条目的同款动画。
  /// [highlighted] 只在键盘导航时生效（鼠标用户看到的样式与以前完全一致）。
  Widget _menuRow(BuildContext context, OptionItem<T> it, {bool highlighted = false}) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected(it);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _pick(it),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          // 选中 = 主题色药丸；键盘高亮 = 同色更淡的一档（弱于选中，避免混淆）
          color: sel
              ? scheme.primary.withAlpha(34)
              : (highlighted ? scheme.primary.withAlpha(16) : Colors.transparent),
          border: Border.all(
              color: sel
                  ? scheme.primary.withAlpha(90)
                  : (highlighted ? scheme.primary.withAlpha(44) : Colors.transparent)),
        ),
        child: Row(children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: Icon(
              it.icon ?? Icons.circle_outlined,
              key: ValueKey('${it.value}_$sel'),
              size: 15,
              color: sel ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text(it.label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? scheme.primary : scheme.onSurfaceVariant,
                )),
            if (it.subtitle != null) ...[
              const SizedBox(height: 2),
              Text(it.subtitle!,
                  style: TextStyle(fontSize: 10, color: scheme.outline)),
            ],
          ])),
          // 选中标记：淡入淡出（与图标同一动画语言）
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: sel
                ? Icon(Icons.check_rounded,
                    key: const ValueKey('check'),
                    size: 16, color: scheme.primary)
                : const SizedBox.shrink(key: ValueKey('none')),
          ),
        ]),
      ),
    );
  }
}
