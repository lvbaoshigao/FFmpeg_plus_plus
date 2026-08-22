import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

/// 移动端通用模糊顶栏 —— 悬浮玻璃条（两侧留边 + 圆角）。
///
/// 视觉：全宽透明背景（含状态栏区域），内部圆角模糊条居中悬浮，
/// 两侧与底部留边，配合 Liquid Glass 通透感。
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

    return Container(
      // 状态栏高度在容器内
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      // 左右留边 + 底部留空，让顶栏悬浮
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              decoration: BoxDecoration(
                color: baseColor.withAlpha(bgAlpha),
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.10 : 0.22),
                  width: 0.6,
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
        ),
      ),
    );
  }
}