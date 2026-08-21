import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

/// 移动端通用模糊顶栏 —— 简洁全宽背景模糊 + 标题 + 操作按钮。
///
/// 去除了按钮的液态玻璃包装（原 wrapButton 在 liquid 模式下套 GlassPanel），
/// 顶栏整体已提供背景模糊，按钮单独套玻璃会产生双重光效噪点。
class MobileTopBar extends StatelessWidget {
  final Widget title;
  final List<Widget> actions;
  final double height;

  const MobileTopBar({
    super.key,
    required this.title,
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