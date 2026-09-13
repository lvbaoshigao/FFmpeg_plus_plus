import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/mobile_ui.dart';
import 'app_card.dart' show SurfaceStyle;
import 'mobile_glass_pill.dart';

/// 移动端通用顶栏 —— 简洁全宽背景模糊 + 标题 + 操作按钮。
///
/// 样式由「顶部药丸样式」（AppConfig.pillStyle）接管：
/// - liquid / blur：全宽背景模糊 + 半透明 surface 底色
/// - theme / gray：纯色顶栏（跟随主题色 / 灰色），不做背景模糊
///
/// 去除了按钮的液态玻璃包装（原 wrapButton 在 liquid 模式下套 GlassPanel），
/// 顶栏整体已提供背景模糊，按钮单独套玻璃会产生双重光效噪点。
class MobileTopBar extends StatelessWidget {
  final Widget title;
  final Widget? leading;
  final List<Widget> actions;
  final double height;

  const MobileTopBar({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final op = context.select<AppState, double>((s) => s.config.cardOpacity).clamp(0.0, 1.0);
    final style = context.select<AppState, String>((s) => s.config.pillStyle);

    // 顶栏内容（状态栏高度在容器内，内容区高度固定为 height）
    Widget barBody(Color bg) => Container(
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withAlpha(30),
                width: 0.5,
              ),
            ),
          ),
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 4),
                ] else
                  const SizedBox(width: 8),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                    child: title,
                  ),
                ),
                // 按钮直接放置，不再套 GlassPanel 产生双重光效
                ...actions,
                const SizedBox(width: 4),
              ]),
            ),
          ),
        );

    // theme/gray：纯色顶栏（无背景模糊）。纯色语义即实心：完全不透明，
    // 不跟随 cardOpacity（此前 ~92% 保底仍透底）
    if (style == SurfaceStyle.theme || style == SurfaceStyle.gray) {
      final base = style == SurfaceStyle.theme ? scheme.primary : scheme.surfaceContainerHigh;
      const int alpha = 255;
      return barBody(base.withAlpha(alpha));
    }

    // liquid/blur：背景模糊 + 半透明 surface 底色（略降低以更通透）
    final bgAlpha = ((isDark ? 155 : 175) * op).round().clamp(0, 255);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: barBody(scheme.surface.withAlpha(bgAlpha)),
      ),
    );
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
      child: Row(children: [
        // 左：圆形玻璃返回按钮（44×44、radius 22 = 正圆）
        MobileGlassPill(
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
        const SizedBox(width: 8),
        // 中：标题药丸，左对齐并占据剩余宽度（与主界面一致）
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: MobileGlassPill(
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
          ),
        ),
        // 右：操作药丸（高度 44，与返回按钮、标题药丸对齐）
        if (actions.isNotEmpty) ...[
          const SizedBox(width: 8),
          MobileGlassPill(
            radius: MobileUi.pillRadius,
            height: MobileUi.pillHeight,
            padding: const EdgeInsets.symmetric(horizontal: MobileUi.actionsPillPadH),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
          ),
        ],
      ]),
    );
  }
}