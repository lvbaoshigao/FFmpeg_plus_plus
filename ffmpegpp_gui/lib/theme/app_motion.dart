import 'package:flutter/material.dart';

import 'app_motion_binding.dart';
import 'app_page_transitions.dart';

/// Applies the app preference together with the platform accessibility setting.
/// Keep the Navigator and its overlays below this scope in every window.
class AppMotion extends StatelessWidget {
  const AppMotion({super.key, required this.disabled, required this.child});

  final bool disabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final binding = WidgetsBinding.instance;
    if (binding is AppMotionBinding) {
      binding.appAnimationsDisabled = disabled;
    }
    final media = MediaQuery.of(context);
    final reduceMotion = disabled || media.disableAnimations;
    final theme = Theme.of(context);
    return MediaQuery(
      data: media.copyWith(
        disableAnimations: reduceMotion,
        accessibleNavigation: media.accessibleNavigation || reduceMotion,
      ),
      child: Theme(
        data: reduceMotion
            ? theme.copyWith(
                pageTransitionsTheme: PageTransitionsTheme(
                  builders: {
                    for (final platform in TargetPlatform.values)
                      platform: _NoMotionPageTransitionsBuilder(
                        theme.pageTransitionsTheme.builders[platform],
                      ),
                  },
                ),
                expansionTileTheme: theme.expansionTileTheme.copyWith(
                  expansionAnimationStyle: AnimationStyle.noAnimation,
                ),
                textButtonTheme: TextButtonThemeData(
                  style: (theme.textButtonTheme.style ?? const ButtonStyle())
                      .copyWith(animationDuration: Duration.zero),
                ),
                elevatedButtonTheme: ElevatedButtonThemeData(
                  style:
                      (theme.elevatedButtonTheme.style ?? const ButtonStyle())
                          .copyWith(animationDuration: Duration.zero),
                ),
                filledButtonTheme: FilledButtonThemeData(
                  style: (theme.filledButtonTheme.style ?? const ButtonStyle())
                      .copyWith(animationDuration: Duration.zero),
                ),
                outlinedButtonTheme: OutlinedButtonThemeData(
                  style:
                      (theme.outlinedButtonTheme.style ?? const ButtonStyle())
                          .copyWith(animationDuration: Duration.zero),
                ),
                iconButtonTheme: IconButtonThemeData(
                  style: (theme.iconButtonTheme.style ?? const ButtonStyle())
                      .copyWith(animationDuration: Duration.zero),
                ),
              )
            : theme,
        child: child,
      ),
    );
  }
}

// Keep the app's predictive-back observer while its transition widgets honor
// MediaQuery.disableAnimations. Returning the page directly loses navigation
// events along with the visual effect.
class _NoMotionPageTransitionsBuilder extends AppPageTransitionsBuilder {
  _NoMotionPageTransitionsBuilder(PageTransitionsBuilder? original)
    : super(
        predictiveBack:
            original is AppPageTransitionsBuilder && original.predictiveBack,
      );

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;
}
