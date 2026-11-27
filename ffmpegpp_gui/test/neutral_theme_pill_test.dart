import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  test('disabled custom accents keep default accents and neutral surfaces', () {
    for (final (theme, defaults) in [
      (
        AppTheme.light(useThemeColor: false, dynamicSeed: 0xFFFF0088),
        AppTheme.light(),
      ),
      (
        AppTheme.dark(useThemeColor: false, dynamicSeed: 0xFF0088FF),
        AppTheme.dark(),
      ),
    ]) {
      final s = theme.colorScheme;
      expect(s.primary, defaults.colorScheme.primary);
      expect(s.secondary, defaults.colorScheme.secondary);
      expect(s.tertiary, defaults.colorScheme.tertiary);
      for (final color in [s.surface, s.surfaceContainerHighest, s.outline]) {
        expect(color.r, closeTo(color.g, 1 / 255));
        expect(color.g, closeTo(color.b, 1 / 255));
      }
    }
    final config = AppConfig()..useThemeColor = false;
    expect(AppConfig.fromJson(config.toJson()).useThemeColor, isFalse);
    expect(AppConfig.fromJson({}).useThemeColor, isTrue);
  });

  testWidgets(
    'liquid pill lights on press without moving glass or stealing drags',
    (tester) async {
      final state = AppState()..config.pillStyle = 'liquid';
      addTearDown(state.dispose);
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
      final bounds = tester.getRect(pill);
      final paint = find
          .descendant(of: pill, matching: find.byType(CustomPaint))
          .first;
      final element = tester.element(paint);
      final gesture = await tester.startGesture(tester.getCenter(pill));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final pressedPainter = tester
          .widget<CustomPaint>(paint)
          .foregroundPainter;
      expect(pressedPainter, isNotNull);
      expect((pressedPainter as dynamic).amount, 1);
      expect(tester.getRect(pill), bounds);
      // 桌面端：按压只有光效，不缩放（压缩回弹仅移动端）。
      expect(
        find.descendant(of: pill, matching: find.byType(Transform)),
        findsNothing,
      );
      await gesture.moveBy(const Offset(70, 20));
      await tester.pump(const Duration(milliseconds: 180));
      expect(tester.getRect(pill), bounds);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(tester.element(paint), same(element));
      expect(
        (tester.widget<CustomPaint>(paint).foregroundPainter as dynamic).amount,
        0,
      );
      await tester.tap(pill);
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('mobile liquid pill compresses to 0.96 on press', (tester) async {
    debugIsMobilePlatformOverride = true;
    addTearDown(() => debugIsMobilePlatformOverride = null);
    final state = AppState()..config.pillStyle = 'liquid';
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Center(
              child: MobileGlassPill(
                pressable: true,
                onTap: () {},
                height: 48,
                child: const Text('Project'),
              ),
            ),
          ),
        ),
      ),
    );
    final pill = find.byType(MobileGlassPill);
    final bounds = tester.getRect(pill);
    final gesture = await tester.startGesture(tester.getCenter(pill));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final press = tester.widget<Transform>(
      find.byKey(const ValueKey('pill_press_scale')),
    );
    // 只看 X/Y：Transform.scale 的 Z 轴恒为 1。
    expect(press.transform.entry(0, 0), closeTo(0.96, 0.001));
    expect(tester.getRect(pill), bounds);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
