import 'package:flutter/material.dart';

import '../models/node_picker_options.dart';
import '../theme/app_neutral_surface.dart';

/// Compact, exclusive categories shared by the editor's element panels.
/// Opaque neutral fills keep labels readable when a wallpaper shows behind them.
class NodeCategoryFilter extends StatelessWidget {
  const NodeCategoryFilter({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
    required this.isZh,
    this.dense = true,
    this.keyPrefix = 'node-picker-category',
  });

  final List<NodePickerCategory> categories;
  final NodePickerCategory value;
  final ValueChanged<NodePickerCategory> onChanged;
  final bool isZh;
  final bool dense;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final base = dark
        ? AppNeutralSurface.darkCard
        : AppNeutralSurface.lightBackground;
    return FocusTraversalGroup(
      child: LayoutBuilder(
        builder: (context, constraints) => Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final category in categories)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: Tooltip(
                  message: nodePickerCategoryLabel(category, isZh: isZh),
                  excludeFromSemantics: true,
                  child: ChoiceChip(
                    key: ValueKey('$keyPrefix-${category.name}'),
                    label: ConstrainedBox(
                      // Account for chip padding in the initial text layout so
                      // long labels can grow vertically even in a narrow pane.
                      constraints: BoxConstraints(
                        maxWidth: (constraints.maxWidth - (dense ? 20 : 24))
                            .clamp(0.0, double.infinity)
                            .toDouble(),
                      ),
                      child: Text(
                        nodePickerCategoryLabel(category, isZh: isZh),
                        textAlign: TextAlign.center,
                        softWrap: true,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    selected: value == category,
                    onSelected: (_) => onChanged(category),
                    // The border and tint convey selection without adding a
                    // checkmark that changes widths and reflows adjacent chips.
                    showCheckmark: false,
                    labelStyle: TextStyle(
                      fontSize: dense ? 12 : 13,
                      fontWeight: FontWeight.w500,
                      color: value == category
                          ? scheme.primary
                          : highContrast
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                    color: WidgetStateProperty.resolveWith((states) {
                      var tint = states.contains(WidgetState.selected)
                          ? (dark ? 0.14 : 0.09)
                          : 0.0;
                      if (states.contains(WidgetState.pressed)) {
                        tint += 0.08;
                      } else if (states.contains(WidgetState.hovered)) {
                        tint += 0.04;
                      }
                      return Color.alphaBlend(
                        scheme.primary.withValues(alpha: tint),
                        base,
                      );
                    }),
                    side: WidgetStateBorderSide.resolveWith((states) {
                      final focused = states.contains(WidgetState.focused);
                      return BorderSide(
                        color: focused
                            ? scheme.primary
                            : highContrast
                            ? scheme.onSurface
                            : states.contains(WidgetState.selected)
                            ? scheme.primary.withValues(alpha: 0.6)
                            : scheme.outline.withValues(alpha: 0.32),
                        width: focused || highContrast ? 1.5 : 1,
                      );
                    }),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: dense ? 10 : 12,
                      vertical: 4,
                    ),
                    labelPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.standard,
                    materialTapTargetSize: dense
                        ? MaterialTapTargetSize.shrinkWrap
                        : MaterialTapTargetSize.padded,
                    elevation: 0,
                    pressElevation: 0,
                    shadowColor: Colors.transparent,
                    selectedShadowColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
