import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

CustomPainter? cometOf(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<CustomPainter>()
    .where((p) => p.runtimeType.toString() == '_CometFillPainter')
    .firstOrNull;

Future<List<int>> raster(CustomPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(300, 44));
  final picture = recorder.endRecording();
  final image = await picture.toImage(300, 44);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = bytes!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return result;
}

int alphaAt(List<int> data, int x) => data[(22 * 300 + x) * 4 + 3];
int alphaSum(List<int> data) => data.indexed
    .where((entry) => entry.$1 % 4 == 3)
    .fold(0, (total, entry) => total + entry.$2);

Future<void> mount(
  WidgetTester tester,
  AppState state,
  Widget child, {
  bool reduced = false,
  TextDirection direction = TextDirection.ltr,
}) => tester.pumpWidget(
  ChangeNotifierProvider.value(
    value: state,
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Center(child: SizedBox(width: 300, child: child)),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final range in [false, true]) {
    Widget slider() => range
        ? AppRangeSlider(values: const RangeValues(0.2, 0.7), onChanged: (_) {})
        : AppSlider(value: 0.4, onChanged: (_) {});
    final kind = range ? 'range' : 'single';

    testWidgets('$kind comet visibly fades after release then stops frames', (
      tester,
    ) async {
      final state = AppState()..config.sliderParticles = true;
      addTearDown(state.dispose);
      await mount(tester, state, slider());
      final rect = tester.getRect(find.byType(range ? RangeSlider : Slider));
      final gesture = await tester.startGesture(
        Offset(rect.left + 120, rect.center.dy),
      );
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 32));
      await gesture.up();
      await tester.pump();
      final released = cometOf(tester);
      expect(
        released,
        isNotNull,
        reason: 'Release must not abruptly remove the comet',
      );
      final initial = await tester.runAsync(() => raster(released!));
      await tester.pump(const Duration(milliseconds: 90));
      final fading = cometOf(tester);
      expect(
        fading,
        isNotNull,
        reason: 'A visible intermediate fade frame is required',
      );
      final middle = await tester.runAsync(() => raster(fading!));
      expect(alphaSum(middle!), inExclusiveRange(0, alphaSum(initial!)));
      await tester.pumpAndSettle();
      expect(
        cometOf(tester),
        isNull,
        reason: 'Idle sliders have no permanent highlight',
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$kind moving specks animate and speed decays while held still', (
      tester,
    ) async {
      final state = AppState()..config.sliderParticles = true;
      addTearDown(state.dispose);
      await mount(tester, state, slider());
      final rect = tester.getRect(find.byType(range ? RangeSlider : Slider));
      final gesture = await tester.startGesture(
        Offset(rect.left + 120, rect.center.dy),
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 20));
      final dynamic moving = cometOf(tester)!;
      expect(moving.speed, greaterThan(0.5));
      final before = await tester.runAsync(
        () => raster(moving as CustomPainter),
      );
      await tester.pump(const Duration(milliseconds: 40));
      final after = await tester.runAsync(() => raster(cometOf(tester)!));
      expect(
        after,
        isNot(equals(before)),
        reason: 'The held comet must have visible phase motion',
      );
      await tester.pump(const Duration(seconds: 1));
      final dynamic stopped = cometOf(tester)!;
      expect(
        stopped.speed,
        lessThan(0.01),
        reason:
            'Speed decay must use actual elapsed time, including a delayed frame',
      );
      await gesture.up();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$kind moving specks animate and speed decays while held still', (
      tester,
    ) async {
      final state = AppState()..config.sliderParticles = true;
      addTearDown(state.dispose);
      await mount(tester, state, slider());
      final rect = tester.getRect(find.byType(range ? RangeSlider : Slider));
      final gesture = await tester.startGesture(
        Offset(rect.left + 120, rect.center.dy),
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 20));
      final dynamic moving = cometOf(tester)!;
      expect(moving.speed, greaterThan(0.5));
      final before = await tester.runAsync(
        () => raster(moving as CustomPainter),
      );
      await tester.pump(const Duration(milliseconds: 40));
      final after = await tester.runAsync(() => raster(cometOf(tester)!));
      expect(
        after,
        isNot(equals(before)),
        reason: 'The held comet must have visible phase motion',
      );
      await tester.pump(const Duration(seconds: 1));
      final dynamic stopped = cometOf(tester)!;
      expect(
        stopped.speed,
        lessThan(0.01),
        reason:
            'Speed decay must use actual elapsed time, including a delayed frame',
      );
      await gesture.up();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$kind reduced motion toggle stops active comet frames', (
      tester,
    ) async {
      final state = AppState()..config.sliderParticles = true;
      addTearDown(state.dispose);
      final child = slider();
      await mount(tester, state, child);
      final rect = tester.getRect(find.byType(range ? RangeSlider : Slider));
      final gesture = await tester.startGesture(
        Offset(rect.left + 120, rect.center.dy),
      );
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 32));
      expect(cometOf(tester), isNotNull);
      await mount(tester, state, child, reduced: true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(cometOf(tester), isNull);
      expect(tester.binding.transientCallbackCount, 0);
      await mount(tester, state, child);
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump(const Duration(milliseconds: 32));
      expect(cometOf(tester), isNotNull);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'reduced motion snaps external single-slider values without tweening',
    (tester) async {
      final state = AppState()..config.sliderParticles = true;
      addTearDown(state.dispose);
      await mount(
        tester,
        state,
        AppSlider(value: 0.2, onChanged: (_) {}),
        reduced: true,
      );
      await mount(
        tester,
        state,
        AppSlider(value: 0.8, onChanged: (_) {}),
        reduced: true,
      );
      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.8);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final direction in TextDirection.values) {
    testWidgets(
      'single drag should keep the comet inside the fill in $direction',
      (tester) async {
        final state = AppState()..config.sliderParticles = true;
        addTearDown(state.dispose);
        await mount(
          tester,
          state,
          AppSlider(value: 0.4, onChanged: (_) {}),
          direction: direction,
        );
        final slider = find.byType(Slider);
        final rtl = direction == TextDirection.rtl;
        final towardFill = rtl ? 30 : -30;

        Future<double> checkCometAtThumb() async {
          final value = tester.widget<Slider>(slider).value;
          final head = (2 + 296 * (rtl ? 1 - value : value)).round();
          final painter = cometOf(tester);
          expect(painter, isNotNull);
          final pixels = (await tester.runAsync(() => raster(painter!)))!;
          expect(
            alphaAt(pixels, head),
            greaterThan(40),
            reason: 'The glow should follow the thumb during the drag',
          );
          expect(
            alphaAt(pixels, head + towardFill),
            greaterThan(alphaAt(pixels, head - towardFill)),
            reason: 'The comet trail should extend into the filled track',
          );
          return value;
        }

        final gesture = await tester.startGesture(tester.getCenter(slider));
        await gesture.moveBy(const Offset(60, 0));
        await tester.pump(const Duration(milliseconds: 20));
        final rightwardValue = await checkCometAtThumb();

        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump(const Duration(milliseconds: 20));
        final leftwardValue = await checkCometAtThumb();
        expect(
          leftwardValue,
          rtl ? greaterThan(rightwardValue) : lessThan(rightwardValue),
        );
        await gesture.up();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('range start handle owns the moving comet head', (tester) async {
    final state = AppState()..config.sliderParticles = true;
    addTearDown(state.dispose);
    await mount(
      tester,
      state,
      AppRangeSlider(values: const RangeValues(0.3, 0.8), onChanged: (_) {}),
    );
    final rect = tester.getRect(find.byType(RangeSlider));
    final gesture = await tester.startGesture(
      Offset(rect.left + 2 + 296 * 0.3, rect.center.dy),
    );
    await gesture.moveBy(const Offset(-35, 0));
    await tester.pump(const Duration(milliseconds: 20));
    final values = tester.widget<RangeSlider>(find.byType(RangeSlider)).values;
    expect(values.start, lessThan(0.3));
    final data = await tester.runAsync(() => raster(cometOf(tester)!));
    final head = (2 + 296 * values.start).round();
    expect(
      alphaAt(data!, head),
      greaterThan(40),
      reason: 'Glow must follow the start handle, not remain at the end handle',
    );
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
  });
}
