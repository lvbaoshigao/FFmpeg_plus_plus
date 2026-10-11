import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  test('disabled accents are achromatic with dynamic colors in both modes', () {
    for (final theme in [
      AppTheme.light(useThemeColor: false, dynamicSeed: 0xFFFF0088),
      AppTheme.dark(useThemeColor: false, dynamicSeed: 0xFF0088FF),
    ]) {
      final s = theme.colorScheme;
      for (final color in [
        s.primary,
        s.primaryContainer,
        s.secondary,
        s.secondaryContainer,
        s.tertiary,
        s.tertiaryContainer,
        s.surface,
        s.surfaceContainerHighest,
        s.outline,
      ]) {
        expect(color.r, closeTo(color.g, 1 / 255));
        expect(color.g, closeTo(color.b, 1 / 255));
      }
    }
    final config = AppConfig()..useThemeColor = false;
    expect(AppConfig.fromJson(config.toJson()).useThemeColor, isFalse);
    expect(AppConfig.fromJson({}).useThemeColor, isTrue);
  });

  testWidgets('liquid pill follows drag, springs home and preserves taps', (
    tester,
  ) async {
    final state = AppState();
    state.config.pillStyle = 'liquid';
    var taps = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Center(
              child: MobileGlassPill(
                pressable: true,
                onTap: () => taps++,
                height: 48,
                child: const Text('Project'),
              ),
            ),
          ),
        ),
      ),
    );
    final pill = find.byType(MobileGlassPill);
    final size = tester.getSize(pill);
    final gesture = await tester.startGesture(tester.getCenter(pill));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    await gesture.moveBy(const Offset(60, 15));
    await tester.pump();
    final transform = tester.widget<Transform>(
      find.descendant(of: pill, matching: find.byType(Transform)).first,
    );
    expect(transform.transform.entry(0, 3), greaterThan(0));
    expect(tester.getSize(pill), size);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
    final settled = tester
        .widget<Transform>(
          find.descendant(of: pill, matching: find.byType(Transform)).first,
        )
        .transform;
    expect(settled.entry(0, 3), closeTo(0, 0.01));
    expect(settled.entry(0, 0), closeTo(1, 0.001));
    await tester.tap(pill);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
