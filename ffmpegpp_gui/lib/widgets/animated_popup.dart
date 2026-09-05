import 'package:flutter/material.dart';

import '../platform/app_platform.dart';

/// 弹出菜单的统一宽度约束。
///
/// 为什么需要：`showMenu` / `PopupMenuButton` 默认按「最长条目内容」撑开宽度。
/// 节点类型菜单的条目是「色块图标 + 中英标签 + 媒体标签」，在桌面端会把菜单
/// 拉到数百像素宽（用户反馈「PC 端菜单选项宽度极大」）。这里给出与主题
/// popupMenuTheme 一致的显式约束，供各调用点直接复用。
const BoxConstraints kPopupMenuConstraints = BoxConstraints(
  minWidth: 168,
  maxWidth: 280,
);

/// 移动端菜单更窄（屏幕宽度有限，过宽会遮住画布）。
const BoxConstraints kPopupMenuConstraintsMobile = BoxConstraints(
  minWidth: 132,
  maxWidth: 200,
);

/// 按平台选择菜单宽度约束。
BoxConstraints popupConstraints() =>
    isMobilePlatform ? kPopupMenuConstraintsMobile : kPopupMenuConstraints;

/// 带淡入 + 轻微缩放动画的弹出菜单。
///
/// `showMenu` 自带的过渡在本项目的玻璃主题下几乎看不出来（用户反馈「部分菜单
/// 选项展开无动画」）。这里用一条自定义 `PopupRoute` 接管：
/// - 150ms 淡入 + 0.96→1.0 缩放，锚点在菜单靠近点击位置的角上；
/// - 关闭 120ms 反向播放；
/// - 统一圆角、宽度约束与主题背景，和 DropdownMenu 的观感保持一致。
///
/// 用法与 `showMenu` 基本一致：给 `position`（相对屏幕的点击位置）和 `items`，
/// 返回被选中项的值；点击遮罩返回 null。
Future<T?> showAnimatedMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<AnimatedMenuEntry<T>> items,
  BoxConstraints? constraints,
}) {
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  final screen = overlay?.size ?? MediaQuery.sizeOf(context);
  return Navigator.of(context).push(
    _AnimatedMenuRoute<T>(
      position: position,
      screenSize: screen,
      items: items,
      constraints: constraints ?? popupConstraints(),
      capturedThemes:
          InheritedTheme.capture(from: context, to: Navigator.of(context).context),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

/// 菜单条目。[value] 为 null 时表示不可选（分隔线 / 分组标题 / 自定义行）。
class AnimatedMenuEntry<T> {
  /// 选中后返回的值；null = 该行不可选中。
  final T? value;

  /// 行内容。
  final Widget child;

  /// 是否为分隔线（此时忽略 child）。
  final bool isDivider;

  /// 行高（分隔线固定 9）。
  final double height;

  /// 自定义点击行为；提供时点击不返回 value，由回调自行处理
  /// （例如展开二级菜单）。
  final VoidCallback? onTap;

  const AnimatedMenuEntry({
    this.value,
    required this.child,
    this.height = 40,
    this.onTap,
  }) : isDivider = false;

  const AnimatedMenuEntry.divider()
      : value = null,
        child = const SizedBox.shrink(),
        isDivider = true,
        height = 9,
        onTap = null;

  bool get enabled => value != null || onTap != null;
}

class _AnimatedMenuRoute<T> extends PopupRoute<T> {
  _AnimatedMenuRoute({
    required this.position,
    required this.screenSize,
    required this.items,
    required this.constraints,
    required this.capturedThemes,
    required this.barrierLabel,
  });

  final Offset position;
  final Size screenSize;
  final List<AnimatedMenuEntry<T>> items;
  final BoxConstraints constraints;
  final CapturedThemes capturedThemes;

  @override
  final String barrierLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final menu = _AnimatedMenuBody<T>(
      items: items,
      constraints: constraints,
      onSelected: (v) => Navigator.of(context).pop(v),
    );
    return CustomSingleChildLayout(
      delegate: _MenuLayoutDelegate(position: position, screenSize: screenSize),
      child: capturedThemes.wrap(menu),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    // 锚点：菜单从靠近点击处的那个角「长出来」，比整体居中缩放更自然。
    final alignX = position.dx > screenSize.width / 2 ? 1.0 : -1.0;
    final alignY = position.dy > screenSize.height / 2 ? 1.0 : -1.0;
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
        alignment: Alignment(alignX, alignY),
        child: child,
      ),
    );
  }
}

/// 菜单定位：优先在点击点右下展开，空间不足时翻转到左/上，并留 8px 边距。
class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  _MenuLayoutDelegate({required this.position, required this.screenSize});

  final Offset position;
  final Size screenSize;

  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(Size(
      constraints.maxWidth - _margin * 2,
      constraints.maxHeight - _margin * 2,
    ));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = position.dx;
    var y = position.dy;
    if (x + childSize.width > size.width - _margin) {
      x = (position.dx - childSize.width).clamp(_margin, size.width - _margin);
    }
    if (y + childSize.height > size.height - _margin) {
      y = (position.dy - childSize.height).clamp(_margin, size.height - _margin);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate old) =>
      old.position != position || old.screenSize != screenSize;
}

class _AnimatedMenuBody<T> extends StatelessWidget {
  const _AnimatedMenuBody({
    required this.items,
    required this.constraints,
    required this.onSelected,
  });

  final List<AnimatedMenuEntry<T>> items;
  final BoxConstraints constraints;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final popupTheme = Theme.of(context).popupMenuTheme;
    final radius = BorderRadius.circular(18);
    return ConstrainedBox(
      constraints: constraints,
      child: Material(
        color: popupTheme.color ?? scheme.surface,
        elevation: popupTheme.elevation ?? 8,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: IntrinsicWidth(
          stepWidth: 1,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in items)
                  if (item.isDivider)
                    Divider(
                      height: item.height,
                      thickness: 1,
                      color: scheme.outlineVariant.withAlpha(90),
                    )
                  else
                    _MenuRow<T>(
                      item: item,
                      onSelected: onSelected,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({required this.item, required this.onSelected});

  final AnimatedMenuEntry<T> item;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Align(alignment: Alignment.centerLeft, child: item.child),
    );
    if (!item.enabled) {
      return SizedBox(height: item.height, child: row);
    }
    return InkWell(
      onTap: () {
        if (item.onTap != null) {
          item.onTap!();
        } else {
          onSelected(item.value);
        }
      },
      child: SizedBox(height: item.height, child: row),
    );
  }
}
