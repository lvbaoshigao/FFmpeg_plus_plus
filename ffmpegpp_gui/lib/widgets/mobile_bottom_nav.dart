import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

/// 移动端底部液态玻璃导航栏。
///
/// - 液态玻璃：BackdropFilter 背景模糊 + 半透明渐变 + 边缘高光/反光/底影
///   （复用与 PC 侧边栏一致的光影语言）。
/// - 遮罩移动：选中项由一个可拖动的胶囊遮罩表达 —— 水平拖动遮罩（或整条
///   导航栏），松手后吸附到最近的导航项并跳转。逻辑与 PC 侧边栏
///   （sidebar.dart 的 _maskDragTop）完全一致，只是方向改为水平。
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
  static const _barHeight = 60.0;

  /// 遮罩拖动中的临时 left 偏移（null = 未拖动）
  double? _maskDragLeft;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lang = context.watch<AppState>().config.language;
    final s = AppStrings.of(lang);

    final items = <({int page, IconData icon, String label})>[
      (page: 0, icon: Icons.movie_outlined, label: s.navProjects),
      (page: 1, icon: Icons.list_alt_outlined, label: s.navQueue),
      (page: 3, icon: Icons.folder_copy_outlined, label: lang == 'zh' ? '配置库' : 'Configs'),
      (page: 4, icon: Icons.settings_outlined, label: s.navSettings),
    ];

    final localSel = items.indexWhere((it) => it.page == widget.selectedIndex);
    final sel = localSel < 0 ? 0 : localSel;

    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(isDark ? 70 : 32),
            blurRadius: 22,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.surface.withAlpha(isDark ? 178 : 200),
                  scheme.surface.withAlpha(isDark ? 132 : 150),
                ],
              ),
              border: Border(
                top: BorderSide(
                  color: scheme.outlineVariant.withAlpha(isDark ? 70 : 100),
                  width: 0.7,
                ),
              ),
            ),
            child: CustomPaint(
              painter: _BottomGlassPainter(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: _barHeight,
                  child: LayoutBuilder(builder: (context, cons) {
                    final w = cons.maxWidth;
                    final itemW = w / items.length;

                    // 测量最长标签的实际宽度，让遮罩与元素（图标+文字）长度一致
                    final labelStyle = const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600);
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
                        .clamp(centerOff, (items.length - 1) * itemW + centerOff);

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // 遮罩移动：整条导航栏可水平拖动（比 PC 更容易触达），
                      // 逻辑与 PC 侧边栏一致 —— 拖动 → 松手吸附最近项 → 跳转。
                      onHorizontalDragStart: (_) {
                        setState(() => _maskDragLeft = sel * itemW + centerOff);
                      },
                      onHorizontalDragUpdate: (d) {
                        setState(() {
                          _maskDragLeft =
                              (_maskDragLeft ?? sel * itemW + centerOff) + d.delta.dx;
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
                        // 滑动遮罩：默认随选中项动画滑动；拖动时跟手
                        AnimatedPositioned(
                          duration: _maskDragLeft == null ? _anim : Duration.zero,
                          curve: _curve,
                          left: maskLeft,
                          top: 6,
                          bottom: 6,
                          width: elementW,
                          child: Container(
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer.withAlpha(230),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: scheme.primary.withAlpha(isDark ? 70 : 40),
                                  blurRadius: 10,
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

  Widget _item(ColorScheme scheme, ({int page, IconData icon, String label}) item, bool selected, VoidCallback onTap) {
    final clr = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(item.icon, size: 22, color: clr),
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

/// 底部导航栏的液态玻璃光影：边缘高光 + 左上内高光 + 对角反光 + 底部内阴影。
class _BottomGlassPainter extends CustomPainter {
  final BorderRadius borderRadius;
  _BottomGlassPainter({required this.borderRadius});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || size.shortestSide < 12) return;
    final rrect = RRect.fromRectAndCorners(
      Offset.zero & size,
      topLeft: borderRadius.topLeft,
      topRight: borderRadius.topRight,
      bottomLeft: borderRadius.bottomLeft,
      bottomRight: borderRadius.bottomRight,
    );
    canvas.save();
    canvas.clipRRect(rrect);

    // 1) 边缘折射高光环
    final rim = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 3.14159 * 2,
        colors: [
          Colors.white.withValues(alpha: 0.28),
          Colors.white.withValues(alpha: 0.06),
          Colors.black.withValues(alpha: 0.07),
          Colors.white.withValues(alpha: 0.13),
          Colors.white.withValues(alpha: 0.28),
        ],
        stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
      ).createShader(rrect.outerRect);
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..shader = rim.shader,
    );

    // 2) 左上内高光
    canvas.drawRRect(
      rrect.deflate(2.5),
      Paint()
        ..shader = RadialGradient(
          center: Alignment.topLeft,
          radius: 1.2,
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width * 0.7, size.height * 0.6)),
    );

    // 3) 对角反射光泽
    canvas.drawRRect(
      rrect.deflate(1.5),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.04),
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.025),
          ],
          stops: const [0.0, 0.35, 0.75, 1.0],
        ).createShader(rrect.outerRect),
    );

    // 4) 底部内阴影（厚度感）
    canvas.drawRRect(
      rrect.deflate(0.8),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.0),
            Colors.black.withValues(alpha: 0.06),
          ],
        ).createShader(rrect.outerRect),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_BottomGlassPainter old) =>
      old.borderRadius != borderRadius;
}
