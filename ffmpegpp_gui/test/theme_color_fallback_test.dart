import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/theme/app_accent_surface.dart';
import 'package:ffmpegpp_gui/theme/app_neutral_surface.dart';
import 'package:ffmpegpp_gui/theme/app_semantic_colors.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/theme/mobile_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ThemeData _theme(
  Brightness brightness, {
  int seedColor = AppTheme.defaultSeedColor,
  int? dynamicSeed,
  bool useThemeColor = true,
  String glassEffect = 'liquid',
}) => brightness == Brightness.dark
    ? AppTheme.dark(
        seedColor: seedColor,
        dynamicSeed: dynamicSeed,
        useThemeColor: useThemeColor,
        glassEffect: glassEffect,
      )
    : AppTheme.light(
        seedColor: seedColor,
        dynamicSeed: dynamicSeed,
        useThemeColor: useThemeColor,
        glassEffect: glassEffect,
      );

List<Color> _accents(ColorScheme s) => [
  s.primary,
  s.onPrimary,
  s.primaryContainer,
  s.onPrimaryContainer,
  s.primaryFixed,
  s.primaryFixedDim,
  s.onPrimaryFixed,
  s.onPrimaryFixedVariant,
  s.secondary,
  s.onSecondary,
  s.secondaryContainer,
  s.onSecondaryContainer,
  s.secondaryFixed,
  s.secondaryFixedDim,
  s.onSecondaryFixed,
  s.onSecondaryFixedVariant,
  s.tertiary,
  s.onTertiary,
  s.tertiaryContainer,
  s.onTertiaryContainer,
  s.tertiaryFixed,
  s.tertiaryFixedDim,
  s.onTertiaryFixed,
  s.onTertiaryFixedVariant,
  s.inversePrimary,
];

void _expectNeutral(Color color) {
  expect(color.r, closeTo(color.g, 1 / 255));
  expect(color.g, closeTo(color.b, 1 / 255));
}

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    group('Theme color fallback ($brightness)', () {
      test(
        'ignores custom and dynamic seeds and restores all default accents',
        () {
          final defaults = _theme(brightness).colorScheme;
          for (final seed in [0xFFFF0088, 0xFF009967, 0xFF777777]) {
            for (final dynamicSeed in [null, 0xFFFFCC00, 0xFF0088FF]) {
              final fallback = _theme(
                brightness,
                seedColor: seed,
                dynamicSeed: dynamicSeed,
                useThemeColor: false,
              ).colorScheme;
              expect(_accents(fallback), _accents(defaults));
              expect(
                HSVColor.fromColor(fallback.primary).saturation,
                greaterThan(0.15),
              );
            }
          }
        },
      );

      test('keeps surfaces neutral and foreground pairs readable', () {
        for (final effect in ['none', 'blur', 'liquid']) {
          final theme = _theme(
            brightness,
            seedColor: 0xFFFF0088,
            dynamicSeed: 0xFF009967,
            useThemeColor: false,
            glassEffect: effect,
          );
          final s = theme.colorScheme;
          for (final color in [
            s.surface,
            s.surfaceDim,
            s.surfaceBright,
            s.surfaceContainerLowest,
            s.surfaceContainerLow,
            s.surfaceContainer,
            s.surfaceContainerHigh,
            s.surfaceContainerHighest,
            s.onSurface,
            s.onSurfaceVariant,
            s.outline,
            s.outlineVariant,
            s.inverseSurface,
            s.onInverseSurface,
            s.surfaceTint,
            theme.scaffoldBackgroundColor,
            theme.dialogTheme.backgroundColor!,
          ]) {
            _expectNeutral(color);
          }
          expect(
            theme.scaffoldBackgroundColor,
            AppNeutralSurface.background(brightness),
          );
          for (final (foreground, background) in [
            (s.onPrimary, s.primary),
            (s.onPrimaryContainer, s.primaryContainer),
            (s.onSecondary, s.secondary),
            (s.onSecondaryContainer, s.secondaryContainer),
            (s.onTertiary, s.tertiary),
            (s.onTertiaryContainer, s.tertiaryContainer),
            (s.onSurface, s.surface),
            (s.onSurfaceVariant, s.surfaceContainerHighest),
          ]) {
            expect(
              _contrast(foreground, background),
              greaterThanOrEqualTo(4.5),
            );
          }
          final accent = AppAccentSurface.fromScheme(s);
          expect(
            _contrast(accent.foreground, accent.fill),
            greaterThanOrEqualTo(4.5),
          );
          expect(accent.fill, isNot(s.primary));
          expect(theme.sliderTheme.activeTrackColor, s.primary);
          expect(theme.progressIndicatorTheme.color, s.primary);
          expect(
            theme.radioTheme.fillColor!.resolve({WidgetState.selected}),
            s.primary,
          );
          expect(
            theme.inputDecorationTheme.focusedBorder!.borderSide.color,
            s.primary,
          );
        }
      });

      test(
        'semantic colors follow their scheme when default accents are shared',
        () {
          final defaults = _theme(brightness);
          final fallback = _theme(brightness, useThemeColor: false);
          for (final theme in [defaults, fallback, defaults, fallback]) {
            final s = theme.colorScheme;
            final sem = s.sem;
            expect(sem.neutral, s.outline);
            expect(sem.neutralContainer, s.surfaceContainerHighest);
            expect(sem.info, s.primary);
            expect(sem.infoContainer, s.primaryContainer);
            expect(sem.danger, s.error);
            expect(sem.dangerContainer, s.errorContainer);
            expect(theme.extension<AppSemantic>(), same(sem));
            expect(s.sem, same(sem));
            expect(sem.success, isNot(sem.neutral));
            expect(sem.warning, isNot(sem.neutral));
          }
        },
      );

      test(
        'dynamic colors take priority only while custom accents are enabled',
        () {
          final dynamicTheme = _theme(
            brightness,
            seedColor: 0xFFFF0088,
            dynamicSeed: 0xFF009967,
          );
          expect(
            dynamicTheme.colorScheme,
            _theme(brightness, seedColor: 0xFF009967).colorScheme,
          );
          final fallback = _theme(
            brightness,
            dynamicSeed: 0xFF009967,
            useThemeColor: false,
          );
          expect(
            fallback.colorScheme.primary,
            _theme(brightness).colorScheme.primary,
          );
          final mobile = const MobileVisualTheme(
            enabled: true,
          ).applyTo(fallback);
          expect(_accents(mobile.colorScheme), _accents(fallback.colorScheme));
          _expectNeutral(mobile.colorScheme.surface);
          _expectNeutral(mobile.colorScheme.surfaceContainerHighest);
        },
      );

      test(
        'mobile visuals refresh semantic roles for their neutral surfaces',
        () {
          for (final enabled in [true, false]) {
            final base = _theme(brightness, useThemeColor: enabled);
            final mobile = const MobileVisualTheme(enabled: true).applyTo(base);
            final sem = mobile.extension<AppSemantic>()!;
            expect(sem.neutral, mobile.colorScheme.outline);
            expect(
              sem.neutralContainer,
              mobile.colorScheme.surfaceContainerHighest,
            );
            expect(sem, same(mobile.colorScheme.sem));
            expect(sem.info, base.colorScheme.primary);
          }
        },
      );

      testWidgets(
        'toggling custom accents updates real controls and preserves saved colors',
        (tester) async {
          final config = AppConfig()
            ..themeColor = 0xFF009967
            ..themeColor2 = 0xFFFF0088;
          final saved = config.toJson()..remove('use_theme_color');
          await tester.pumpWidget(
            StatefulBuilder(
              builder: (context, setState) => MaterialApp(
                theme: _theme(
                  brightness,
                  seedColor: config.themeColor,
                  useThemeColor: config.useThemeColor,
                ),
                themeAnimationDuration: Duration.zero,
                home: Scaffold(
                  body: Column(
                    children: [
                      FilledButton(
                        key: const ValueKey('primary-action'),
                        onPressed: () {},
                        child: const Text('Run'),
                      ),
                      const LinearProgressIndicator(value: 0.5),
                      TextButton(
                        onPressed: () => setState(() {
                          config.useThemeColor = !config.useThemeColor;
                        }),
                        child: const Text('Toggle custom accents'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          Color actionColor() => tester
              .widget<Material>(
                find
                    .descendant(
                      of: find.byKey(const ValueKey('primary-action')),
                      matching: find.byType(Material),
                    )
                    .first,
              )
              .color!;
          final custom = actionColor();
          expect(
            custom,
            _theme(
              brightness,
              seedColor: config.themeColor,
            ).colorScheme.primary,
          );
          await tester.tap(find.text('Toggle custom accents'));
          await tester.pumpAndSettle();
          final fallbackColor = _theme(brightness).colorScheme.primary;
          expect(actionColor(), fallbackColor);
          expect(actionColor(), isNot(custom));
          final context = tester.element(find.byType(LinearProgressIndicator));
          expect(Theme.of(context).progressIndicatorTheme.color, fallbackColor);
          expect(config.toJson()..remove('use_theme_color'), saved);
          await tester.tap(find.text('Toggle custom accents'));
          await tester.pumpAndSettle();
          expect(actionColor(), custom);
          expect(config.toJson()..remove('use_theme_color'), saved);
          expect(tester.takeException(), isNull);
        },
      );
    });
  }
}
