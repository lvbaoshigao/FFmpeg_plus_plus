import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 应用统一的页面转场（Android）。
///
/// ## 为什么不用 framework 的 PredictiveBackPageTransitionsBuilder
///
/// 它的非手势分支委托给 [FadeForwardsPageTransitionsBuilder]，而后者在**旧路由**
/// 上垫了一层 `ColoredBox(ColorScheme.surface)`（`page_transitions_theme.dart:541-552`），
/// 并且旧页在转场前 25% 就淡出（`:507-510`）、新页要到 75% 才完全淡入
/// （`:504`）。结果：前约 112ms 屏幕上只剩一块 surface 实色 —— 深色主题下
/// 就是用户看到的「进入二级菜单先黑一下」。改成 Zoom 更糟，它的 scrim 是
/// 硬编码纯黑。
///
/// ## 这里的做法
///
/// 平移式「共享轴」转场：
///
/// * 新页：从右侧 6% 位移滑入；
/// * 旧页：由 `secondaryAnimation` 驱动左移 4%（视差），**不淡出**；
/// * 全程**没有** ColoredBox / scrim，也**没有页面级 opacity**。
///
/// 页面级 `FadeTransition` 是刻意避免的：整页一层 OpacityLayer 会让页内的
/// `BackdropFilter` / 液态玻璃 shader 在过渡期间采不到背景（与下拉浮层
/// 「点一下闪一下」完全同一个机制）。位移不会破坏 backdrop 采样。
///
/// ## 两个容易踩的坑
///
/// 1. **不要**实现 `delegatedTransition`。一旦实现，旧路由拿到的
///    `secondaryAnimation` 会被冻结成 `ProxyAnimation`（`routes.dart:1655-1677`），
///    旧页动画永远不生效。
/// 2. 预测式返回的手势**必须**自己装观察者：framework 的那个 observer 是私有
///    类，只挂在它自己的 builder 里。这里用公开 API
///    （`route.handleStartBackGesture` 等）复刻同样的判定，于是换成自定义转场后
///    返回手势仍然可用。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder({this.predictiveBack = true});

  /// 是否安装预测式返回手势（设置 → 交互 → 预测式返回）。
  final bool predictiveBack;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 280);

  /// 新页入场曲线：起手快、收尾稳。
  static const Curve _enterCurve = Curves.easeOutCubic;

  /// 旧页视差曲线：与新页同向但更慢，形成层次。
  static const Curve _exitCurve = Curves.easeOutCubic;

  /// 新页相对屏宽的起手位移（正 = 从右侧进入）。
  static const double _enterFraction = 0.06;

  /// 旧页相对屏宽的左移量。
  static const double _exitFraction = 0.04;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Widget content = _AppPageExitTransition(
      animation: secondaryAnimation,
      curve: _exitCurve,
      fraction: _exitFraction,
      child: _AppPageEnterTransition(
        animation: animation,
        curve: _enterCurve,
        fraction: _enterFraction,
        child: child,
      ),
    );
    if (!predictiveBack) return content;
    return _PredictiveBackDetector(route: route, child: content);
  }
}

/// 新页位移（0 → 1 = 从右侧 `fraction × 屏宽` 滑到 0）。
class _AppPageEnterTransition extends StatelessWidget {
  const _AppPageEnterTransition({
    required this.animation,
    required this.curve,
    required this.fraction,
    required this.child,
  });

  final Animation<double> animation;
  final Curve curve;
  final double fraction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      // child 只建一次：整页子树不参与每帧重建，只有 Transform 在变。
      child: child,
      builder: (context, child) {
        final double t = curve.transform(animation.value.clamp(0.0, 1.0));
        final double dx = (1 - t) * fraction * MediaQuery.sizeOf(context).width;
        if (dx.abs() < 0.01) return child!;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}

/// 旧页视差（0 → 1 = 从 0 左移到 `-fraction × 屏宽`）。不淡出。
class _AppPageExitTransition extends StatelessWidget {
  const _AppPageExitTransition({
    required this.animation,
    required this.curve,
    required this.fraction,
    required this.child,
  });

  final Animation<double> animation;
  final Curve curve;
  final double fraction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final double t = curve.transform(animation.value.clamp(0.0, 1.0));
        final double dx = -t * fraction * MediaQuery.sizeOf(context).width;
        if (dx.abs() < 0.01) return child!;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}

/// 预测式返回手势观察者。
///
/// 只做一件事：把手势事件转交给路由（framework 收到 `route.animation` 的推进后，
/// [AppPageTransitionsBuilder] 的位移会自然跟随手指）。判定用
/// `route.isCurrent && route.popGestureEnabled` —— 后者在 `PopScope(canPop: false)`
/// 的页面上是 false（编辑器页就是），此时不能吞掉手势。
class _PredictiveBackDetector extends StatefulWidget {
  const _PredictiveBackDetector({required this.route, required this.child});

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_PredictiveBackDetector> createState() => _PredictiveBackDetectorState();
}

class _PredictiveBackDetectorState extends State<_PredictiveBackDetector>
    with WidgetsBindingObserver {
  bool get _canStart =>
      widget.route.isCurrent && widget.route.popGestureEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 实体返回键（isButtonEvent）不是手势，交给系统默认路径处理。
    if (backEvent.isButtonEvent || !_canStart) return false;
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
  }

  @override
  void handleCancelBackGesture() => widget.route.handleCancelBackGesture();

  @override
  void handleCommitBackGesture() => widget.route.handleCommitBackGesture();

  @override
  Widget build(BuildContext context) => widget.child;
}
