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
  final reduceMotion = mobile && MediaQuery.disableAnimationsOf(context);
  final duration = reduceMotion
      ? Duration.zero
      : const Duration(milliseconds: 250);
  late OverlayEntry entry;
  final controller = AnimationController(vsync: overlay, duration: duration);
  final animation = CurvedAnimation(
    parent: controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );

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
      Widget toast = Material(
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
      if (!reduceMotion) {
        toast = FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.3),
              end: Offset.zero,
            ).animate(animation),
            child: toast,
          ),
        );
      }
      return Positioned(
        top: top,
        left: 0,
        right: 0,
        child: Center(child: toast),
      );
    },
  );

  overlay.insert(entry);
  controller.forward();

  // Dispose once whether timeout or an overlay teardown wins the race.
  var dismissed = false;
  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    try {
      entry.remove();
    } catch (_) {}
    try {
      controller.dispose();
    } catch (_) {}
  }

  Timer(const Duration(seconds: 2), () {
    if (dismissed) return;
    if (!overlay.mounted) {
      dismiss();
      return;
    }
    if (reduceMotion) {
      dismiss();
    } else {
      controller.reverse().whenComplete(dismiss);
    }
  });
}
