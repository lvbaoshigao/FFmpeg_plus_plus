import 'package:flutter/material.dart';

import '../platform/app_platform.dart';

/// Uses the project page's breakpoint and the space available to the page.
/// Window chrome and navigation remain outside this layout.
class AppTopBarLayout extends StatelessWidget {
  const AppTopBarLayout({super.key, required this.builder});

  final Widget Function(BuildContext context, bool compact) builder;

  static const double compactBreakpoint = 600;

  static bool isCompact(BuildContext context, BoxConstraints constraints) {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return isMobilePlatform ||
        constraints.maxWidth < compactBreakpoint * textScale.clamp(1.0, 1.5);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        builder(context, isCompact(context, constraints)),
  );
}

/// Selects the existing long bar or pill bar without changing page contents.
class AdaptiveTopBar extends StatelessWidget {
  const AdaptiveTopBar({
    super.key,
    required this.expandedBuilder,
    required this.compactBuilder,
  });

  final WidgetBuilder expandedBuilder;
  final WidgetBuilder compactBuilder;

  @override
  Widget build(BuildContext context) => AppTopBarLayout(
    builder: (context, compact) =>
        (compact ? compactBuilder : expandedBuilder)(context),
  );
}
