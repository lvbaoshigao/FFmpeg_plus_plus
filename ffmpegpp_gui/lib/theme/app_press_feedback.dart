import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared, shape-bounded feedback for buttons and ink controls.
abstract final class AppPressFeedback {
  /// Replaces the spreading Material ripple with a soft surface light.
  static const InteractiveInkFeatureFactory splashFactory = _SoftPressFactory();

  /// Base feedback color for controls inheriting directly from [ThemeData].
  static Color splashColor(ColorScheme scheme) =>
      scheme.onSurface.withValues(alpha: 0.09);

  /// A low-contrast neutral tint for custom painted surfaces.
  static Color softOverlay(ColorScheme scheme, bool pressed) =>
      scheme.onSurface.withValues(alpha: pressed ? 0.08 : 0);

  /// Retains distinct hover, keyboard-focus and disabled states.
  static WidgetStateProperty<Color?> overlayColor(ColorScheme scheme) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return Colors.transparent;
        if (states.contains(WidgetState.focused)) {
          return scheme.primary.withValues(alpha: 0.14);
        }
        if (states.contains(WidgetState.pressed)) {
          // Native buttons use this for both their ink highlight and feature.
          return scheme.onSurface.withValues(alpha: 0.045);
        }
        if (states.contains(WidgetState.hovered)) {
          return scheme.onSurface.withValues(alpha: 0.045);
        }
        return null;
      });
}

/// Supplies view-specific motion and contrast preferences to ink rendering.
///
/// The ink factory itself has no BuildContext. Keep this above the Navigator
/// in each window so its feedback follows accessibility preference changes.
final class AppPressTheme extends StatelessWidget {
  const AppPressTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final highContrast = MediaQuery.highContrastOf(context);
    // Reuse the same factory while resizing; a new identity would invalidate
    // the theme throughout every route even when motion preferences are stable.
    final factory = switch ((reduced, highContrast)) {
      (false, false) => AppPressFeedback.splashFactory,
      (true, false) => const _SoftPressFactory(reducedMotion: true),
      (false, true) => const _SoftPressFactory(highContrast: true),
      (true, true) => const _SoftPressFactory(
        reducedMotion: true,
        highContrast: true,
      ),
    };
    return Theme(
      data: theme.copyWith(splashFactory: factory),
      child: child,
    );
  }
}

class _SoftPressFactory extends InteractiveInkFeatureFactory {
  const _SoftPressFactory({
    this.reducedMotion = false,
    this.highContrast = false,
  });

  final bool reducedMotion;
  final bool highContrast;

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) => _SoftPressFeature(
    controller: controller,
    referenceBox: referenceBox,
    color: color,
    textDirection: textDirection,
    rectCallback: rectCallback,
    borderRadius: borderRadius,
    customBorder: customBorder,
    reducedMotion:
        reducedMotion ||
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations,
    highContrast:
        highContrast ||
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .highContrast,
    onRemoved: onRemoved,
  );
}

class _SoftPressFeature extends InteractiveInkFeature {
  _SoftPressFeature({
    required super.controller,
    required super.referenceBox,
    required super.color,
    required this._textDirection,
    required bool reducedMotion,
    required this._highContrast,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    super.customBorder,
    super.onRemoved,
  }) : _reducedMotion = reducedMotion,
       _rect = rectCallback,
       _corners = borderRadius {
    _level =
        AnimationController(
            vsync: controller.vsync,
            duration: const Duration(milliseconds: 75),
            value: reducedMotion ? 1 : 0.25,
          )
          ..addListener(controller.markNeedsPaint)
          ..addStatusListener((status) {
            if (status == AnimationStatus.dismissed && _releasing) dispose();
          });
    controller.addInkFeature(this);
    if (!reducedMotion) _level.forward();
  }

  final TextDirection _textDirection;
  final bool _reducedMotion;
  final bool _highContrast;
  final RectCallback? _rect;
  final BorderRadius? _corners;
  final Paint _fillPaint = Paint();
  final Paint _edgePaint = Paint();
  Rect? _paintBounds;
  ShapeBorder? _paintBorder;
  Path? _clipPath;
  Shader? _edgeShader;
  Color? _shaderColor;
  late final AnimationController _level;
  bool _releasing = false;
  bool _disposed = false;

  void _release(Duration duration) {
    if (_disposed || _releasing) return;
    _releasing = true;
    if (_reducedMotion) {
      dispose();
    } else {
      _level.animateBack(0, duration: duration, curve: Curves.easeOutCubic);
    }
  }

  @override
  void confirm() => _release(const Duration(milliseconds: 165));

  @override
  void cancel() => _release(const Duration(milliseconds: 95));

  void _cachePaintResources(Rect bounds) {
    final border = customBorder;
    final resized = _paintBounds != bounds;
    if (resized || _paintBorder != border) {
      final corners =
          _corners ??
          BorderRadius.circular(math.min(12, bounds.shortestSide / 2));
      _clipPath =
          border?.getOuterPath(bounds, textDirection: _textDirection) ??
          (Path()..addRRect(corners.toRRect(bounds)));
      _paintBorder = border;
    }
    if (!_highContrast && (resized || _shaderColor != color)) {
      _disposeEdgeShader();
      // Keep the gradient fixed; Paint alpha carries the animation intensity.
      _edgeShader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 1), color.withValues(alpha: 0)],
      ).createShader(bounds);
      _edgePaint.shader = _edgeShader;
      _shaderColor = color;
    }
    _paintBounds = bounds;
  }

  void _disposeEdgeShader() {
    _edgePaint.shader = null;
    _edgeShader?.dispose();
    _edgeShader = null;
    _shaderColor = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _level.dispose();
    _disposeEdgeShader();
    _clipPath = null;
    _paintBounds = null;
    _paintBorder = null;
    super.dispose();
  }

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    if (_disposed || !referenceBox.hasSize || color.a == 0) return;
    final bounds = _rect?.call() ?? Offset.zero & referenceBox.size;
    if (bounds.isEmpty) return;
    _cachePaintResources(bounds);
    final strength = Curves.easeOutCubic.transform(_level.value);
    final alpha = (color.a * strength * (_highContrast ? 1.7 : 1)).clamp(
      0.0,
      1.0,
    );
    _fillPaint.color = color.withValues(alpha: alpha);
    canvas.save();
    canvas.transform(transform.storage);
    canvas.clipPath(_clipPath!);
    canvas.drawRect(bounds, _fillPaint);
    // A stationary, clipped edge light avoids a travelling ripple or scale.
    if (!_highContrast) {
      _edgePaint.color = color.withValues(alpha: alpha * 0.8);
      canvas.drawRect(bounds, _edgePaint);
    }
    canvas.restore();
  }
}
