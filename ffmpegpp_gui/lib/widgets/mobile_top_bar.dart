import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import 'mobile_glass_pill.dart';

/// 移动端通用顶栏 —— 简洁全宽背景模糊 + 标题 + 操作按钮。
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
    final follow = cfg.glassFollowTheme;
    final baseColor = follow ? scheme.primary : scheme.surface;

    // 背景透明度（略降低以更通透）
    final bgAlpha = ((isDark ? 155 : 175) * op).round().clamp(0, 255);

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          // 状态栏高度在容器内，内容区高度固定为 height
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          decoration: BoxDecoration(
            color: baseColor.withAlpha(bgAlpha),
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
        ),
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
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(children: actions),
          ),
          const SizedBox(width: 8),
        ],
        // 右：标题药丸
        MobileGlassPill(
          radius: 22,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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