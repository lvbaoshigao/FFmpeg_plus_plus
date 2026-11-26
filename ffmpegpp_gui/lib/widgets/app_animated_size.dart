import 'package:flutter/widgets.dart';

/// Animates size normally and lays out directly when motion is disabled.
/// Zero-duration AnimatedSize can invalidate its own layout on a size change.
class AppAnimatedSize extends StatefulWidget {
  const AppAnimatedSize({
    super.key,
    required this.duration,
    required this.child,
    this.curve = Curves.linear,
    this.alignment = Alignment.center,
  });

  final Duration duration;
  final Widget child;
  final Curve curve;
  final AlignmentGeometry alignment;

  @override
  State<AppAnimatedSize> createState() => _AppAnimatedSizeState();
}

class _AppAnimatedSizeState extends State<AppAnimatedSize> {
  // Moving this subtree out of AnimatedSize must preserve live form state.
  final _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    if (MediaQuery.disableAnimationsOf(context) ||
        widget.duration == Duration.zero) {
      return child;
    }
    return AnimatedSize(
      duration: widget.duration,
      curve: widget.curve,
      alignment: widget.alignment,
      child: child,
    );
  }
}
