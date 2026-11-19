import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';

import '../platform/app_platform.dart';

/// Lets desktop surfaces share a lightweight mode during window resizing.
final class DesktopResizeScope extends StatefulWidget {
  /// Observes the view containing [child].
  const DesktopResizeScope({super.key, required this.child});

  /// The window contents.
  final Widget child;

  /// Whether this view is currently receiving changes to its window size.
  static bool isResizingOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ResizeStatus>()?.active ??
      false;

  @override
  State<DesktopResizeScope> createState() => _DesktopResizeScopeState();
}

class _DesktopResizeScopeState extends State<DesktopResizeScope>
    with WidgetsBindingObserver {
  static const _settleDelay = Duration(milliseconds: 160);

  FlutterView? _view;
  (Size, double)? _geometry;
  Timer? _settle;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    if (isDesktopPlatform) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!isDesktopPlatform) {
      return;
    }
    final view = View.of(context);
    if (identical(view, _view)) {
      return;
    }
    _view = view;
    _geometry = (view.physicalSize, view.devicePixelRatio);
  }

  @override
  void didChangeMetrics() {
    final view = _view;
    if (view == null || view.physicalSize.isEmpty) {
      return;
    }
    final geometry = (view.physicalSize, view.devicePixelRatio);
    if (geometry == _geometry) {
      return;
    }
    _geometry = geometry;
    if (!_active) {
      setState(() => _active = true);
    }
    _settle?.cancel();
    _settle = Timer(_settleDelay, () {
      _settle = null;
      setState(() => _active = false);
    });
  }

  @override
  void dispose() {
    if (isDesktopPlatform) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => isDesktopPlatform
      ? _ResizeStatus(active: _active, child: widget.child)
      : widget.child;
}

class _ResizeStatus extends InheritedWidget {
  const _ResizeStatus({required this.active, required super.child});

  final bool active;

  @override
  bool updateShouldNotify(_ResizeStatus oldWidget) =>
      active != oldWidget.active;
}
