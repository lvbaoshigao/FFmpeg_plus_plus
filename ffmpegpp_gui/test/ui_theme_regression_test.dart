import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_card.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
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
