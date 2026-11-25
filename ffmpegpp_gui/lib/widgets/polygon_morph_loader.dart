import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A native rendering of the polygon loaders in docs/polygon-morph-loader*.svg.
///
/// Each side grows over 900 ms, from a triangle to an octagon and back, without
/// pausing at the ends. The default constructor is solid for indeterminate work;
/// [PolygonMorphLoader.hollow] includes the stationary app icon for startup.
/// Nothing paints the background. [color] defaults to the current primary color.
///
/// By default the system's reduced motion preference produces a static triangle.
/// [reduceMotion] can supply an app preference. Disabled [TickerMode] pauses the
/// current frame, and resumes from that frame when the widget becomes visible.
/// Supply a localized [semanticsLabel] when no surrounding text describes loading.
class PolygonMorphLoader extends StatefulWidget {
  const PolygonMorphLoader({
    super.key,
    this.size = 24,
    this.color,
    this.reduceMotion,
    this.semanticsLabel,
  }) : hollow = false,
       assert(size > 0 && size < double.infinity);

  const PolygonMorphLoader.hollow({
    super.key,
    this.size = 160,
    this.color,
    this.reduceMotion,
    this.semanticsLabel,
  }) : hollow = true,
       assert(size > 0 && size < double.infinity);

  static const cycleDuration = Duration(milliseconds: 9000);

  final double size;
  final Color? color;
  final bool? reduceMotion;
  final String? semanticsLabel;
  final bool hollow;

  @override
  State<PolygonMorphLoader> createState() => _PolygonMorphLoaderState();
}

class _PolygonMorphLoaderState extends State<PolygonMorphLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: PolygonMorphLoader.cycleDuration,
    animationBehavior: AnimationBehavior.preserve,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(PolygonMorphLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reduceMotion != widget.reduceMotion) _syncAnimation();
  }

  void _syncAnimation() {
    final reduce =
        widget.reduceMotion ?? MediaQuery.disableAnimationsOf(context);
    if (reduce) {
      _controller.stop();
      _controller.value = 0;
    } else if (!TickerMode.valuesOf(context).enabled) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      label: widget.semanticsLabel,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: widget.size,
            child: CustomPaint(
              painter: _PolygonMorphPainter(
                animation: _controller,
                color: color,
                hollow: widget.hollow,
              ),
              child: widget.hollow
                  ? Center(
                      // This square stays within the hole even in the triangle
                      // phase, including while the frame rotates around it.
                      child: FractionallySizedBox(
                        widthFactor: 0.28,
                        heightFactor: 0.28,
                        child: RepaintBoundary(
                          child: Image.asset(
                            'rele/icon.png',
                            fit: BoxFit.contain,
                            cacheWidth: 128,
                            excludeFromSemantics: true,
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

const _tau = math.pi * 2;
const _viewBox = 800.0;
const _corner = 52.0;
const _holeScale = 0.72;
const _innerPerimeter = 1980 - _tau * _corner;
const _segmentMs = 900.0;
const _counts = [3, 4, 5, 6, 7, 8, 7, 6, 5, 4, 3];

class _MorphStep {
  const _MorphStep(this.base, this.d0, this.d1, this.theta0, this.theta1);

  final int base;
  final double d0;
  final double d1;
  final double theta0;
  final double theta1;
}

({List<_MorphStep> steps, double endAngle}) _buildSteps(double correction) {
  final steps = <_MorphStep>[];
  var theta = 0.0;
  for (var i = 1; i < _counts.length; i++) {
    final from = _counts[i - 1];
    final to = _counts[i];
    // The SVG divides its small loop correction over the last two segments.
    final turn = _tau / from + (i >= _counts.length - 2 ? correction / 2 : 0);
    if (to > from) {
      steps.add(_MorphStep(from, 0, math.pi / to, theta, theta + turn));
      theta += turn + math.pi / to;
    } else {
      final start = theta - math.pi / from;
      steps.add(_MorphStep(to, math.pi / from, 0, start, start + turn));
      theta = start + turn;
    }
  }
  return (steps: steps, endAngle: theta);
}

final _steps = () {
  final uncorrected = _buildSteps(0);
  final symmetry = _tau / _counts.first;
  var correction = -uncorrected.endAngle % symmetry;
  if (correction > symmetry / 2) correction -= symmetry;
  return _buildSteps(correction).steps;
}();

double _bezier(double a, double b, double t) {
  final c = 3 * a;
  final d = 3 * (b - a) - c;
  return (((1 - c - d) * t + d) * t + c) * t;
}

double _bezierSlope(double a, double b, double t) {
  final c = 3 * a;
  final d = 3 * (b - a) - c;
  return (3 * (1 - c - d) * t + 2 * d) * t + c;
}

double _ease(double u) {
  if (u <= 0 || u >= 1) return u.clamp(0, 1);
  var t = u;
  for (var i = 0; i < 8; i++) {
    final difference = _bezier(0.12, 0.88, t) - u;
    if (difference.abs() < 1e-7) {
      return u + (_bezier(0.36, 0.64, t) - u) * 0.45;
    }
    final slope = _bezierSlope(0.12, 0.88, t);
    if (slope.abs() <= 1e-6) break;
    t -= difference / slope;
    if (t < 0 || t > 1) break;
  }
  var lo = 0.0;
  var hi = 1.0;
  for (var i = 0; i < 48; i++) {
    final mid = (lo + hi) / 2;
    if (_bezier(0.12, 0.88, mid) < u) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return u + (_bezier(0.36, 0.64, (lo + hi) / 2) - u) * 0.45;
}

List<Offset> _verticesAt(double milliseconds) {
  final time = milliseconds % PolygonMorphLoader.cycleDuration.inMilliseconds;
  final index = (time / _segmentMs).floor();
  final step = _steps[index];
  final e = _ease((time - index * _segmentMs) / _segmentMs);
  final delta = step.d0 + (step.d1 - step.d0) * e;
  final angle = step.theta0 + (step.theta1 - step.theta0) * e;
  final gap = (_tau - 2 * delta) / step.base;
  final radius =
      _innerPerimeter / (2 * (math.sin(delta) + step.base * math.sin(gap / 2)));
  final points = List<Offset>.generate(step.base + 1, (i) {
    final a = i == 0 ? -delta : delta + (i - 1) * gap;
    return Offset(math.cos(a) * radius, math.sin(a) * radius);
  });

  // Center the area centroid, rather than the circumcircle, before rotation.
  var twiceArea = 0.0;
  var centroid = Offset.zero;
  for (var i = 0; i < points.length; i++) {
    final a = points[i];
    final b = points[(i + 1) % points.length];
    final cross = a.dx * b.dy - b.dx * a.dy;
    twiceArea += cross;
    centroid += (a + b) * cross;
  }
  centroid /= 3 * twiceArea;
  final c = math.cos(angle);
  final s = math.sin(angle);
  return points
      .map((point) {
        final p = point - centroid;
        return Offset(c * p.dx - s * p.dy, s * p.dx + c * p.dy);
      })
      .toList(growable: false);
}

/// Reference vertices in the SVG's 800 by 800 coordinate system, centered at 0.
/// Kept independent of rendering so the native port can be checked against SVG
/// samples and its constant perimeter and continuous loop can be verified.
@visibleForTesting
List<Offset> polygonMorphVerticesAt(Duration elapsed) =>
    _verticesAt(elapsed.inMicroseconds / Duration.microsecondsPerMillisecond);

// A convex polygon filled and stroked with a round join is its Minkowski sum
// with a disk of radius corner. Trace that outline directly with circular arcs:
// the hollow version can then use even-odd fill, without a mask or saveLayer.
Path _roundedOutline(List<Offset> points, {double scale = 1}) {
  final vertices = <Offset>[];
  for (final point in points) {
    final p = point * scale;
    if (vertices.isEmpty || (p - vertices.last).distanceSquared > 1e-12) {
      vertices.add(p);
    }
  }
  if ((vertices.first - vertices.last).distanceSquared <= 1e-12) {
    vertices.removeLast();
  }
  final normals = List<Offset>.generate(vertices.length, (i) {
    final edge = vertices[(i + 1) % vertices.length] - vertices[i];
    return Offset(edge.dy, -edge.dx) / edge.distance;
  });
  final path = Path();
  for (var i = 0; i < vertices.length; i++) {
    final incoming = normals[(i + vertices.length - 1) % vertices.length];
    final outgoing = normals[i];
    final startAngle = math.atan2(incoming.dy, incoming.dx);
    final endAngle = math.atan2(outgoing.dy, outgoing.dx);
    if (i == 0) {
      final start = vertices[i] + incoming * _corner;
      path.moveTo(start.dx, start.dy);
    }
    path.arcTo(
      Rect.fromCircle(center: vertices[i], radius: _corner),
      startAngle,
      (endAngle - startAngle) % _tau,
      false,
    );
  }
  return path..close();
}

class _PolygonMorphPainter extends CustomPainter {
  _PolygonMorphPainter({
    required this.animation,
    required this.color,
    required this.hollow,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final bool hollow;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final vertices = _verticesAt(
      animation.value * PolygonMorphLoader.cycleDuration.inMilliseconds,
    );
    final path = _roundedOutline(vertices);
    if (hollow) {
      // The reference SVG scales the hole's vertices, retaining the same
      // 104-unit round stroke. Keep that detail as well as its 0.72 scale.
      path.fillType = PathFillType.evenOdd;
      path.addPath(_roundedOutline(vertices, scale: _holeScale), Offset.zero);
    }
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final scale = size.shortestSide / _viewBox;
    canvas.scale(scale);
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PolygonMorphPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.hollow != hollow ||
      oldDelegate.animation != animation;
}
