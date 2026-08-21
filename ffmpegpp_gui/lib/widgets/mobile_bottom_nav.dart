import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

/// 移动端悬浮玻璃底部导航栏 —— 减少复杂光效，保留通透感。
///
/// 与原版区别：
/// - 单层 BackdropFilter 模糊（sigma 20，原 30）
/// - 纯色半透明背景（原双色渐变），通透感由低透明度实现
/// - 去除 SweepGradient 边缘折射高光与底部内阴影（CustomPainter）
/// - 单层柔阴影（原双层）
/// - 选中遮罩使用单色 tonal 色（surfaceContainerHighest + primary 着色），
///   去除内层 BackdropFilter 与渐变色，减少视觉噪点
/// - 遮罩移动：选中项由一个可拖动的胶囊遮罩表达 —— 水平拖动遮罩（或整条
///   导航栏），松手后吸附到最近的导航项并跳转。
class MobileBottomNav extends StatefulWidget {
  /// 当前选中的「全局页索引」（见 AppShell._page：0 项目 / 1 队列 /
  /// 3 配置库 / 4 设置）。命令(2) 与 日志(5) 已移入设置，不在底部栏。
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const MobileBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  State<MobileBottomNav> createState() => _MobileBottomNavState();
}

class _MobileBottomNavState extends State<MobileBottomNav> {
  static const _anim = Duration(milliseconds: 260);
  static const _curve = Curves.easeInOutCubic;
  static const _barHeight = 62.0;
  static const _radius = 30.0;
  static const _maskRadius = 20.0;

  /// 遮罩拖动中的临时 left 偏移（null = 未拖动）
  double? _maskDragLeft;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lang = context.watch<AppState>().config.language;
    final s = AppStrings.of(lang);

    final items = <({int page, IconData icon, IconData iconFilled, String label})>[
      (page: 0, icon: Icons.movie_outlined, iconFilled: Icons.movie, label: s.navProjects),
      (page: 1, icon: Icons.list_alt_outlined, iconFilled: Icons.list_alt, label: s.navQueue),
      (page: 3, icon: Icons.folder_copy_outlined, iconFilled: Icons.folder_copy, label: lang == 'zh' ? '配置库' : 'Configs'),
      (page: 4, icon: Icons.settings_outlined, iconFilled: Icons.settings, label: s.navSettings),
    ];

    final localSel = items.indexWhere((it) => it.page == widget.selectedIndex);
    // 当前页不在导航项内（如命令页/日志页）时不再回退高亮第 0 项，避免误导
    final sel = localSel < 0 ? -1 : localSel;

    // 遮罩色：surfaceContainerHighest 叠加 primary 着色，单色（无渐变、无内模糊）
    final maskColor = Color.lerp(scheme.secondaryContainer, scheme.primary, 0.25)!.withValues(alpha: 0.85);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
        child: Container(
          height: _barHeight,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            // 单层柔阴影，去除了双层阴影中的贴身小阴影
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(isDark ? 60 : 20),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius - 2),
            child: BackdropFilter(
              // 降低模糊强度：sigma 20（原 30），减少性能开销与辉光畸变
              filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: BoxDecoration(
                  // 纯色半透明背景（原双色渐变），通透感由低 alpha 维持
                  color: scheme.surface.withAlpha(isDark ? 120 : 100),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.24),
                    width: 0.6,
                  ),
                ),
                child: SizedBox(
                  height: _barHeight,
                  child: LayoutBuilder(builder: (context, cons) {
                    final w = cons.maxWidth;
                    final itemW = w / items.length;

                    // 测量最长标签的实际宽度，让遮罩与元素（图标+文字）长度一致
                    final labelStyle = const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w600);
                    double maxLabelW = 0;
                    for (final it in items) {
                      final tp = TextPainter(
                        text: TextSpan(text: it.label, style: labelStyle),
                        textDirection: TextDirection.ltr,
                        maxLines: 1,
                      )..layout();
                      if (tp.width > maxLabelW) maxLabelW = tp.width;
                    }
                    // 元素宽度 = max(图标 22, 最长标签) + 左右留白；不超出单元格
                    final elementW =
                        (math.max(22.0, maxLabelW) + 12).clamp(0.0, itemW - 4);
                    final centerOff = (itemW - elementW) / 2;
                    final maskLeft = (_maskDragLeft ?? sel * itemW + centerOff)
                        .clamp(centerOff,
                            (items.length - 1) * itemW + centerOff);

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // 遮罩移动：整条导航栏可水平拖动
                      onHorizontalDragStart: (_) {
                        setState(
                            () => _maskDragLeft = sel * itemW + centerOff);
                      },
                      onHorizontalDragUpdate: (d) {
                        setState(() {
                          _maskDragLeft =
                              (_maskDragLeft ?? sel * itemW + centerOff) +
                                  d.delta.dx;
                        });
                      },
                      onHorizontalDragEnd: (_) {
                        final t = _maskDragLeft;
                        if (t == null) return;
                        final idx = ((t - centerOff) / itemW)
                            .round()
                            .clamp(0, items.length - 1);
                        setState(() => _maskDragLeft = null);
                        if (idx != sel) {
                          widget.onSelected(items[idx].page);
                        }
                      },
                      onHorizontalDragCancel: () =>
                          setState(() => _maskDragLeft = null),
                      child: Stack(children: [
                        // 滑动遮罩：单色 tonal 胶囊，无内模糊、无渐变
                        AnimatedPositioned(
                          duration: _maskDragLeft == null
                              ? _anim
                              : Duration.zero,
                          curve: _curve,
                          left: maskLeft,
                          top: 8,
                          bottom: 8,
                          width: elementW,
                          child: Container(
                            decoration: BoxDecoration(
                              color: maskColor,
                              borderRadius:
                                  BorderRadius.circular(_maskRadius),
                              boxShadow: [
                                BoxShadow(
                                  color: scheme.primary
                                      .withAlpha(isDark ? 60 : 35),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Row(children: [
                          for (var i = 0; i < items.length; i++)
                            Expanded(
                              child: _item(
                                scheme,
                                items[i],
                                i == sel,
                                () => widget.onSelected(items[i].page),
                              ),
                            ),
                        ]),
                      ]),
                    );
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(
    ColorScheme scheme,
    ({int page, IconData icon, IconData iconFilled, String label}) item,
    bool selected,
    VoidCallback onTap,
  ) {
    final clr = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 选中项：实心图标 + 轻微放大；未选中：描边图标 + 缩小
          AnimatedScale(
            scale: selected ? 1.06 : 0.88,
            duration: _anim,
            curve: _curve,
            child: AnimatedSwitcher(
              duration: _anim,
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: Icon(
                selected ? item.iconFilled : item.icon,
                key: ValueKey(selected),
                size: 22,
                color: clr,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: clr,
            ),
          ),
        ],
      ),
    );
  }
}
