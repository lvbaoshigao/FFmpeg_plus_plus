import 'dart:async';
import 'package:flutter/material.dart';

enum ToastType { success, error, warning, info }

void showToast(BuildContext context, String message, {ToastType type = ToastType.info}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  final controller = AnimationController(vsync: overlay, duration: const Duration(milliseconds: 250));
  final animation = CurvedAnimation(parent: controller, curve: Curves.easeOut, reverseCurve: Curves.easeIn);

  entry = OverlayEntry(builder: (ctx) {
    final scheme = Theme.of(ctx).colorScheme;
    final (icon, color) = switch (type) {
      ToastType.success => (Icons.check_circle_rounded, Colors.green),
      ToastType.error => (Icons.cancel_rounded, Colors.red),
      ToastType.warning => (Icons.warning_rounded, Colors.orange),
      ToastType.info => (Icons.info_rounded, scheme.primary),
    };

    return Positioned(
      top: 48,
      left: 0,
      right: 0,
      child: Center(
        child: FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, -0.3), end: Offset.zero).animate(animation),
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: scheme.surface.withAlpha(240),
                  borderRadius: BorderRadius.circular(100),
                  border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 20, offset: const Offset(0, 4)),
                  ],
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 10),
                  Flexible(child: Text(message,
                    style: TextStyle(fontSize: 13, color: scheme.onSurface, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  )),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  });

  overlay.insert(entry);
  controller.forward();

  // 拆卸只能发生一次：定时器到点、以及 overlay 被提前销毁，两条路径都会走到这里。
  // 原先没有这层保护——若在 2 秒内切页/退出，overlay 先没了，
  // 定时器仍会在已 dispose 的 controller 上调 reverse()，抛异常。
  var dismissed = false;
  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    try { entry.remove(); } catch (_) {}
    try { controller.dispose(); } catch (_) {}
  }

  Timer(const Duration(seconds: 2), () {
    if (dismissed) return;
    if (!overlay.mounted) { dismiss(); return; }
    controller.reverse().whenComplete(dismiss);
  });
}
