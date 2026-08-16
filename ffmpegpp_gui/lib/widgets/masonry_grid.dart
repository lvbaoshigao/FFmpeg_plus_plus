import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Two-column masonry grid: cards fill the shorter column.
/// Each child gets full width/column, height adapts to content.
class MasonryGrid extends MultiChildRenderObjectWidget {
  final int columns;
  final double spacing;
  final double runSpacing;

  const MasonryGrid({
    super.key,
    this.columns = 2,
    this.spacing = 12,
    this.runSpacing = 12,
    required super.children,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      MasonryGridRenderObject(columns: columns, spacing: spacing, runSpacing: runSpacing);

  @override
  void updateRenderObject(BuildContext context, MasonryGridRenderObject renderObject) {
    renderObject
      ..columns = columns
      ..spacing = spacing
      ..runSpacing = runSpacing;
  }
}

class MasonryGridRenderObject extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, MasonryGridParentData>,
         RenderBoxContainerDefaultsMixin<RenderBox, MasonryGridParentData> {
  int columns;
  double spacing;
  double runSpacing;

  MasonryGridRenderObject({required this.columns, required this.spacing, required this.runSpacing});

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MasonryGridParentData) {
      child.parentData = MasonryGridParentData();
    }
  }

  @override
  void performLayout() {
    final w = constraints.maxWidth;
    final colW = (w - spacing * (columns - 1)) / columns;
    final colH = List.filled(columns, 0.0);

    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tightFor(width: colW), parentUsesSize: true);
      final idx = _shortestColumn(colH);
      final parentData = child.parentData! as MasonryGridParentData;
      parentData.offset = Offset(idx * (colW + spacing), colH[idx]);
      colH[idx] += child.size.height + runSpacing;
      child = parentData.nextSibling;
    }

    final maxH = colH.reduce((a, b) => a > b ? a : b) - runSpacing;
    size = Size(w, maxH.clamp(0, double.infinity));
  }

  int _shortestColumn(List<double> colH) {
    var minIdx = 0;
    for (var i = 1; i < colH.length; i++) {
      if (colH[i] < colH[minIdx]) minIdx = i;
    }
    return minIdx;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}

class MasonryGridParentData extends ContainerBoxParentData<RenderBox> {}
