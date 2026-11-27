import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass_panel.dart';

/// Editor-only chrome. Keep the contents mounted while a window or section is
/// collapsed so drafts, scroll positions and focused editors survive restoring.
class NodeEditorPanelFrame extends StatefulWidget {
  const NodeEditorPanelFrame({
    super.key,
    required this.header,
    required this.child,
    this.collapsed = false,
    this.headerHeight = 48,
  });

  final Widget header;
  final Widget child;
  final bool collapsed;
  final double headerHeight;

  @override
  State<NodeEditorPanelFrame> createState() => _NodeEditorPanelFrameState();
}

class _NodeEditorPanelFrameState extends State<NodeEditorPanelFrame> {
  Size _expandedBody = const Size(360, 480);

  @override
  Widget build(BuildContext context) => GlassPanel(
    radius: 20,
    blur: 12,
    padding: EdgeInsets.zero,
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Glass materials can inset their border by a fractional logical pixel.
        final headerHeight = math.min(
          widget.headerHeight,
          constraints.maxHeight,
        );
        if (!widget.collapsed) {
          _expandedBody = Size(
            constraints.maxWidth,
            math.max(0, constraints.maxHeight - headerHeight),
          );
        }
        return Column(
          children: [
            SizedBox(height: headerHeight, child: widget.header),
            Expanded(
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: _expandedBody.width,
                  maxWidth: _expandedBody.width,
                  minHeight: _expandedBody.height,
                  maxHeight: _expandedBody.height,
                  child: Visibility(
                    visible: !widget.collapsed,
                    maintainState: true,
                    child: ExcludeFocus(
                      excluding: widget.collapsed,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class NodeEditorPanelSection extends StatefulWidget {
  const NodeEditorPanelSection({
    super.key,
    required this.header,
    required this.child,
    required this.expanded,
    required this.headerHeight,
  });

  final Widget header;
  final Widget child;
  final bool expanded;
  final double headerHeight;

  @override
  State<NodeEditorPanelSection> createState() => _NodeEditorPanelSectionState();
}

class _NodeEditorPanelSectionState extends State<NodeEditorPanelSection> {
  double _bodyHeight = 160;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (widget.expanded) {
        _bodyHeight = math.max(0, constraints.maxHeight - widget.headerHeight);
      }
      return Column(
        children: [
          SizedBox(height: widget.headerHeight, child: widget.header),
          Expanded(
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: _bodyHeight,
                maxHeight: _bodyHeight,
                child: Visibility(
                  visible: widget.expanded,
                  maintainState: true,
                  child: ExcludeFocus(
                    excluding: !widget.expanded,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Narrow mobile windows can scroll wide parameter forms instead of clipping
/// their fields. Vertical scrolling remains the responsibility of each section.
class NodeEditorPanelViewport extends StatelessWidget {
  const NodeEditorPanelViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: math.max(320, constraints.maxWidth),
        height: constraints.maxHeight,
        child: child,
      ),
    ),
  );
}

/// A visible grip with mouse, touch, keyboard and accessibility adjustments.
class NodeEditorResizeHandle extends StatefulWidget {
  const NodeEditorResizeHandle({
    super.key,
    required this.axis,
    required this.label,
    required this.onDelta,
    this.onReset,
  });

  final Axis axis;
  final String label;
  final ValueChanged<double> onDelta;
  final VoidCallback? onReset;

  @override
  State<NodeEditorResizeHandle> createState() => _NodeEditorResizeHandleState();
}

class _NodeEditorResizeHandleState extends State<NodeEditorResizeHandle> {
  final FocusNode _focus = FocusNode();
  bool _hovered = false;
  bool _dragging = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.label,
      onIncrease: () => widget.onDelta(24),
      onDecrease: () => widget.onDelta(-24),
      child: Focus(
        focusNode: _focus,
        onFocusChange: (_) => setState(() {}),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final decrease = horizontal
              ? LogicalKeyboardKey.arrowLeft
              : LogicalKeyboardKey.arrowUp;
          final increase = horizontal
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowDown;
          if (event.logicalKey == decrease || event.logicalKey == increase) {
            widget.onDelta(event.logicalKey == decrease ? -16 : 16);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: horizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Tooltip(
            message: widget.label,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focus.requestFocus,
              onDoubleTap: widget.onReset,
              onHorizontalDragStart: horizontal
                  ? (_) => setState(() => _dragging = true)
                  : null,
              onHorizontalDragUpdate: horizontal
                  ? (details) => widget.onDelta(details.delta.dx)
                  : null,
              onHorizontalDragEnd: horizontal
                  ? (_) => setState(() => _dragging = false)
                  : null,
              onHorizontalDragCancel: horizontal
                  ? () => setState(() => _dragging = false)
                  : null,
              onVerticalDragStart: !horizontal
                  ? (_) => setState(() => _dragging = true)
                  : null,
              onVerticalDragUpdate: !horizontal
                  ? (details) => widget.onDelta(details.delta.dy)
                  : null,
              onVerticalDragEnd: !horizontal
                  ? (_) => setState(() => _dragging = false)
                  : null,
              onVerticalDragCancel: !horizontal
                  ? () => setState(() => _dragging = false)
                  : null,
              child: Center(
                child: AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 140),
                  width: horizontal ? 4 : 40,
                  height: horizontal ? 40 : 4,
                  decoration: BoxDecoration(
                    color: (_hovered || _dragging || _focus.hasFocus)
                        ? scheme.primary
                        : scheme.outlineVariant.withAlpha(150),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single glass surface keeps the rail light and follows the application's
/// liquid / blur / solid preferences without changing shared theme tokens.
class NodeEditorToolRail extends StatelessWidget {
  const NodeEditorToolRail({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withAlpha(32),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: GlassPanel(
        radius: 26,
        blur: 12,
        padding: const EdgeInsets.all(6),
        child: SingleChildScrollView(
          primary: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}
