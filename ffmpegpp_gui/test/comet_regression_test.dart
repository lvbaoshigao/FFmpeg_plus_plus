import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<List<int>> pixels(CustomPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = bytes!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return result;
}

CustomPainter painterOf(WidgetTester tester, String type) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<CustomPainter>()
    .firstWhere((p) => p.runtimeType.toString() == type);

void main() {
  testWidgets('indeterminate progress remains visible without decoration', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    for (final (reduceMotion, particles) in [
      (false, false),
      (true, false),
      (true, true),
    ]) {
      state.config.sliderParticles = particles;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: const Scaffold(
                body: SizedBox(width: 240, child: AppProgressBar()),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 900));
      final painter = painterOf(tester, '_IndeterminateBarPainter');
      final data = await tester.runAsync(
        () => pixels(painter, const Size(240, 12)),
      );
      expect(
        data!
            .asMap()
            .entries
            .where((e) => e.key % 4 == 3)
            .any((e) => e.value > 0),
        isTrue,
        reason:
            'The loading segment must remain visible when comet decoration is off',
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('repeated reduced motion changes safely resume progress', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    for (final reduceMotion in [false, true, false, true, false]) {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: const Scaffold(
                body: SizedBox(width: 240, child: AppProgressBar()),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(
        tester.binding.transientCallbackCount,
        reduceMotion ? 0 : greaterThan(0),
        reason: reduceMotion
            ? 'Reduced motion must stop scheduling frames'
            : 'Progress must resume scheduling animation frames',
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('range slider comet pixels mirror in RTL', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final images = <List<int>>[];
    for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            home: Directionality(
              textDirection: direction,
              child: Scaffold(
                body: SizedBox(
                  width: 240,
                  child: AppRangeSlider(
                    values: const RangeValues(0.1, 0.6),
                    onChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      slider.onChangeStart!(slider.values);
      slider.onChanged!(const RangeValues(0.1, 0.7));
      await tester.pump();
      final painter = painterOf(tester, '_CometFillPainter');
      images.add(
        (await tester.runAsync(() => pixels(painter, const Size(240, 24))))!,
      );
      // Reset animation phase and drag state before comparing the other axis.
      await tester.pumpWidget(const SizedBox());
    }
    var difference = 0;
    for (var y = 0; y < 24; y++) {
      for (var x = 0; x < 240; x++) {
        final a = (y * 240 + x) * 4 + 3;
        final b = (y * 240 + 239 - x) * 4 + 3;
        difference += (images[0][a] - images[1][b]).abs();
      }
    }
    expect(
      difference / (240 * 24),
      lessThan(2),
      reason: 'The comet head must follow the mirrored fill leading edge',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
