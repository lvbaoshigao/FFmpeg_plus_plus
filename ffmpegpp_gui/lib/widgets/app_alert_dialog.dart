import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_neutral_surface.dart';
import 'liquid_glass_fallback.dart' show cachedGlassBlur;

/// Semantic visual role for an action shown in a modal surface.
enum AppDialogActionRole { cancel, primary, destructive, neutral }

/// Styles an existing action without changing its callback or button type.
class AppDialogAction extends StatelessWidget {
  const AppDialogAction({
    super.key,
    required this.child,
    this.role = AppDialogActionRole.neutral,
  });

  final Widget child;
  final AppDialogActionRole role;

  static Color _secondaryBackgroundOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? AppNeutralSurface.darkControl
      : AppNeutralSurface.lightCardHigh;

  /// Shared role styling for buttons in custom modal headers and footers.
  static ButtonStyle styleOf(BuildContext context, AppDialogActionRole role) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (role) {
      AppDialogActionRole.cancel => (
        _secondaryBackgroundOf(context),
        colors.onSurface,
      ),
      AppDialogActionRole.primary => (colors.primary, colors.onPrimary),
      AppDialogActionRole.destructive => (colors.error, colors.onError),
      AppDialogActionRole.neutral => (
        _secondaryBackgroundOf(context),
        colors.onSurface,
      ),
    };
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? background.withAlpha(80)
            : background,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? colors.onSurface.withAlpha(96)
            : foreground,
      ),
      overlayColor: WidgetStatePropertyAll(foreground.withAlpha(24)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
      maximumSize: const WidgetStatePropertyAll(Size.infinite),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      side: const WidgetStatePropertyAll(BorderSide.none),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      alignment: Alignment.center,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (role) {
      AppDialogActionRole.cancel => (
        _secondaryBackgroundOf(context),
        colors.onSurface,
      ),
      AppDialogActionRole.primary => (colors.primary, colors.onPrimary),
      AppDialogActionRole.destructive => (colors.error, colors.onError),
      AppDialogActionRole.neutral => (
        _secondaryBackgroundOf(context),
        colors.onSurface,
      ),
    };
    final original = child is ButtonStyleButton
        ? (child as ButtonStyleButton).style
        : null;
    final style = styleOf(context, role).merge(original);
    final styledChild = _copyButtonWithStyle(child, style);

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: SizedBox(
        width: double.infinity,
        child:
            styledChild ??
            DecoratedBox(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: foreground),
                  child: IconTheme.merge(
                    data: IconThemeData(color: foreground),
                    child: child,
                  ),
                ),
              ),
            ),
      ),
    );
  }

  Widget? _copyButtonWithStyle(Widget child, ButtonStyle style) =>
      switch (child) {
        final TextButton button => TextButton(
          key: button.key,
          onPressed: button.onPressed,
          onLongPress: button.onLongPress,
          onHover: button.onHover,
          onFocusChange: button.onFocusChange,
          style: style,
          focusNode: button.focusNode,
          autofocus: button.autofocus,
          clipBehavior: button.clipBehavior,
          statesController: button.statesController,
          isSemanticButton: button.isSemanticButton,
          child: button.child!,
        ),
        final FilledButton button => FilledButton(
          key: button.key,
          onPressed: button.onPressed,
          onLongPress: button.onLongPress,
          onHover: button.onHover,
          onFocusChange: button.onFocusChange,
          style: style,
          focusNode: button.focusNode,
          autofocus: button.autofocus,
          clipBehavior: button.clipBehavior,
          statesController: button.statesController,
          child: button.child!,
        ),
        final ElevatedButton button => ElevatedButton(
          key: button.key,
          onPressed: button.onPressed,
          onLongPress: button.onLongPress,
          onHover: button.onHover,
          onFocusChange: button.onFocusChange,
          style: style,
          focusNode: button.focusNode,
          autofocus: button.autofocus,
          clipBehavior: button.clipBehavior,
          statesController: button.statesController,
          child: button.child!,
        ),
        final OutlinedButton button => OutlinedButton(
          key: button.key,
          onPressed: button.onPressed,
          onLongPress: button.onLongPress,
          onHover: button.onHover,
          onFocusChange: button.onFocusChange,
          style: style,
          focusNode: button.focusNode,
          autofocus: button.autofocus,
          clipBehavior: button.clipBehavior,
          statesController: button.statesController,
          child: button.child!,
        ),
        _ => null,
      };
}

/// A shared, Material-styled alert dialog for app-owned confirmation flows.
///
/// It mirrors the ordinary [AlertDialog] constructor and keeps the Material
/// surface on every platform without overriding platform-specific editing.
class AppAlertDialog extends StatelessWidget {
  const AppAlertDialog({
    super.key,
    this.icon,
    this.iconPadding,
    this.iconColor,
    this.title,
    this.titlePadding,
    this.titleTextStyle,
    this.content,
    this.contentPadding,
    this.contentTextStyle,
    this.actions,
    this.actionsPadding,
    this.actionsAlignment,
    this.actionsOverflowAlignment,
    this.actionsOverflowDirection,
    this.actionsOverflowButtonSpacing,
    this.buttonPadding,
    this.backgroundColor,
    this.elevation,
    this.shadowColor,
    this.surfaceTintColor,
    this.semanticLabel,
    this.insetPadding,
    this.clipBehavior,
    this.shape,
    this.alignment,
    this.constraints,
    this.scrollable = false,
  });

  final Widget? icon;
  final EdgeInsetsGeometry? iconPadding;
  final Color? iconColor;
  final Widget? title;
  final EdgeInsetsGeometry? titlePadding;
  final TextStyle? titleTextStyle;
  final Widget? content;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? contentTextStyle;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? actionsPadding;
  final MainAxisAlignment? actionsAlignment;
  final OverflowBarAlignment? actionsOverflowAlignment;
  final VerticalDirection? actionsOverflowDirection;
  final double? actionsOverflowButtonSpacing;
  final EdgeInsetsGeometry? buttonPadding;
  final Color? backgroundColor;
  final double? elevation;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final String? semanticLabel;
  final EdgeInsets? insetPadding;
  final Clip? clipBehavior;
  final ShapeBorder? shape;
  final AlignmentGeometry? alignment;
  final BoxConstraints? constraints;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final dialogTheme = DialogTheme.of(context);
    final direction = Directionality.of(context);
    final dialogInsets =
        insetPadding ??
        dialogTheme.insetPadding ??
        const EdgeInsets.symmetric(horizontal: 20, vertical: 24);
    final actionInsets =
        (actionsPadding ??
                dialogTheme.actionsPadding ??
                const EdgeInsets.fromLTRB(24, 8, 24, 20))
            .resolve(direction);
    final dialogWidth = math.max(
      0.0,
      math.min(
        constraints?.maxWidth ?? dialogTheme.constraints?.maxWidth ?? 560,
        media.size.width -
            media.padding.horizontal -
            media.viewInsets.horizontal -
            dialogInsets.horizontal,
      ),
    );
    final actionWidth = math.max(0.0, dialogWidth - actionInsets.horizontal);
    final resolvedShape =
        shape ??
        dialogTheme.shape ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
        );
    final surface =
        backgroundColor ??
        dialogTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerHigh;
    final resolvedTitleStyle =
        titleTextStyle ??
        dialogTheme.titleTextStyle ??
        theme.textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w600);
    final resolvedContentStyle =
        contentTextStyle ??
        dialogTheme.contentTextStyle ??
        theme.textTheme.bodyMedium!;

    final chrome = SizedBox(
      width: dialogWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (icon != null)
            Padding(
              padding:
                  iconPadding ??
                  EdgeInsets.fromLTRB(
                    24,
                    20,
                    24,
                    title != null
                        ? 16
                        : content != null
                        ? 0
                        : 20,
                  ),
              child: IconTheme.merge(
                data: IconThemeData(
                  color:
                      iconColor ??
                      dialogTheme.iconColor ??
                      theme.colorScheme.secondary,
                ),
                child: icon!,
              ),
            ),
          if (title != null)
            Padding(
              padding:
                  titlePadding ??
                  EdgeInsets.fromLTRB(24, icon == null ? 20 : 0, 24, 0),
              child: DefaultTextStyle(
                style: resolvedTitleStyle,
                textAlign: icon == null ? TextAlign.start : TextAlign.center,
                child: Semantics(
                  namesRoute:
                      semanticLabel == null &&
                      theme.platform != TargetPlatform.iOS,
                  container: true,
                  child: title,
                ),
              ),
            ),
          if (content != null)
            Padding(
              padding:
                  contentPadding ??
                  EdgeInsets.fromLTRB(
                    24,
                    title == null && icon == null ? 20 : 8,
                    24,
                    16,
                  ),
              child: DefaultTextStyle(
                style: resolvedContentStyle,
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: content,
                ),
              ),
            ),
          if (actions != null && actions!.isNotEmpty)
            Padding(
              padding: actionInsets,
              child: OverflowBar(
                alignment: actionsAlignment ?? MainAxisAlignment.end,
                spacing: (buttonPadding?.horizontal ?? 16) / 2,
                overflowAlignment:
                    actionsOverflowAlignment ?? OverflowBarAlignment.end,
                overflowDirection:
                    actionsOverflowDirection ?? VerticalDirection.down,
                overflowSpacing: actionsOverflowButtonSpacing ?? 0,
                children: [
                  SizedBox(
                    width: actionWidth,
                    child: _ResponsiveDialogActions(
                      pairFits:
                          actions!.length == 2 &&
                          actionWidth >= 200 * media.textScaler.scale(1) &&
                          media.textScaler.scale(1) <= 1.3,
                      actions: [
                        for (var i = 0; i < actions!.length; i++)
                          if (actions![i] is AppDialogAction)
                            actions![i]
                          else
                            AppDialogAction(
                              role: _roleFor(i, actions!, theme.colorScheme),
                              child: actions![i],
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    // Keep one scroll viewport around title, form, and footer so the keyboard
    // cannot leave the actions or title outside the available dialog height.
    Widget body = SingleChildScrollView(child: chrome);
    if (!media.highContrast && !media.disableAnimations && surface.a < 1) {
      body = BackdropFilter(filter: cachedGlassBlur(8), child: body);
    }
    body = ClipPath(
      clipper: ShapeBorderClipper(
        shape: resolvedShape,
        textDirection: direction,
      ),
      child: body,
    );

    return AlertDialog(
      content: body,
      contentPadding: EdgeInsets.zero,
      backgroundColor: media.highContrast
          ? surface.withAlpha(255)
          : backgroundColor,
      elevation: elevation,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      semanticLabel: semanticLabel,
      insetPadding: insetPadding,
      clipBehavior: clipBehavior,
      shape: shape,
      alignment: alignment,
      constraints: constraints,
    );
  }

  AppDialogActionRole _roleFor(
    int index,
    List<Widget> children,
    ColorScheme colors,
  ) {
    final action = children[index];
    if (action is ButtonStyleButton) {
      final background = action.style?.backgroundColor?.resolve({});
      final foreground = action.style?.foregroundColor?.resolve({});
      if (background == colors.error || foreground == colors.error) {
        return AppDialogActionRole.destructive;
      }
    }
    if (index == children.length - 1) return AppDialogActionRole.primary;
    if (children.length == 2 && index == 0) return AppDialogActionRole.cancel;
    return AppDialogActionRole.neutral;
  }
}

class _ResponsiveDialogActions extends StatelessWidget {
  const _ResponsiveDialogActions({
    required this.actions,
    required this.pairFits,
  });

  final List<Widget> actions;
  final bool pairFits;

  @override
  Widget build(BuildContext context) {
    if (pairFits) {
      return Row(
        children: [
          Expanded(child: actions[0]),
          const SizedBox(width: 8),
          Expanded(child: actions[1]),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          actions[i],
        ],
      ],
    );
  }
}

/// Shared Material dialog shell for custom dialog content that needs its own
/// layout (for example a wide editor) instead of alert sizing.
class AppModalSurface extends StatelessWidget {
  const AppModalSurface({
    super.key,
    required this.child,
    this.insetPadding,
    this.constraints,
    this.alignment,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsets? insetPadding;
  final BoxConstraints? constraints;
  final AlignmentGeometry? alignment;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final surface =
        DialogTheme.of(context).backgroundColor ??
        theme.colorScheme.surfaceContainerHigh;
    return Dialog(
      backgroundColor: media.highContrast ? surface.withAlpha(255) : null,
      insetPadding: insetPadding,
      constraints: constraints,
      alignment: alignment,
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}
