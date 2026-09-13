import 'package:flutter/material.dart';

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
/// 结构（与主界面一致）：
///   Padding(8, safeTop+6, 8, 6)
///     Stack(center)
///       ├ 常规层：[MobilePillBarLayout] —— 左标题药丸(44/22/pad14, 可按压)
///       │         + 间距 + 右操作药丸(44/22/pad6)；操作放不下时右半只留「…」，
///       │         点开向左展开（详见 MobilePillBarLayout 注释）
///       │         搜索时整体 220ms 淡出 + 缩放 0.9（仍占位）
///       └ 搜索层：同一颗搜索药丸 220ms 淡入 + 缩放 0.86→1.0（锚点居中），
///                 尺寸恒为 [MobileUi.searchPillWidth] × [MobileUi.pillHeight]
///
/// [searchChild] 为 null 时不启用搜索层（如配置库、队列页）。
/// ═══════════════════════════════════════════════════════════════════════════
class MobilePillTopBar extends StatelessWidget {
  /// 左标题药丸内容（文字 / 多选计数行等）
  final Widget title;

  /// 右操作药丸内容，通常是若干 [MobileGlassPillAction]
  final List<Widget> actions;

  /// 是否处于搜索态（仅当 [searchChild] 非空时生效）
  final bool searching;

  /// 搜索药丸内容（一般为 [MobileSearchPill]）
  final Widget? searchChild;

  const MobilePillTopBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.searching = false,
    this.searchChild,
  });

  /// 搜索层淡入淡出 + 缩放的时长（落在 180~220ms 区间；缩放与淡入共用一个时长，
  /// 不再像旧实现那样「220ms 淡入 + 320ms 变长」两条节奏互相打架）。
  static const Duration _fade = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    final search = searchChild;
    final hasSearch = search != null;
    final searchOpen = hasSearch && searching;

    final normal = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      // 左半标题药丸（占满剩余宽度、内容左对齐、长标题省略号收尾）+
      // 右半操作药丸；「左右原则」与操作溢出收纳统一交给 MobilePillBarLayout，
      // 本页不再自己判断宽度 / 拼 FittedBox。
      child: MobilePillBarLayout(
        titlePill: MobileGlassPill(
          radius: MobileUi.pillRadius,
          height: MobileUi.pillHeight,
          padding: const EdgeInsets.symmetric(horizontal: MobileUi.titlePillPadH),
          pressable: true,
          child: DefaultTextStyle.merge(
            style: MobileUi.titleStyle(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: title,
          ),
        ),
        actions: actions,
        // 搜索态下右侧不允许停留在「操作已展开」形态：搜索药丸会盖住它
        forceCollapsed: searchOpen,
      ),
    );

    final Widget body;
    if (!hasSearch) {
      body = normal;
    } else {
      body = Stack(alignment: Alignment.center, children: [
        AnimatedOpacity(
          opacity: searchOpen ? 0.0 : 1.0,
          duration: _fade,
          child: AnimatedScale(
            scale: searchOpen ? 0.9 : 1.0,
            duration: _fade,
            curve: Curves.easeOutCubic,
            child: IgnorePointer(ignoring: searchOpen, child: normal),
          ),
        ),
        AnimatedOpacity(
          opacity: searchOpen ? 1.0 : 0.0,
          duration: _fade,
          child: IgnorePointer(
            ignoring: !searchOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              // 展开动画 = 缩放 + 淡入：整颗药丸从 0.86 放大到 1.0 出现，
              // 不再像旧实现那样把同一颗 44px 药丸横向拉到 [MobileUi.searchPillWidth]
              // （宽度突变时边框与内边距像被「两把刀」左右撕开）。
              // 锚点取 center：药丸本身在顶栏里水平居中，从中心放大最自然。
              child: AnimatedScale(
                scale: searchOpen ? 1.0 : 0.86,
                alignment: Alignment.center,
                duration: _fade,
                curve: Curves.easeOutCubic,
                child: MobileGlassPill(
                  radius: MobileUi.pillRadius,
                  // 只留水平内边距：药丸总高 = MobileUi.pillHeight(44)，与标题 /
                  // 操作药丸严格等高（旧的 vertical 内边距会让它高出 4px）。
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  // 收起态只换内容、不换外壳尺寸：宽度恒为 MobileUi.searchPillWidth，
                  // 缩放期间零布局跳动；同时避免空闲时也构建 autofocus 的 TextField
                  // （那会在页面首帧抢走输入焦点）。
                  child: searchOpen
                      ? search
                      : const SizedBox(
                          width: MobileUi.searchPillWidth,
                          height: MobileUi.pillHeight,
                        ),
                ),
              ),
            ),
          ),
        ),
      ]);
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        MobileUi.barInsetH,
        safeTop + MobileUi.barInsetTop,
        MobileUi.barInsetH,
        MobileUi.barInsetBottom,
      ),
      child: body,
    );
  }
}

/// ═══════════════════════════════════════════════════════════════════════════
/// 统一搜索药丸内容 —— 主界面与设置页此前各写一份（含 6 个 border 的清零），
/// 这里收敛为唯一实现：[MobilePillTopBar.searchChild] 传它即可。
///
/// 尺寸固定 [MobileUi.searchPillWidth] × 44；输入框自身不带任何 Material 边框，
/// 液态玻璃药丸就是容器。
/// ═══════════════════════════════════════════════════════════════════════════
class MobileSearchPill extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: MobileUi.pillHeight,
      child: Row(children: [
        Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            cursorColor: scheme.onSurfaceVariant,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
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
            onChanged: onChanged,
          ),
        ),
        MobileGlassPillAction(
          icon: Icons.close,
          tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
          color: scheme.onSurfaceVariant,
          onTap: onClose,
        ),
      ]),
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
