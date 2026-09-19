import 'package:flutter/widgets.dart';

import '../platform/app_platform.dart';

/// 当前生效的移动端主导航位置（bottom / left / right），由 AppShell 下发。
///
/// **为什么用 InheritedWidget，而不是全局变量或让页面自己去读配置：**
/// 主 Tab 页的滚动内边距要按「菜单栏是否还在底部」决定要不要让出
/// [kMobileNavClearance]（底部悬浮 → 必须让；竖排导轨 → 内容不会被遮挡）。
/// 但主 Tab 的页面实例被 AppShell 的 `_pageCache` 缓存后作为**同一个 Widget
/// 实例**复用，上层重建时 Flutter 会直接短路上报（`identical(new, old)`），
/// 页面自己的 build 根本不会被调用；而设置页改「菜单栏位置」时，页面也未必
/// 恰好因为别的配置字段重建。只有 InheritedWidget 的依赖关系能保证
/// 「位置一变 → 依赖它的页面下一帧就重建」，且不引入 providers 依赖。
///
/// 桌面端没有该 scope，[of] 返回 [MobileNavPlacement.bottom]（与桌面行为无关）。
class MobileNavPlacementScope extends InheritedWidget {
  final MobileNavPlacement placement;

  const MobileNavPlacementScope({
    super.key,
    required this.placement,
    required super.child,
  });

  /// 读取当前生效的导航位置（无 scope 时按「底部」处理）。
  ///
  /// 调用即建立依赖：位置变化时调用方会重建。
  static MobileNavPlacement of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MobileNavPlacementScope>()
          ?.placement ??
      MobileNavPlacement.bottom;

  @override
  bool updateShouldNotify(MobileNavPlacementScope oldWidget) =>
      oldWidget.placement != placement;
}
