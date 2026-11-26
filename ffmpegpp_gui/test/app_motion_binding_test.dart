import 'package:ffmpegpp_gui/theme/app_motion.dart';
import 'package:ffmpegpp_gui/theme/app_motion_binding.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MotionTestBinding extends AutomatedTestWidgetsFlutterBinding
    with AppMotionBinding {}

void main() {
  final binding = _MotionTestBinding();

  tearDown(() {
    binding.appAnimationsDisabled = false;
    binding.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });

  testWidgets('native animation policy combines app and system preferences', (
    tester,
  ) async {
    final disabled = ValueNotifier(true);
    addTearDown(disabled.dispose);
    await tester.pumpWidget(_host(disabled, const SizedBox()));
    expect(binding.disableAnimations, isTrue);
    disabled.value = false;
    await tester.pump();
    expect(binding.disableAnimations, isFalse);

    binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pump();
    expect(binding.disableAnimations, isTrue);
    expect(
      MediaQuery.disableAnimationsOf(
        tester.element(find.byType(SizedBox).last),
      ),
      isTrue,
    );
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    await tester.pump();
    expect(binding.disableAnimations, isFalse);
  });

  for (final disabled in [true, false]) {
    testWidgets('native controls follow reduced motion: $disabled', (
      tester,
    ) async {
      final motion = ValueNotifier(disabled);
      final checked = ValueNotifier(false);
      addTearDown(motion.dispose);
      addTearDown(checked.dispose);
      await tester.pumpWidget(
        _host(
          motion,
          ValueListenableBuilder<bool>(
            valueListenable: checked,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: value,
                  onChanged: (value) => checked.value = value,
                ),
                Checkbox(
                  value: value,
                  onChanged: (value) => checked.value = value!,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final originalSwitch = tester.element(find.byType(Switch));
      checked.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      expect(tester.element(find.byType(Switch)), same(originalSwitch));
      expect(
        tester.binding.transientCallbackCount,
        disabled ? 0 : greaterThan(0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('tooltip follows reduced motion: $disabled', (tester) async {
      final motion = ValueNotifier(disabled);
      addTearDown(motion.dispose);
      await tester.pumpWidget(
        _host(motion, const Tooltip(message: 'Hint', child: Text('Target'))),
      );
      tester.state<TooltipState>(find.byType(Tooltip)).ensureTooltipVisible();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('Hint'), findsOneWidget);
      final fades = tester.widgetList<FadeTransition>(
        find.ancestor(
          of: find.text('Hint'),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fades, isNotEmpty);
      expect(
        fades.map((fade) => fade.opacity.value),
        disabled ? everyElement(1.0) : contains(lessThan(1.0)),
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _host(ValueNotifier<bool> disabled, Widget child) => MaterialApp(
  builder: (context, app) => ValueListenableBuilder<bool>(
    valueListenable: disabled,
    builder: (context, value, _) => AppMotion(disabled: value, child: app!),
  ),
  home: Scaffold(body: Center(child: child)),
);
