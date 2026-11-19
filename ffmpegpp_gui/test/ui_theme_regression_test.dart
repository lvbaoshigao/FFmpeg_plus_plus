import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/theme/mobile_visual_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_card.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

double _contrastRatio(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}

void main() {
  group('AppTheme dialogs', () {
    test(
      'should keep modal text and field focus readable over any backdrop',
      () {
        for (final seed in [0xff315cc0, 0xff348460, 0xffd55823]) {
          for (final effect in ['none', 'blur', 'liquid']) {
            for (final theme in [
              AppTheme.light(seedColor: seed, glassEffect: effect),
              AppTheme.dark(seedColor: seed, glassEffect: effect),
            ]) {
              final dialog = theme.dialogTheme;
              final input = theme.inputDecorationTheme;
              for (final backdrop in [Colors.black, Colors.white]) {
                final surface = Color.alphaBlend(
                  dialog.backgroundColor!,
                  backdrop,
                );
                final field = Color.alphaBlend(input.fillColor!, surface);
                for (final foreground in [
                  dialog.titleTextStyle!.color!,
                  dialog.contentTextStyle!.color!,
                  theme.colorScheme.primary,
                ]) {
                  expect(
                    _contrastRatio(foreground, surface),
                    greaterThanOrEqualTo(4.5),
                  );
                }
                expect(
                  _contrastRatio(input.hintStyle!.color!, field),
                  greaterThanOrEqualTo(4.5),
                );
                for (final border in [
                  input.focusedBorder!,
                  input.focusedErrorBorder!,
                ]) {
                  expect(
                    _contrastRatio(border.borderSide.color, field),
                    greaterThanOrEqualTo(3),
                  );
                }
                final sheet = Color.alphaBlend(
                  theme.bottomSheetTheme.backgroundColor!,
                  backdrop,
                );
                expect(
                  _contrastRatio(theme.colorScheme.onSurfaceVariant, sheet),
                  greaterThanOrEqualTo(4.5),
                );
              }
            }
          }
        }
      },
    );

    testWidgets(
      'should keep compact large-text dialogs accessible by keyboard',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final inputFocus = FocusNode();
        final cancelFocus = FocusNode();
        final saveFocus = FocusNode();
        addTearDown(inputFocus.dispose);
        addTearDown(cancelFocus.dispose);
        addTearDown(saveFocus.dispose);
        final theme = AppTheme.dark(fontWeight: 700);
        String? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.5),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showDialog<String>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Configuration options'),
                        content: TextField(
                          focusNode: inputFocus,
                          autofocus: true,
                          decoration: const InputDecoration(labelText: 'Name'),
                        ),
                        actions: [
                          TextButton(
                            focusNode: cancelFocus,
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Keep editing'),
                          ),
                          FilledButton(
                            focusNode: saveFocus,
                            onPressed: () => Navigator.pop(context, 'saved'),
                            child: const Text('Save preset'),
                          ),
                        ],
                      ),
                    );
                  },
                  child: const Text('Open dialog'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open dialog'));
        await tester.pumpAndSettle();
        final materialFinder = find.descendant(
          of: find.byType(Dialog),
          matching: find.byWidgetPredicate(
            (widget) => widget is Material && widget.type == MaterialType.card,
          ),
        );
        final material = tester.widget<Material>(materialFinder);
        expect(material.color, theme.dialogTheme.backgroundColor);
        expect(tester.getSize(materialFinder).width, greaterThanOrEqualTo(280));
        expect(find.bySemanticsLabel('Save preset'), findsOneWidget);
        expect(
          DefaultTextStyle.of(
            tester.element(find.text('Configuration options')),
          ).style.fontWeight,
          FontWeight.w700,
        );
        expect(inputFocus.hasFocus, isTrue);
        await tester.enterText(find.byType(TextField), 'Preset');
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pumpAndSettle();
        expect(
          tester.getBottomRight(materialFinder).dy,
          lessThanOrEqualTo(520),
        );
        expect(
          tester.getSize(find.byType(FilledButton)).height,
          greaterThanOrEqualTo(48),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(cancelFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(saveFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(inputFocus.hasFocus, isTrue);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(saveFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(result, 'saved');
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'should theme sheets while preserving custom transparent panels',
      (tester) async {
        final standardTheme = AppTheme.light();
        final mobileTheme = resolveMobileVisualTheme(
          'miuix',
          isMobile: true,
        ).applyTo(standardTheme);
        for (final theme in [standardTheme, mobileTheme]) {
          for (final backgroundOverride in [null, Colors.transparent]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        backgroundColor: backgroundOverride,
                        sheetAnimationStyle: AnimationStyle.noAnimation,
                        builder: (context) => SizedBox(
                          height: 160,
                          child: Center(
                            child: TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close sheet'),
                            ),
                          ),
                        ),
                      ),
                      child: const Text('Open sheet'),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('Open sheet'));
            await tester.pumpAndSettle();
            final material = tester.widget<Material>(
              find
                  .descendant(
                    of: find.byType(BottomSheet),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            expect(
              material.color,
              backgroundOverride ?? theme.bottomSheetTheme.backgroundColor,
            );
            await tester.tap(find.text('Close sheet'));
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsNothing);
            expect(tester.takeException(), isNull);
          }
        }
      },
    );
  });

  group('Theme preferences', () {
    testWidgets(
      'should apply a weight selection and render it after restoring config',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState();
        state.config.cardStyle = 'gray';
        state.config.menuStyle = 'gray';
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: Consumer<AppState>(
              builder: (context, state, _) => MaterialApp(
                theme: AppTheme.dark(fontWeight: state.config.fontWeightValue),
                home: const Scaffold(body: SettingsPage()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '字重');
        await tester.pumpAndSettle();
        final bold = find.text('粗体 · 700');
        await tester.ensureVisible(bold);
        await tester.tap(bold);
        await tester.pumpAndSettle();
        expect(state.config.fontWeightValue, 700);
        expect(AppConfig.fromJson(state.config.toJson()).fontWeightValue, 700);
        expect(
          Theme.of(tester.element(bold)).textTheme.bodyMedium!.fontWeight,
          FontWeight.w700,
        );
        expect(find.text('粗体 · 700'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
    test(
      'should restore each font weight through the existing config schema',
      () {
        for (var i = 0; i < AppConfig.fontWeightValues.length; i++) {
          final config = AppConfig()..fontWeightIndex = i;
          final restored = AppConfig.fromJson(config.toJson());
          expect(restored.fontWeightIndex, i);
          expect(restored.fontWeightValue, AppConfig.fontWeightValues[i]);
          final theme = AppTheme.dark(fontWeight: restored.fontWeightValue);
          expect(
            theme.textTheme.bodyMedium!.fontWeight!.value,
            restored.fontWeightValue,
          );
          expect(
            theme.primaryTextTheme.bodyMedium!.fontWeight!.value,
            restored.fontWeightValue,
          );
        }
      },
    );

    test('should derive glass tint from active seed and brightness', () {
      final blue = AppTheme.dark(seedColor: 0xff315cc0).colorScheme;
      final green = AppTheme.dark(seedColor: 0xff348460).colorScheme;
      final light = AppTheme.light(seedColor: 0xff348460).colorScheme;
      expect(
        themedGlassBase(blue, .45, false),
        isNot(themedGlassBase(green, .45, false)),
      );
      expect(
        themedGlassBase(green, .45, true),
        isNot(themedGlassBase(green, .45, false)),
      );
      expect(
        themedGlassBase(light, .45, true).computeLuminance(),
        greaterThan(themedGlassBase(green, .45, true).computeLuminance()),
      );
    });

    testWidgets('should retain font weight inside shared card Material', (
      tester,
    ) async {
      final state = AppState();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.dark(fontWeight: 700),
            home: const Scaffold(
              body: AppCard(style: 'gray', child: Text('Typography')),
            ),
          ),
        ),
      );
      final context = tester.element(find.text('Typography'));
      expect(DefaultTextStyle.of(context).style.fontWeight, FontWeight.w700);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    testWidgets(
      'should honor a panel style override independent of pill preference',
      (tester) async {
        final state = AppState();
        state.config.pillStyle = 'gray';
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: MaterialApp(
              theme: AppTheme.dark(),
              home: const Scaffold(
                body: MobileGlassPill(style: 'blur', child: Text('Panel')),
              ),
            ),
          ),
        );
        expect(find.byType(BackdropFilter), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  });
}
