import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
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
    final cfg = context.watch<AppState>().config;
    final op = cfg.cardOpacity.clamp(0.0, 1.0);
    final style = cfg.pillStyle;

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

/// 移动端「二级页面」顶栏：左上角圆形玻璃返回按钮 + 右上角标题药丸（+ 可选操作药丸）。
/// 用于设置二级菜单、命令、日志等 push 出来的子页面。
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
      padding: EdgeInsets.fromLTRB(12, safeTop + 6, 12, 6),
      child: Row(children: [
        // 左：圆形玻璃返回按钮（44×44、radius 22 = 正圆）
        MobileGlassPill(
          radius: 22,
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              icon: Icon(Icons.arrow_back, size: 22, color: scheme.onSurface),
              tooltip: 'back',
              onPressed: onBack ?? () => Navigator.of(context).maybePop(),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
        const Spacer(),
        if (actions.isNotEmpty) ...[
          MobileGlassPill(
            radius: 22,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(children: actions),
          ),
          const SizedBox(width: 8),
        ],
        // 右：标题药丸（高度 44，与左侧圆形返回按钮、操作药丸对齐）
        MobileGlassPill(
          radius: 22,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
            child: title,
          ),
        ),
      ]),
    );
  }
}