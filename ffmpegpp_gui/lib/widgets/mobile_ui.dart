import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../theme/mobile_ui.dart';
import 'mobile_glass_pill.dart';
// 「左半 / 右半 + 操作溢出收纳」布局与 MobileSubPageTopBar 同源，共用唯一实现
import 'mobile_top_bar.dart';

export '../theme/mobile_ui.dart' show MobileUi;

/// ═══════════════════════════════════════════════════════════════════════════
/// 移动端统一组件层（以「主界面」lib/pages/project_page.dart 为基准）
///
/// 这里提供主界面已被认可的顶栏 / 搜索 / 分段控件的唯一实现，替代此前
/// 各页面各写一份导致的规格漂移。尺寸令牌见 theme/mobile_ui.dart。
/// ═══════════════════════════════════════════════════════════════════════════

/// ═══════════════════════════════════════════════════════════════════════════
/// 主 Tab 页统一顶栏 —— 主界面（项目页）顶栏的唯一实现。
///
/// 搜索圆钮保持 44 × 44；展开时同一玻璃表面向左延展并移动到顶栏中央，
/// 标题与其它操作渐隐。搜索内容只在展开时挂载，避免隐藏输入框抢走焦点。
///
/// [searchChild] 为 null 时不启用搜索层（如配置库、队列页）。
/// ═══════════════════════════════════════════════════════════════════════════
class MobilePillTopBar extends StatefulWidget {
  /// 左标题药丸内容（文字 / 多选计数行等）
  final Widget title;

  /// 右操作药丸内容，通常是若干 [MobileGlassPillAction]
  final List<Widget> actions;

  /// 是否处于搜索态（仅当 [searchChild] 非空时生效）
  final bool searching;

  /// 搜索药丸内容（一般为 [MobileSearchPill]）
  final Widget? searchChild;

  /// 是否允许把放不下的操作收进「…」（默认 true）。
  /// 配置库传 false：3 个固定操作直接 inline 展示，不再折叠。
  final bool collapseActions;

  const MobilePillTopBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.searching = false,
    this.searchChild,
    this.collapseActions = true,
  });

  @override
  State<MobilePillTopBar> createState() => _MobilePillTopBarState();
}

class _MobilePillTopBarState extends State<MobilePillTopBar> {
  static const Duration _duration = Duration(milliseconds: 220);
  static const double _searchPadding = 12;

  bool _keepSearchSurface = false;
  FocusNode? _previousFocus;

  @override
  void initState() {
    super.initState();
    _keepSearchSurface = _searchOpen;
  }

  bool get _searchOpen => widget.searchChild != null && widget.searching;

  @override
  void didUpdateWidget(covariant MobilePillTopBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasOpen = oldWidget.searchChild != null && oldWidget.searching;
    if (_searchOpen && !wasOpen) {
      _keepSearchSurface = true;
      _previousFocus = FocusManager.instance.primaryFocus;
    } else if (!_searchOpen && wasOpen) {
      final previous = _previousFocus;
      _previousFocus = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !_searchOpen &&
            previous != null &&
            previous.context != null &&
            previous.canRequestFocus) {
          previous.requestFocus();
        }
      });
    }
    if (widget.searchChild == null) {
      _keepSearchSurface = false;
    }
  }

  void _finishSearchTransition() {
    if (_searchOpen || !_keepSearchSurface) {
      return;
    }
    // A zero-duration transition can finish while LayoutBuilder is updating.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_searchOpen && _keepSearchSurface) {
        setState(() => _keepSearchSurface = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final search = widget.searchChild;
    final searchOpen = _searchOpen;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _duration;
    final singleAction = widget.actions.length == 1
        ? widget.actions.single
        : null;
    final standaloneSearch =
        search != null &&
        singleAction is MobileGlassPillAction &&
        singleAction.icon == Icons.search;

    final titleContent = DefaultTextStyle.merge(
      style: MobileUi.titleStyle(context),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: widget.title,
    );
    final barPadding = EdgeInsets.only(
      right: standaloneSearch ? MobileUi.pillHeight + 8 : 0,
      bottom: 6,
    );
    final normal = Padding(
      padding: barPadding,
      child: SizedBox(
        height: MobileUi.pillHeight,
        child: MobilePillBarLayout(
          titlePill: MobileGlassPill(
            radius: MobileUi.pillRadius,
            height: MobileUi.pillHeight,
            padding: const EdgeInsets.symmetric(
              horizontal: MobileUi.titlePillPadH,
            ),
            pressable: true,
            child: titleContent,
          ),
          actions: standaloneSearch ? const [] : widget.actions,
          forceCollapsed: searchOpen,
          collapseActions: widget.collapseActions,
        ),
      ),
    );

    // A fading BackdropFilter samples its own saveLayer and can flash black.
    // Fade a lightweight painted plate instead; restore live glass at rest.
    Widget flatPill(Widget child, double padding) => SizedBox(
      height: MobileUi.pillHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(MobileUi.pillRadius),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 0.7,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: padding),
          child: Center(widthFactor: 1, child: child),
        ),
      ),
    );

    Widget fadingNormal(double availableWidth) => Padding(
      padding: barPadding,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: flatPill(titleContent, MobileUi.titlePillPadH),
            ),
          ),
          if (!standaloneSearch && widget.actions.isNotEmpty) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(
                  MobileUi.pillHeight,
                  availableWidth - MobileUi.pillHeight * 2 - 8,
                ),
              ),
              child: flatPill(
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: widget.actions,
                  ),
                ),
                MobileUi.actionsPillPadH,
              ),
            ),
          ],
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        MobileUi.barInsetH,
        MediaQuery.paddingOf(context).top + MobileUi.barInsetTop,
        MobileUi.barInsetH,
        MobileUi.barInsetBottom,
      ),
      child: search == null
          ? normal
          : LayoutBuilder(
              builder: (context, constraints) {
                final screenWidth = math.max(
                  0.0,
                  MediaQuery.sizeOf(context).width - MobileUi.barInsetH * 2,
                );
                final availableWidth = math.min(
                  constraints.maxWidth,
                  screenWidth,
                );
                final contentWidth = search is MobileSearchPill
                    ? search.width
                    : MobileUi.searchPillWidth;
                final expandedWidth = math.min(
                  availableWidth,
                  math.max(
                    MobileUi.pillHeight,
                    contentWidth + _searchPadding * 2,
                  ),
                );
                final collapsedWidth = math.min(
                  MobileUi.pillHeight,
                  availableWidth,
                );
                return Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1,
                  child: SizedBox(
                    width: availableWidth,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ExcludeFocus(
                          excluding: searchOpen,
                          child: ExcludeSemantics(
                            excluding: searchOpen,
                            child: IgnorePointer(
                              ignoring: searchOpen,
                              child: TweenAnimationBuilder<double>(
                                key: const ValueKey('mobile_top_bar_normal'),
                                tween: Tween<double>(end: searchOpen ? 0 : 1),
                                duration: duration,
                                curve: Curves.easeOutCubic,
                                builder: (context, opacity, _) => opacity == 1
                                    ? normal
                                    : Opacity(
                                        key: const ValueKey(
                                          'mobile_top_bar_normal_fade',
                                        ),
                                        opacity: opacity,
                                        child: fadingNormal(availableWidth),
                                      ),
                              ),
                            ),
                          ),
                        ),
                        AnimatedPositioned(
                          key: const ValueKey('mobile_search_position'),
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          top: 0,
                          right: searchOpen
                              ? (availableWidth - expandedWidth) / 2
                              : 0,
                          width: searchOpen ? expandedWidth : collapsedWidth,
                          height: MobileUi.pillHeight,
                          onEnd: _finishSearchTransition,
                          child: Offstage(
                            offstage:
                                !standaloneSearch &&
                                !searchOpen &&
                                (duration == Duration.zero ||
                                    !_keepSearchSurface),
                            child: MobileGlassPill(
                              key: const ValueKey('mobile_search_surface'),
                              radius: MobileUi.pillRadius,
                              height: MobileUi.pillHeight,
                              padding: EdgeInsets.zero,
                              // Keep glass outside opacity layers so its backdrop stays live.
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ExcludeFocus(
                                    excluding: searchOpen,
                                    child: ExcludeSemantics(
                                      excluding: searchOpen,
                                      child: IgnorePointer(
                                        ignoring: searchOpen,
                                        child: AnimatedOpacity(
                                          key: const ValueKey(
                                            'mobile_search_collapsed_icon',
                                          ),
                                          opacity: searchOpen ? 0 : 1,
                                          duration: duration,
                                          child: Center(
                                            child: standaloneSearch
                                                ? Semantics(
                                                    key: const ValueKey(
                                                      'mobile_search_action_semantics',
                                                    ),
                                                    container: true,
                                                    button: true,
                                                    child: singleAction,
                                                  )
                                                : Icon(
                                                    Icons.search,
                                                    size:
                                                        MobileUi.actionIconSize,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.onSurface,
                                                  ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  IgnorePointer(
                                    ignoring: !searchOpen,
                                    child: ClipRect(
                                      child: OverflowBox(
                                        alignment: Alignment.centerRight,
                                        minWidth: expandedWidth,
                                        maxWidth: expandedWidth,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: _searchPadding,
                                          ),
                                          child: AnimatedOpacity(
                                            key: const ValueKey(
                                              'mobile_search_content',
                                            ),
                                            opacity: searchOpen ? 1 : 0,
                                            duration: duration,
                                            curve: Curves.easeOutCubic,
                                            child: searchOpen
                                                ? search
                                                : const SizedBox.shrink(),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// ═══════════════════════════════════════════════════════════════════════════
/// 统一搜索药丸内容 —— 主界面与设置页此前各写一份（含 6 个 border 的清零），
/// 这里收敛为唯一实现：[MobilePillTopBar.searchChild] 传它即可。
///
/// 默认宽度 [MobileUi.searchPillWidth]，窄屏按可用空间收缩；输入框不带 Material 边框，
/// 液态玻璃药丸就是容器。
/// ═══════════════════════════════════════════════════════════════════════════
class MobileSearchPill extends StatefulWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback onClose;
  final double width;

  const MobileSearchPill({
    super.key,
    this.controller,
    this.focusNode,
    required this.hint,
    this.onChanged,
    required this.onClose,
    this.width = MobileUi.searchPillWidth,
  });

  @override
  State<MobileSearchPill> createState() => _MobileSearchPillState();
}

class _MobileSearchPillState extends State<MobileSearchPill> {
  final _localFocus = FocusNode(debugLabel: 'Mobile search');
  FocusNode get _fieldFocus => widget.focusNode ?? _localFocus;

  @override
  void initState() {
    super.initState();
    // FocusScope.autofocus leaves an already focused control active. Opening
    // search explicitly moves focus to the newly mounted field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _fieldFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _localFocus.dispose();
    super.dispose();
  }

  void _close() {
    _fieldFocus.unfocus();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Focus(
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        width: math.min(
          widget.width,
          math.max(
            0.0,
            MediaQuery.sizeOf(context).width - MobileUi.barInsetH * 2,
          ),
        ),
        height: MobileUi.pillHeight,
        child: Row(
          children: [
            Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _fieldFocus,
                style: TextStyle(fontSize: 14, color: scheme.onSurface),
                cursorColor: scheme.onSurfaceVariant,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                  // filled 必须显式关掉：全局 InputDecorationTheme 是 filled: true +
                  // fillColor(surfaceContainerHighest/80)，这里不写 filled 就会继承它，
                  // 于是药丸内部多出一块暗色圆角矩形 —— 即用户反馈的
                  // 「设置与主界面的搜索框内怎么有个暗色的矩形」。
                  // 搜索框的容器是液态玻璃药丸本身，不需要任何填充。
                  filled: false,
                  // 显式清掉所有状态下的主题色边框：液态玻璃药丸本身就是容器，
                  // 不再让 Material3 给一个 primary 色的下划线 / 轮廓。
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onChanged: widget.onChanged,
              ),
            ),
            MobileGlassPillAction(
              icon: Icons.close,
              tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
              color: scheme.onSurfaceVariant,
              onTap: _close,
            ),
          ],
        ),
      ),
    );
  }
}

/// 分段药丸条目。
class MobilePillTab {
  /// 可选前置图标
  final IconData? icon;
  /// 主标签
  final String label;
  /// 可选数量角标（如「节点编辑器 12」）
  final String? badge;

  const MobilePillTab(this.label, {this.icon, this.badge});
}

/// ═══════════════════════════════════════════════════════════════════════════
/// 统一分段控件（顶部标签 / 过滤器）—— 玻璃药丸外壳 + 主题色滑动指示器。
///
/// 替换此前各页自绘的分段控件：
/// * 配置库「节点编辑器 / 快捷配置」自绘 Container + AnimatedPositioned；
/// * 日志页用 Material [FilterChip]（与应用药丸语言完全脱节）。
///
/// 等宽排布，选中项由 240ms easeOutCubic 的圆角指示器承载；外壳跟随
/// 「顶部药丸样式」（pillStyle 四值）。
/// ═══════════════════════════════════════════════════════════════════════════
class MobileSegmentedPills extends StatelessWidget {
  final List<MobilePillTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 外壳圆角（默认 24，配 4px 内边距）
  final double radius;
  final EdgeInsetsGeometry margin;

  const MobileSegmentedPills({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    this.radius = 24,
    this.margin = const EdgeInsets.fromLTRB(
        MobileUi.pagePaddingH, 12, MobileUi.pagePaddingH, 6),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (tabs.isEmpty) return const SizedBox.shrink();
    final index = selectedIndex.clamp(0, tabs.length - 1);

    return Container(
      margin: margin,
      child: MobileGlassPill(
        radius: radius,
        padding: const EdgeInsets.all(4),
        child: LayoutBuilder(builder: (ctx, cons) {
          final w = cons.maxWidth;
          final itemW = w / tabs.length;
          // 内层 32 + 外壳上下各 4 = 40，与原自绘分段条（配置库标签）等高，
          // 桌面端也不产生高度差。
          return SizedBox(
            height: 32,
            // 关键：Stack 默认 alignment 是 topStart，非定位的 Row 只拿 loose 约束、
            // 按自身内容高度（约 18px）贴在 32px 盒子顶部 —— 文字中心因此比指示器
            // 中心高约 7px，下方留白大于上方，看起来就是「选项文字偏上」。
            // 显式 center 让内容行与 32px 高的指示器同心。
            child: Stack(alignment: Alignment.center, children: [
              // 滑动指示器：随选中项在等宽分区之间平滑移动
              AnimatedPositioned(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                left: index * itemW,
                width: itemW,
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.primary.withAlpha(isDark ? 80 : 60),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: scheme.primary.withAlpha(110)),
                  ),
                ),
              ),
              Row(children: [
                for (var i = 0; i < tabs.length; i++)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onSelected(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (tabs[i].icon != null) ...[
                              Icon(tabs[i].icon,
                                  size: 15,
                                  color: i == index ? scheme.primary : scheme.outline),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                tabs[i].label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: i == index ? scheme.primary : scheme.outline,
                                ),
                              ),
                            ),
                            if (tabs[i].badge != null) ...[
                              const SizedBox(width: 5),
                              Text(
                                tabs[i].badge!,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: i == index
                                      ? scheme.primary.withAlpha(200)
                                      : scheme.outline.withAlpha(140),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ]),
            ]),
          );
        }),
      ),
    );
  }
}
