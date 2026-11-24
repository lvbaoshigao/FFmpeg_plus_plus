import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The row of items plus the moving selection capsule ("droplet").
///
/// This widget only owns the motion; what the capsule looks like comes from
/// [indicatorBuilder] / [indicatorBelowBuilder] and what the items look like
/// from [itemBuilder]. Behaviour:
///
///  * tapping another item makes the capsule flow there — it stretches and
///    thins on the way and settles with a small overshoot (easeOutBack);
///  * dragging horizontally moves the capsule with the finger; on release it
///    snaps to the nearest item;
///  * while a finger is down (press-and-hold, drag) or during a tap the
///    capsule grows and turns into glass. The amount (0..1) is passed to the
///    builders as `glass`.
class DropletTrack extends StatefulWidget {
  /// Creates the track.
  const DropletTrack({
    super.key,
    required this.slotCount,
    required this.selectedSlot,
    required this.onSlotSelected,
    required this.itemBuilder,
    required this.capsuleHeight,
    required this.indicatorBuilder,
    this.indicatorBelowBuilder,
    this.onSlotTap,
    this.maxOverhang = 0,
    this.minGlassHeight = 0,
    this.onActiveChanged,
  });

  /// Number of items.
  final int slotCount;

  /// Currently selected item. When it changes from outside the capsule
  /// animates there.
  final int selectedSlot;

  /// Called when a selection is made (tap or end of a drag). Also called for
  /// a tap on the already selected item so apps can e.g. pop to root.
  final ValueChanged<int> onSlotSelected;

  /// Builds an item. Must only change its color with `active`: both layers
  /// are drawn on top of each other.
  final Widget Function(BuildContext context, int slot, bool active)
      itemBuilder;

  /// Height of the resting capsule.
  final double capsuleHeight;

  /// The glass lens drawn ABOVE the items. `glass` is 0 at rest and 1 while
  /// pressed / dragging / mid-switch.
  final Widget Function(BuildContext context, double glass) indicatorBuilder;

  /// The resting capsule drawn BELOW the items (a fill painted above an icon
  /// would wash it out).
  final Widget Function(BuildContext context, double glass)?
      indicatorBelowBuilder;

  /// Lets the owner take over a tap / drag release on an item (return
  /// `true`): the selection does not change and the capsule returns to the
  /// current item — useful for "action" items that open a sheet.
  final bool Function(int slot)? onSlotTap;

  /// How far the capsule may stick out of the row on the first / last item,
  /// so it sits concentric with the rounded ends of the bar.
  final double maxOverhang;

  /// The glass droplet is never shorter than this while it moves or is held
  /// (usually the bar's height), even when fast movement flattens it.
  final double minGlassHeight;

  /// `true` while the user interacts (drag, hold, briefly after a tap) — the
  /// bar uses it to grow slightly.
  final ValueChanged<bool>? onActiveChanged;

  @override
  State<DropletTrack> createState() => _DropletTrackState();
}

class _DropletTrackState extends State<DropletTrack>
    with TickerProviderStateMixin {
  /// Slide between items after a tap.
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..addListener(() => setState(() {}));

  /// 0→1 while a finger is down. Very short so fast drags feel immediate.
  late final AnimationController _dragAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 80),
  )..addListener(() => setState(() {}));

  /// 0→1 while the droplet is MOVING; when the finger stops the speed stretch
  /// eases out with it. Fast forward, slow reverse.
  late final AnimationController _moveAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 50),
    reverseDuration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() {}));

  /// Pulse for a tap on the already selected item.
  late final AnimationController _pulseAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 250),
  )
    ..addListener(() => setState(() {}))
    ..addStatusListener((st) {
      if (st == AnimationStatus.completed) _pulseAnim.reverse();
    });

  /// Fires shortly after the last drag event: the finger has stopped.
  Timer? _stillTimer;

  /// Press-and-hold without moving also turns the capsule into glass; the
  /// short delay separates a quick tap (which gets a pulse anyway) from a hold.
  Timer? _holdTimer;

  /// Ends the short "active" phase after a tap.
  Timer? _bumpTimer;

  double _from = 0;
  double _to = 0;

  /// Droplet position during a drag; `null` when not dragging.
  double? _dragPos;

  /// Item the droplet moved to on pointer DOWN, before the tap is confirmed.
  /// The selection only changes when the finger is lifted over it; otherwise
  /// the droplet returns to the selected item.
  int? _preview;

  /// Set when the tap of the current pointer was delivered.
  bool _tapCommitted = false;

  /// The drag started from a previewed item (see [_preview]).
  bool _dragFromPreview = false;

  /// The droplet really moved during the current drag.
  bool _dragMoved = false;

  /// Stretch caused by drag speed (0..1). Rises instantly, decays smoothly.
  double _dragStretch = 0;

  /// Timestamp of the previous drag event, so speed does not depend on the
  /// frame rate.
  Duration? _lastMoveTs;

  @override
  void initState() {
    super.initState();
    _from = _to = widget.selectedSlot.toDouble();
  }

  @override
  void didUpdateWidget(covariant DropletTrack old) {
    super.didUpdateWidget(old);
    if (widget.selectedSlot != old.selectedSlot &&
        widget.selectedSlot.toDouble() != _to &&
        _dragPos == null) {
      _goTo(widget.selectedSlot);
    }
  }

  @override
  void dispose() {
    _stillTimer?.cancel();
    _holdTimer?.cancel();
    _bumpTimer?.cancel();
    _anim.dispose();
    _dragAnim.dispose();
    _moveAnim.dispose();
    _pulseAnim.dispose();
    super.dispose();
  }

  void _noteMovement() {
    _moveAnim.forward();
    _stillTimer?.cancel();
    _stillTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _moveAnim.reverse();
    });
  }

  /// Current droplet position in slot units (fractional).
  double get _pos {
    final drag = _dragPos;
    if (drag != null) return drag;
    if (_anim.isAnimating) {
      // easeOutBack overshoots slightly at the end — the droplet "wobble".
      return _from + (_to - _from) * Curves.easeOutBack.transform(_anim.value);
    }
    return _to;
  }

  void _goTo(int slot) {
    _from = _pos;
    _to = slot.toDouble();
    _dragPos = null;
    // `_dragStretch` is intentionally NOT reset here: it is multiplied by
    // `_moveAnim.value` which fades out smoothly; resetting caused a one-frame
    // jump on release.
    // Longer jumps take a little longer: 380 ms to the neighbour, +160 ms per
    // extra item — a fixed time made far jumps look rushed.
    final distance = (_to - _from).abs();
    _anim.duration = Duration(
      milliseconds: (380 + 160 * (distance - 1)).clamp(380, 860).round(),
    );
    _anim.forward(from: 0);
  }

  /// Marks the bar as active for a short moment (tap, switch, end of hold).
  void _bump([Duration d = const Duration(milliseconds: 300)]) {
    widget.onActiveChanged?.call(true);
    _bumpTimer?.cancel();
    _bumpTimer = Timer(d, () {
      if (mounted && _dragPos == null) widget.onActiveChanged?.call(false);
    });
  }

  void _handleTap(int slot) {
    _bump();
    _tapCommitted = true;
    final previewed = _preview == slot;
    _preview = null;
    if (widget.onSlotTap?.call(slot) ?? false) {
      // An action item: the droplet goes back to the selected item.
      if (_to.round() != widget.selectedSlot) _goTo(widget.selectedSlot);
      return;
    }
    if (slot != _to.round()) {
      _goTo(slot);
    } else if (!previewed) {
      _pulseAnim.forward(from: 0);
    }
    widget.onSlotSelected(slot);
  }

  /// Pointer DOWN on another item: the droplet slides there right away, but
  /// nothing is selected until the finger is lifted (like iOS 26).
  void _startPreview(int slot) {
    _tapCommitted = false;
    _preview = null;
    if (slot == _to.round()) return;
    _preview = slot;
    _bump();
    _goTo(slot);
  }

  /// After the pointer is lifted: if no tap was delivered (the finger moved
  /// away, the gesture was cancelled, ...) the previewed droplet returns.
  void _settlePreview() {
    if (!mounted || _tapCommitted || _dragPos != null) return;
    if (_preview == null) return;
    _preview = null;
    if (_to.round() != widget.selectedSlot) _goTo(widget.selectedSlot);
  }

  void _endDrag() {
    final drag = _dragPos;
    // The drag never started (the gesture arena gave the pointer to the tap).
    if (drag == null) return;
    _stillTimer?.cancel();
    _moveAnim.reverse();
    _dragAnim.reverse();
    widget.onActiveChanged?.call(false);
    // A "drag" that never moved sideways (the finger slid off the bar
    // vertically and the tap was cancelled) must not select the previewed
    // item — the droplet goes back.
    if (_dragFromPreview && !_dragMoved) {
      setState(() => _goTo(widget.selectedSlot));
      return;
    }
    final nearest = drag.round().clamp(0, widget.slotCount - 1);
    if (widget.onSlotTap?.call(nearest) ?? false) {
      setState(() => _goTo(widget.selectedSlot));
      return;
    }
    final changed = nearest != widget.selectedSlot;
    setState(() => _goTo(nearest));
    if (changed) widget.onSlotSelected(nearest);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final slotW = box.maxWidth / widget.slotCount;

        // Stretch: a sine that peaks mid-way during a tap animation (longer
        // jumps stretch more, at most 65% of a fast drag so a long jump does
        // not turn the capsule into a long bar), or the finger speed while
        // dragging.
        final animStretch = _anim.isAnimating
            ? 0.65 *
                math.sin(math.pi * _anim.value.clamp(0.0, 1.0)) *
                ((_to - _from).abs() / 2).clamp(0.0, 1.0)
            : 0.0;
        final s = math.max(animStretch, _dragStretch * _moveAnim.value);

        final dragT = Curves.easeOut.transform(_dragAnim.value);
        final pulseT = Curves.easeOut.transform(_pulseAnim.value);
        final press = math.max(dragT, pulseT);

        // The capsule also turns into glass while sliding after a tap: full
        // glass half-way, plain capsule again when it arrives.
        final slideGlass = _anim.isAnimating
            ? math.sin(math.pi * _anim.value.clamp(0.0, 1.0)).clamp(0.0, 1.0)
            : 0.0;
        final glass = math.max(press, slideGlass);

        // The capsule is exactly one slot wide plus the overhang on each side,
        // so on the first/last item it is concentric with the bar's ends.
        final w = slotW + 2 * widget.maxOverhang;
        final h = widget.capsuleHeight;

        // Droplet deformation: stretches horizontally and flattens with the
        // finger's speed. While the finger is down it keeps one full size —
        // it does NOT shrink when the finger stops; only the stretch eases
        // out. A tap pulse grows it a little less.
        final grow = math.max(dragT, 0.55 * pulseT);
        // 0.36 (was 0.45): a fast drag stretched the droplet too far.
        final sx = (1 + 0.36 * s) * (1 + 0.232 * grow);
        // 0.28: with the 54 high capsule this keeps the held droplet as tall
        // as before (about 69); 0.355 made it stick out too far. As glass it
        // never gets shorter than [minGlassHeight].
        final minSy =
            1 + (math.max(widget.minGlassHeight / h, 1.0) - 1) * glass;
        final sy = math.max((1 - 0.14 * s) * (1 + 0.28 * grow), minSy);

        // Clamp by the STRETCHED width so a stretched droplet pushes against
        // the bar's end instead of sliding out of it. As glass it may stick
        // out further — on iOS 26 the bar's edge shows through the droplet.
        final halfW = w * sx / 2;
        final overhang = widget.maxOverhang + 9 * glass;
        final centerX = (slotW * (_pos + 0.5)).clamp(
          halfW - overhang,
          box.maxWidth + overhang - halfW,
        );
        final left = centerX - w / 2;
        final top = (box.maxHeight - h) / 2;
        final dropRect = Rect.fromCenter(
          center: Offset(centerX, top + h / 2),
          width: w * sx,
          height: h * sy,
        );

        // Items are drawn twice: all unselected below, all selected on top but
        // clipped to the droplet — so only the part under the droplet takes
        // the selected color and the color flows as the droplet moves.
        Widget itemAt(int i, {required bool active}) => Transform.scale(
              // At rest the selected item is slightly larger (iOS 26); under the
              // glass it shrinks — the native lens is a minifying one.
              scale: 1 +
                  (0.07 - 0.14 * glass) *
                      (1 - (_pos - i).abs()).clamp(0.0, 1.0),
              child: widget.itemBuilder(context, i, active),
            );

        Widget capsule(Widget child) => Positioned(
              left: left,
              top: top,
              child: IgnorePointer(
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.diagonal3Values(sx, sy, 1),
                  child: SizedBox(width: w, height: h, child: child),
                ),
              ),
            );

        // The Listener sits outside the gesture arena so press-and-hold can be
        // tracked without competing with the tap / drag recognizers.
        return Listener(
          onPointerDown: (e) {
            _startPreview(
              (e.localPosition.dx / slotW).floor().clamp(
                    0,
                    widget.slotCount - 1,
                  ),
            );
            _holdTimer?.cancel();
            _holdTimer = Timer(const Duration(milliseconds: 150), () {
              if (!mounted) return;
              _dragAnim.forward();
              _bumpTimer?.cancel();
              widget.onActiveChanged?.call(true);
            });
          },
          onPointerUp: (_) {
            _holdTimer?.cancel();
            if (_dragPos == null) {
              _dragAnim.reverse();
              _bump(const Duration(milliseconds: 150));
            }
            // The tap (if any) is delivered later in this same event; check
            // afterwards whether the preview has to be undone.
            scheduleMicrotask(_settlePreview);
          },
          onPointerCancel: (_) {
            _holdTimer?.cancel();
            if (_dragPos == null) {
              _dragAnim.reverse();
              _bump(const Duration(milliseconds: 150));
            }
            scheduleMicrotask(_settlePreview);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (d) {
              // The drag takes over; its release decides the selection.
              _dragFromPreview = _preview != null;
              _dragMoved = false;
              _preview = null;
              _anim.stop();
              _dragAnim.forward();
              _bumpTimer?.cancel();
              widget.onActiveChanged?.call(true);
              _lastMoveTs = d.sourceTimeStamp;
              _dragStretch = 0;
              setState(() => _dragPos = _pos);
            },
            onHorizontalDragUpdate: (d) {
              final delta = d.primaryDelta ?? 0;
              final prev = _dragPos ?? _pos;
              final next = (prev + delta / slotW).clamp(
                0.0,
                (widget.slotCount - 1).toDouble(),
              );
              // Only REAL droplet movement counts — pushing against the last
              // item must not inflate the stretch.
              final moved = (next - prev).abs();
              if (moved > 0) {
                _dragMoved = true;
                _noteMovement();
              }
              // Speed from real time (slots/second), independent of frame
              // rate; dt is clamped so a pause does not fake a slow event.
              double dtSec = 1 / 60;
              final ts = d.sourceTimeStamp;
              final last = _lastMoveTs;
              if (ts != null && last != null) {
                dtSec = ((ts - last).inMicroseconds / 1e6).clamp(
                  1 / 250,
                  1 / 30,
                );
              }
              if (ts != null) _lastMoveTs = ts;
              final target = (moved / dtSec / 6).clamp(0.0, 1.0);
              // Time-based asymmetric smoothing: raw per-event speed is noisy
              // and made the droplet shake. Fast rise (~30 ms), slow decay
              // (~150 ms); identical on 60 and 120 Hz.
              final tau = target > _dragStretch ? 0.03 : 0.15;
              final k = 1 - math.exp(-dtSec / tau);
              setState(() {
                _dragPos = next;
                _dragStretch += (target - _dragStretch) * k;
              });
            },
            onHorizontalDragEnd: (_) => _endDrag(),
            onHorizontalDragCancel: _endDrag,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (widget.indicatorBelowBuilder != null)
                  capsule(widget.indicatorBelowBuilder!(context, glass)),
                Row(
                  children: [
                    for (var i = 0; i < widget.slotCount; i++)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _handleTap(i),
                          child: itemAt(i, active: false),
                        ),
                      ),
                  ],
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ClipPath(
                      // 2 px inside the glass so the clip never leaks color
                      // outside the lens outline.
                      clipper: _StadiumClipper(dropRect.deflate(2)),
                      child: Row(
                        children: [
                          for (var i = 0; i < widget.slotCount; i++)
                            Expanded(child: itemAt(i, active: true)),
                        ],
                      ),
                    ),
                  ),
                ),
                // The lens is drawn ABOVE the items so it refracts them.
                capsule(widget.indicatorBuilder(context, glass)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Clips to a stadium (fully rounded ends) — the droplet's shape.
class _StadiumClipper extends CustomClipper<Path> {
  const _StadiumClipper(this.rect);

  final Rect rect;

  @override
  Path getClip(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide / 2)),
    );

  @override
  bool shouldReclip(_StadiumClipper old) => old.rect != rect;
}
