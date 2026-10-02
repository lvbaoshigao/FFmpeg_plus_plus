import 'package:flutter/material.dart';
// Esc 收起溢出操作（桌面端键盘可达）；只取需要的两个名字，避免整包 services 泄漏到本文件。
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import '../theme/mobile_ui.dart';
import 'mobile_glass_pill.dart';

/// 移动端顶栏组件集：药丸布局层 [MobilePillBarLayout] + 二级页顶栏
/// [MobileSubPageTopBar]（主 Tab 页用的 `MobilePillTopBar` 在 mobile_ui.dart）。
///
/// 原 `MobileTopBar`（全宽背景模糊 + 标题 + 操作）已于 2026-09-18 删除：
/// 它只是 [GlassTopBar] 的移动端分支，而全部 `GlassTopBar` 调用点都先按
/// `isMobilePlatform` 分流，该分支永远不可达（死代码）；且它用的是裸
/// `scheme.primary` / `surfaceContainerHigh`，与全局 harmonizedAccent /
/// neutralGray 约定不一致，留着只会误导后来者照抄。

/// 药丸顶栏里各药丸之间的横向间距（标题药丸 ↔ 操作药丸、返回钮 ↔ 标题药丸）。
const double _pillBarGap = 8;

/// 溢出展开 / 收起动画时长：落在「180~220ms」区间，与仓库其它顶栏过渡同拍。
const Duration _overflowDuration = Duration(milliseconds: 200);

/// 标题药丸在「是否溢出」判定里的保底可读宽度 = 44 × 2 = 88（约 4 个中文字符）。
/// 低于它标题就只剩省略号，此时宁可把操作收进「…」也不挤掉标题。
const double _titlePillMinWidth = MobileUi.pillHeight * 2;

/// 右半「行内直排操作」的最大数量：超过它就把操作全部收进「…」。
///
/// 用户规则（优先于宽度判定，条数上限见 [MobilePillBarLayout.inlineActionLimit]）：
/// * 不超过上限 → 左标题 / 右操作，左右排布，直接平铺；
/// * 超过上限 → 左半只保留一个药丸（存在返回按钮时优先保留返回按钮），
///   右半只保留一颗「…」，其余操作收进浮层；点「…」后左半滑出隐藏、
///   全部操作自右向左滑入，图标 … 变 →，再点收起。
///
/// 宽度判定依然保留（作为兜底）：极窄屏 / 超长标题时即使条数没超，
/// 也会收进「…」，避免标题被挤成一个省略号。（`collapseActions = false` 时
/// 这两条规则都不生效，见该字段说明。）
const int _maxInlineActions = 2;

/// 估算单个操作控件的自然宽度，供溢出判定使用。
///
/// 为什么是「估算」而不是真测量：顶栏必须在自己的 build 阶段就决定
/// 「全部显示还是收进 …」，此时子控件尚未布局，拿不到真实尺寸；
/// 而顶栏里能出现的操作只有两类，宽度都能从它们的声明参数精确推出：
/// * [MobileGlassPillAction]：固定 [MobileGlassPillAction.size]（34）+ 水平内边距；
/// * [PopupMenuButton]：各调用点都按 34×34 声明（padding: zero + 19px 图标）；
/// 其它未知控件按 [MobileUi.pillHeight]（44，一行里最宽的常规药丸）保守估算 ——
/// 估大只会让「…」更早出现，绝不会横向溢出（RenderFlex overflow）。
double _estimateActionWidth(Widget action) {
  if (action is MobileGlassPillAction) {
    // 默认水平内边距移动端 1 / 桌面端 2，这里统一按 2 计，误差 ≤ 2px/项。
    return action.size + (action.padding?.horizontal ?? 2);
  }
  if (action is PopupMenuButton) return MobileUi.actionButtonSize;
  return MobileUi.pillHeight;
}

/// ═══════════════════════════════════════════════════════════════════════════
/// 药丸顶栏的「左半 / 右半 + 操作溢出收纳」布局 ——
/// [MobileSubPageTopBar] 与 [MobilePillTopBar] 共用的实现，页面不直接使用。
///
/// 硬规则（用户要求的「严格左右原则」）：
/// * 左半只放返回 / 标题文字，右半只放操作 / 设置项，两者永不互换、永不混排；
/// * 操作放不下时右半只保留一颗「…」触发药丸，其余操作全部隐藏；
/// * 点「…」展开：全部操作自右向左滑入，同时左半（返回 + 标题）向左滑出并淡出，
///   触发药丸图标 … 变 →；再点它 / 点空白处 / Esc 均收回原状。
///
/// 为什么不再用 FittedBox 压扁：旧实现让整排按钮等比缩小，动作一多图标就挤成
/// 小点、长标题还会被顶掉 ——「显示得下」并不等于「看得清、点得着」。
///
/// 溢出判定基于 [LayoutBuilder] 给出的**真实可用宽度**，不写死条数阈值：
///   需要宽度 = 左半保底宽度 + 间距 + (各操作估算宽度之和 + 操作药丸左右内边距)
/// ═══════════════════════════════════════════════════════════════════════════
class MobilePillBarLayout extends StatefulWidget {
  /// 左半：返回圆钮（主 Tab 页没有返回，传 null）
  final Widget? leading;

  /// 左半：已完成药丸包装的标题（本组件负责放进 Expanded 并左对齐）
  final Widget titlePill;

  /// 右半：全部操作；放不下时收进「…」
  final List<Widget> actions;

  /// 外部原因强制收起（如主 Tab 页进入搜索态，右侧不允许停留展开态）
  final bool forceCollapsed;

  /// 是否允许把放不下的操作收进「…」。
  ///
  /// 默认 true（条数 > [inlineActionLimit] 一律收起）。**主界面**（各 Tab 主页）
  /// 传 false：操作全部 inline 挤在同一颗药丸里，不再出现「…」—— 用户反馈
  /// 「主界面不要搞...了(右上角药丸样式不用折叠，因为项挤在一个药丸里比较合适)」。
  final bool collapseActions;

  /// 允许直接平铺的操作条数上限（超过就收进「…」）。
  ///
  /// * 主界面（左半无返回键）：取默认值 [_maxInlineActions] = 2；
  /// * 二级页（左半有返回键）：传 1 —— 用户规则「如果有两个就遵循一个放左上一个
  ///   放右上；如大于两个选项就返回键放左上，其他选项折叠起来成...放在右上角」，
  ///   即**返回键本身算一个药丸**，总数 > 2 才折叠。
  final int inlineActionLimit;

  const MobilePillBarLayout({
    super.key,
    this.leading,
    required this.titlePill,
    this.actions = const [],
    this.forceCollapsed = false,
    this.collapseActions = true,
    this.inlineActionLimit = _maxInlineActions,
  });

  @override
  State<MobilePillBarLayout> createState() => _MobilePillBarLayoutState();
}

class _MobilePillBarLayoutState extends State<MobilePillBarLayout>
    with SingleTickerProviderStateMixin {
  /// 右半操作是否已展开（只在「确实放不下」的状态下才可能为 true）
  bool _expanded = false;

  /// 0 = 左半可见、操作收在「…」里；1 = 左半已隐藏、全部操作已滑入。
  ///
  /// ⚠️ 不能写成 `late final AnimationController _controller = AnimationController(...)`
  /// —— late 字段是惰性初始化：若 widget 在首次使用动画前就被卸载，
  /// [dispose] 里的访问会在 unmount 阶段触发初始化（`createTicker` → 查询
  /// TickerMode 祖先），抛 "Looking up a deactivated widget's ancestor is unsafe"
  /// （widget 测试整包运行时必现，release 则泄漏一个未挂接的 ticker）。
  AnimationController? _controllerInstance;

  AnimationController get _controller => _controllerInstance ??= AnimationController(
    vsync: this,
    duration: _overflowDuration,
    reverseDuration: _overflowDuration,
  );

  /// 用 drive(CurveTween) 而不是 CurvedAnimation：不需要额外释放，且正反两个
  /// 方向都走同一条 easeOutCubic。
  Animation<double>? _progressInstance;

  Animation<double> get _progress =>
      _progressInstance ??= _controller.drive(CurveTween(curve: Curves.easeOutCubic));

  /// Esc 只有在拥有键盘焦点时才会派发到 [Focus.onKeyEvent]，展开时把焦点收过来。
  final FocusNode _focusNode = FocusNode(debugLabel: 'MobilePillBarLayout');

  /// 展开前的主焦点：收起时还回去，避免抢走 App 级快捷键 Focus
  /// （app.dart 的 Focus(autofocus: true, onKeyEvent: _handleGlobalKey)）导致全局快捷键失效。
  FocusNode? _previousFocus;

  @override
  void didUpdateWidget(covariant MobilePillBarLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部强制收起（搜索态）或操作数量变化：回到收起态。
    // 此处正处在 rebuild 中，改字段即可，不需要（也不应该）再 setState。
    if (_expanded &&
        (widget.forceCollapsed || oldWidget.actions.length != widget.actions.length)) {
      _collapse(fromUpdate: true);
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    // 只释放已创建的实例：未创建过就直接跳过（切勿触发惰性初始化，见上方注释）。
    _controllerInstance?.dispose();
    super.dispose();
  }

  void _expand() {
    if (_expanded) return;
    setState(() => _expanded = true);
    _previousFocus = FocusManager.instance.primaryFocus;
    _focusNode.requestFocus();
    _controller.forward();
  }

  /// 收起。[fromUpdate] = true 表示在 didUpdateWidget 内调用（重建已在进行）。
  void _collapse({bool fromUpdate = false}) {
    if (!_expanded) return;
    if (fromUpdate) {
      _expanded = false;
    } else {
      setState(() => _expanded = false);
    }
    _controller.reverse();
    final previous = _previousFocus;
    _previousFocus = null;
    if (previous != null && previous.canRequestFocus) {
      previous.requestFocus();
    } else if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    }
  }

  void _toggle() => _expanded ? _collapse() : _expand();

  /// Esc 收起。必须返回 handled，否则按键继续冒泡到 App 级快捷键 / 页面关闭。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _collapse();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 左半：返回圆钮（可选）+ 标题药丸；标题药丸占满剩余宽度并左对齐。
  Widget _leadingHalf() => Row(children: [
        if (widget.leading != null) ...[
          widget.leading!,
          const SizedBox(width: _pillBarGap),
        ],
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: widget.titlePill),
        ),
      ]);

  /// 操作药丸：44 高、左右内边距 6，内容用 FittedBox 兜底
  /// （极端窄屏等比缩小，而不是横向溢出）。
  Widget _actionsPill(List<Widget> actions) => MobileGlassPill(
        radius: MobileUi.pillRadius,
        height: MobileUi.pillHeight,
        padding: const EdgeInsets.symmetric(horizontal: MobileUi.actionsPillPadH),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, children: actions),
        ),
      );

  /// 真实可用宽度是否容不下全部操作（= 是否要把操作收进「…」）。
  ///
  /// 判定顺序：
  ///  1. 条数规则（用户要求，优先）：操作多于 [._maxInlineActions] 个 → 收起；
  ///  2. 宽度兜底：即使只有 1~2 个操作，窄屏 + 长标题下也收起，保证标题可读。
  ///
  /// [MobilePillTopBar.collapseActions] 为 false 时**两条规则都不生效**：操作
  /// 一律inline 展示（用户要求「配置库右上角的药丸不要折叠」）。这种页面操作
  /// 数量固定且不多，极端窄屏由 _actionsPill 里的 FittedBox 等比缩小兜底。
  bool _needsOverflow(double availableWidth) {
    if (!widget.collapseActions) return false;
    if (widget.actions.isEmpty || !availableWidth.isFinite) return false;
    if (widget.actions.length > widget.inlineActionLimit) return true;
    final actionsWidth = MobileUi.actionsPillPadH * 2 +
        widget.actions.fold<double>(0, (sum, a) => sum + _estimateActionWidth(a));
    final leadingMin = _titlePillMinWidth +
        (widget.leading == null ? 0.0 : MobileUi.pillHeight + _pillBarGap);
    return leadingMin + _pillBarGap + actionsWidth > availableWidth;
  }

  /// 放得下：保持原来的「左半 + 间距 + 右半」一行，不引入任何额外动画层。
  Widget _plainRow() => Row(children: [
        Expanded(child: _leadingHalf()),
        if (widget.actions.isNotEmpty) ...[
          const SizedBox(width: _pillBarGap),
          _actionsPill(widget.actions),
        ],
      ]);

  /// 放不下：右半只留「…」；展开后左半滑出、全部操作自右向左滑入。
  Widget _overflowRow() => Row(children: [
        Expanded(
          // ClipRect 让滑入的操作「从药丸边缘切进来」而不是飞到药丸外面。
          child: ClipRect(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 左半：展开时向左滑出 + 淡出（即「隐藏左半边的选项」）
                SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset.zero,
                    end: const Offset(-0.35, 0),
                  ).animate(_progress),
                  child: FadeTransition(
                    opacity: ReverseAnimation(_progress),
                    child: IgnorePointer(ignoring: _expanded, child: _leadingHalf()),
                  ),
                ),
                // 右半全部操作：收起时停在药丸外侧（被 ClipRect 裁掉），
                // 展开时从右向左滑入 —— 就是「向左切入」。
                SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(1.05, 0),
                    end: Offset.zero,
                  ).animate(_progress),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: IgnorePointer(
                      ignoring: !_expanded,
                      child: _actionsPill(widget.actions),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: _pillBarGap),
        _triggerPill(context),
      ]);

  /// 溢出触发药丸：收起时是「…」，展开后变「→」（同一颗药丸，位置固定不动）。
  ///
  /// 为什么不复用 [MobileGlassPillAction]：它内部写死一颗 [Icon]，装不下
  /// 「… ⇄ →」的切换动画；这里按它的同一规格手写按钮（34×34 圆形、透明涟漪），
  /// 只在图标位放 AnimatedSwitcher，观感与其它操作按钮一致。
  ///
  /// 尺寸：药丸**必须是正圆**（用户反馈「你这个更多选项药丸不是圆的」）。
  /// 做法是让药丸总宽 = 总高：内边距取 (44 - 34) / 2 = 5，5 + 34 + 5 = 44，
  /// 配上 radius = pillHeight / 2 = 22 就是直径 44 的正圆。旧写法用了
  /// [MobileUi.actionsPillPadH]（6）+ 内层 1px 内边距 → 48 × 44，是个扁圆角矩形。
  Widget _triggerPill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return MobileGlassPill(
      radius: MobileUi.pillRadius,
      height: MobileUi.pillHeight,
      padding: const EdgeInsets.symmetric(
          horizontal: (MobileUi.pillHeight - MobileUi.actionButtonSize) / 2),
      child: Tooltip(
        message: _expanded
            ? (zh ? '收起' : 'Collapse')
            : (zh ? '更多操作' : 'More actions'),
        child: InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(MobileUi.actionButtonSize / 2),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: SizedBox(
            width: MobileUi.actionButtonSize,
            height: MobileUi.actionButtonSize,
            child: AnimatedSwitcher(
              duration: _overflowDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: Icon(
                _expanded ? Icons.arrow_forward : Icons.more_horiz,
                key: ValueKey<bool>(_expanded),
                size: MobileUi.actionIconSize,
                color: scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final overflow = _needsOverflow(constraints.maxWidth);
      if (!overflow && _expanded) {
        // 宽度又够了（旋转 / 分屏 / 操作变少）：自动收回。
        // build 阶段不能 setState，推迟到本帧结束。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _collapse();
        });
      }
      // TapRegion（点空白处收起）与 Focus（Esc 收起）都是纯代理盒子，
      // 不影响布局；常驻可避免展开瞬间才挂载导致 requestFocus 落空。
      return TapRegion(
        onTapOutside: (_) {
          if (_expanded) _collapse();
        },
        child: Focus(
          focusNode: _focusNode,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: overflow ? _overflowRow() : _plainRow(),
        ),
      );
    });
  }
}

/// 移动端「二级页面」统一顶栏 —— 与主界面同一套药丸语言：
/// 左圆形玻璃返回按钮 + 标题药丸（**左对齐，与主界面一致**）+ 右操作药丸。
///
/// 用于设置二级菜单、命令、日志、容器详情、AI 设置等 push 出来的子页面。
///
/// 此前标题药丸靠右，与主界面「标题在左」相反，且各二级页各自拼装
/// （日志页甚至手写了一份完全不同的布局）；这里收敛为唯一实现：
/// * 返回按钮：44×44 正圆药丸，内部用 [MobileGlassPillAction]（透明涟漪），
///   不再用自带 48×48 最小尺寸的 Material IconButton；
/// * 标题药丸：44 高、radius 22、内边距 14，占据剩余宽度、超长省略；
/// * 操作药丸：44 高、内边距 6，内部请放 [MobileGlassPillAction]。
///
/// 「左右原则」由 [MobilePillBarLayout] 强制：任何状态下左半只放返回 + 标题、
/// 右半只放操作。
///
/// 折叠阈值 = 1（`inlineActionLimit: 1`）：**返回键算一个药丸**，所以
/// 「返回 + 1 个操作」= 两个 → 一个左上、一个右上，直接平铺；操作 ≥ 2
/// （总数 > 2）→ 返回键留左上，其余全部收进右上「…」。用户原话：
/// 「如果有两个就遵循一个放左上一个放右上。如大于两个选项就返回键放左上，
/// 其他选项折叠起来成...放在右上角」。
class MobileSubPageTopBar extends StatelessWidget {
  final Widget title;
  final List<Widget> actions;
  final VoidCallback? onBack;

  const MobileSubPageTopBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final safeTop = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        MobileUi.barInsetH,
        safeTop + MobileUi.barInsetTop,
        MobileUi.barInsetH,
        MobileUi.barInsetBottom,
      ),
      child: MobilePillBarLayout(
        // 返回键占掉「两个」里的一个（见类文档），故操作上限为 1。
        inlineActionLimit: 1,
        // 左：圆形玻璃返回按钮（44×44、radius 22 = 正圆）
        leading: MobileGlassPill(
          radius: MobileUi.pillRadius,
          padding: EdgeInsets.zero,
          child: MobileGlassPillAction(
            icon: Icons.arrow_back,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            color: scheme.onSurface,
            size: MobileUi.pillHeight,
            iconSize: 22,
            padding: EdgeInsets.zero,
            onTap: onBack ?? () => Navigator.of(context).maybePop(),
          ),
        ),
        // 中：标题药丸，左对齐并占据剩余宽度（与主界面一致）
        titlePill: MobileGlassPill(
          radius: MobileUi.pillRadius,
          height: MobileUi.pillHeight,
          padding: const EdgeInsets.symmetric(horizontal: MobileUi.titlePillPadH),
          child: DefaultTextStyle.merge(
            style: MobileUi.titleStyle(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: title,
          ),
        ),
        // 右：操作药丸（高度 44，与返回按钮、标题药丸对齐）
        actions: actions,
      ),
    );
  }
}
