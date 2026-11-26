import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/app_platform.dart';
import '../theme/app_semantic_colors.dart';
import 'liquid_glass_fallback.dart'
    show cachedGlassBlur, mobileGlassEffectsReducedOf, mobileGlassSigma;

enum ToastType { success, error, warning, info }

void showToast(
  BuildContext context,
  String message, {
  ToastType type = ToastType.info,
}) {
  final overlay = Overlay.of(context);
  final mobile = isMobilePlatform;
  late OverlayEntry entry;
  var dismissed = false;
  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final isDark = scheme.brightness == Brightness.dark;
      final highContrast = MediaQuery.highContrastOf(ctx);
      final radius = BorderRadius.circular(100);
      final effectsReduced = mobileGlassEffectsReducedOf(ctx);
      final sigma = mobile ? mobileGlassSigma(8) : 8.0;
      final top = mobile ? MediaQuery.paddingOf(ctx).top + 8 : 48.0;
      final sem = scheme.sem;
      final (icon, color) = switch (type) {
        ToastType.success => (Icons.check_circle_rounded, sem.success),
        ToastType.error => (Icons.cancel_rounded, sem.danger),
        ToastType.warning => (Icons.warning_rounded, sem.warning),
        ToastType.info => (Icons.info_rounded, sem.info),
      };

      Widget surface = Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surface.withAlpha(isDark ? 200 : 225),
              scheme.surface.withAlpha(isDark ? 165 : 190),
            ],
          ),
          border: Border.all(
            color: highContrast
                ? scheme.onSurface
                : Colors.white.withAlpha(isDark ? 40 : 140),
            width: highContrast ? 1.5 : 0.7,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          ],
        ),
      );
      surface = ClipRRect(
        borderRadius: radius,
        child: effectsReduced || sigma <= 0
            ? surface
            : BackdropFilter(
                filter: cachedGlassBlur(sigma),
                // 淡入淡出的离屏图层使用 src，避免背景被重复混合。
                blendMode: BlendMode.src,
                child: surface,
              ),
      );
      final toast = Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(30),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: surface,
        ),
      );
      return Positioned(
        top: top,
        left: 0,
        right: 0,
        child: Center(
          child: _ToastMotion(onDismiss: dismiss, child: toast),
        ),
      );
    },
  );

  overlay.insert(entry);
}

/// Own the ticker and timeout in the overlay subtree so preference changes and
/// navigator teardown stop motion immediately, including desktop toasts.
class _ToastMotion extends StatefulWidget {
  const _ToastMotion({required this.onDismiss, required this.child});

  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_ToastMotion> createState() => _ToastMotionState();
}

class _ToastMotionState extends State<_ToastMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _animation;
  late final Timer _timeout;
  bool _reduceMotion = false;
  bool _started = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    _timeout = Timer(const Duration(seconds: 2), _close);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _controller.value = _closing ? 0 : 1;
      if (_closing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onDismiss();
        });
      }
    } else if (!_started) {
      _controller.forward();
    }
    _started = true;
  }

  void _close() {
    if (!mounted) return;
    _closing = true;
    if (_reduceMotion) {
      widget.onDismiss();
    } else {
      _controller.reverse().whenComplete(() {
        if (mounted) widget.onDismiss();
      });
    }
  }

  @override
  void dispose() {
    _timeout.cancel();
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion) return widget.child;
    return FadeTransition(
      opacity: _animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.3),
          end: Offset.zero,
        ).animate(_animation),
        child: widget.child,
      ),
    );
  }
}
