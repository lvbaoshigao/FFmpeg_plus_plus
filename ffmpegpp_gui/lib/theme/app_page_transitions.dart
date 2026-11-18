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
    Widget content(double enterFraction) => _AppPageExitTransition(
      animation: secondaryAnimation,
      fraction: _exitFraction,
      child: _AppPageEnterTransition(
        animation: animation,
        fraction: enterFraction,
        child: child,
      ),
    );
    if (!predictiveBack) return content(_enterFraction);
    return _PredictiveBackDetector(
      route: route,
      builder: (fraction) => content(fraction ?? _enterFraction),
    );
  }
}

/// 二级页面路由：保留 Material 路由兼容性，让旧页 secondaryAnimation 联动。
class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({required super.builder}) : super(allowSnapshotting: false);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 280);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 240);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final configured = Theme.of(context).pageTransitionsTheme.builders[TargetPlatform.android];
    final transitions = configured is AppPageTransitionsBuilder
        ? configured
        : const AppPageTransitionsBuilder();
    return transitions.buildTransitions(this, context, animation, secondaryAnimation, child);
  }
}

/// 新页位移因子（1 = 完全在屏幕外，0 = 归位）。
///
/// **线性**，且只依赖 `animation.value`，不区分动画方向。
///
/// 前一版按 `animation.status` 取向（push 用 `1 - easeOut(v)`、pop 用
/// `easeOut(1 - v)`），本意是让两个方向都「快起慢收」，但在**预测式返回**上翻车：
/// 手势拖动期间路由 animation 的 status 仍是 `completed`（只有松手 commit 后才
/// 切成 reverse），于是 commit 那一帧因子从 `1 - v` 跳到 `easeOut(1 - v)` ——
/// 画面先抖一下/突然消失，再弹回上一级（用户反馈「到 15% 动画突然消失，随后
/// 返回上一级」）。线性 + 只读 value 之后，手指拖多少页面就走多少，
/// 手势、程序化 push/pop 全部同一映射。
double appEnterFactor(Animation<double> animation) =>
    1.0 - animation.value.clamp(0.0, 1.0);

/// 旧页视差因子（0 = 未位移，1 = 位移到位）。同为线性、不区分方向。
double _appExitFactor(Animation<double> animation) =>
    animation.value.clamp(0.0, 1.0);

/// 新页从右侧滑入（`fraction × 屏宽` → 0）。纯位移，不做任何 opacity。
///
/// 暴露出来是给 `smoothRoute` 复用：它是 `PageRouteBuilder` 自带
/// transitionsBuilder，完全绕过 `pageTransitionsTheme`，只改主题的话
/// 「项目页→编辑器」「容器详情」这些页面仍会走旧转场。
class AppSlideInTransition extends StatelessWidget {
  const AppSlideInTransition({
    super.key,
    required this.animation,
    required this.child,
    this.fraction = 0.06,
  });

  final Animation<double> animation;
  final Widget child;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final double f = appEnterFactor(animation);
        final double dx = f * fraction * MediaQuery.sizeOf(context).width;
        if (dx.abs() < 0.01) return child!;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}

/// 新页位移（0 → 1 = 从右侧 `fraction × 屏宽` 滑到 0）。
class _AppPageEnterTransition extends StatelessWidget {
  const _AppPageEnterTransition({
    required this.animation,
    required this.fraction,
    required this.child,
  });

  final Animation<double> animation;
  final double fraction;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      AppSlideInTransition(animation: animation, fraction: fraction, child: child);
}

/// 旧页视差（0 → 1 = 从 0 左移到 `-fraction × 屏宽`）。不淡出。
class _AppPageExitTransition extends StatelessWidget {
  const _AppPageExitTransition({
    required this.animation,
    required this.fraction,
    required this.child,
  });

  final Animation<double> animation;
  final double fraction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final double f = _appExitFactor(animation);
        final double dx = -f * fraction * MediaQuery.sizeOf(context).width;
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
  const _PredictiveBackDetector({required this.route, required this.builder});

  final PageRoute<dynamic> route;
  final Widget Function(double? fraction) builder;

  @override
  State<_PredictiveBackDetector> createState() => _PredictiveBackDetectorState();
}

class _PredictiveBackDetectorState extends State<_PredictiveBackDetector>
    with WidgetsBindingObserver {
  bool _active = false;
  bool _receiving = false;
  double _direction = 1;
  NavigatorState? _navigator;
  Animation<double>? _commitAnimation;

  bool get _canStart =>
      !_active && widget.route.isCurrent && widget.route.popGestureEnabled;

  void _gestureChanged() {
    if (_navigator?.userGestureInProgress == true || !mounted) return;
    void apply() {
      if (!mounted) return;
      setState(() {
        _active = false;
        _receiving = false;
      });
    }

    // dispose 里兜底释放手势前已先移除本监听器，故通知到达时若我们仍在
    // 树上（mounted），直接复位是安全的。
    apply();
  }

  void _stopCommittedGesture(AnimationStatus status) {
    if (status != AnimationStatus.dismissed &&
        status != AnimationStatus.completed) {
      return;
    }
    _commitAnimation?.removeStatusListener(_stopCommittedGesture);
    _commitAnimation = null;
    _navigator?.didStopUserGesture();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _commitAnimation?.removeStatusListener(_stopCommittedGesture);
    // A route removed mid-gesture (drag, commit, or the cancel animation) must
    // not leave the Navigator stuck in user-gesture mode: the framework only
    // releases ownership from an animation-status listener that never fires
    // when the route is disposed while still animating. Drop our own
    // notifier listener first — didStopUserGesture notifies synchronously
    // and would otherwise call setState while the tree is locked.
    final navigator = _navigator;
    if (navigator != null) {
      navigator.userGestureInProgressNotifier.removeListener(_gestureChanged);
      // A live route owns the framework cancellation listener until its
      // forward animation finishes, even if this detector is removed by a
      // theme change. Only take over that cleanup if the route was removed.
      final frameworkCancelling =
          !_receiving && _commitAnimation == null && widget.route.isActive;
      if (_active && !frameworkCancelling && navigator.userGestureInProgress) {
        // Navigator also notifies widgets outside this route. Defer until the
        // tree is unlocked, rather than triggering their rebuilds in dispose.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (navigator.mounted && navigator.userGestureInProgress) {
            navigator.didStopUserGesture();
          }
        });
      }
      _navigator = null;
    }
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 实体返回键（isButtonEvent）不是手势，交给系统默认路径处理。
    if (backEvent.isButtonEvent || !_canStart) return false;
    if (_navigator != widget.route.navigator) {
      _navigator?.userGestureInProgressNotifier.removeListener(_gestureChanged);
      _navigator = widget.route.navigator;
      _navigator?.userGestureInProgressNotifier.addListener(_gestureChanged);
    }
    setState(() {
      _active = _receiving = true;
      _direction = backEvent.swipeEdge == SwipeEdge.left ? 1 : -1;
    });
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_receiving) return;
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
  }

  @override
  void handleCancelBackGesture() {
    if (!_receiving) return;
    _receiving = false;
    widget.route.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    if (!_receiving) return;
    _receiving = false;
    // Flutter 3.44's handleCommitBackGesture restarts reverse from upperBound.
    // Pop already reverses from the drag value, so keep that continuous animation.
    _commitAnimation = widget.route.animation;
    _commitAnimation?.addStatusListener(_stopCommittedGesture);
    if (widget.route.isCurrent) _navigator?.pop();
    if (_commitAnimation?.isAnimating != true) {
      _stopCommittedGesture(AnimationStatus.dismissed);
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(_active ? _direction : null);
}
