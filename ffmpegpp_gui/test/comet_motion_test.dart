import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _capture = Key('slider track');
const _width = 300.0;
const _fill = Color(0xFF00009C);
const _initialRange = RangeValues(0.2, 0.7);

typedef _Pixels = ({int width, int height, ByteData data});

AppState _state() {
  final state = AppState()
    ..config.settingsGlassMode = 'solid'
    ..config.sliderParticles = true;
  addTearDown(state.dispose);
  return state;
}

Future<void> _mount(
  WidgetTester tester,
  AppState state,
  Widget child, {
  bool reduceMotion = false,
  TextDirection direction = TextDirection.ltr,
}) => tester.pumpWidget(
  ChangeNotifierProvider.value(
    value: state,
    child: MaterialApp(
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          surfaceContainerHighest: Colors.black,
          outlineVariant: Colors.black,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: _capture,
                child: ColoredBox(
                  color: Colors.black,
                  child: SizedBox(width: _width, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<_Pixels> _raster(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (width: image.width, height: image.height, data: data!);
    } finally {
      image.dispose();
    }
  }))!;
}

// The track is black and the fill is blue, so red measures only the comet.
int _red(_Pixels pixels, int x, int y) =>
    pixels.data.getUint8((y * pixels.width + x) * 4);

int _centerRed(_Pixels pixels, int x) => _red(pixels, x, pixels.height ~/ 2);

int _peakRed(_Pixels pixels) {
  var peak = 0;
  for (var x = 0; x < pixels.width; x++) {
    final light = _centerRed(pixels, x);
    if (light > peak) {
      peak = light;
    }
  }
  return peak;
}

double _headX(double value, {bool rtl = false}) =>
    2 + (_width - 4) * (rtl ? 1 - value : value);

void _expectTaper(_Pixels pixels, double head, int towardFill) {
  int xAt(int distance) => (head + distance * towardFill).floor();
  int litHeightAt(int distance) => [
    for (var y = 0; y < pixels.height; y++) _red(pixels, xAt(distance), y),
  ].where((light) => light > 4).length;

  final headLight = _centerRed(pixels, xAt(3));
  expect(headLight, greaterThan(40), reason: 'The head follows the thumb');
  expect(_centerRed(pixels, xAt(24)), inExclusiveRange(0, headLight));
  expect(litHeightAt(9), greaterThan(litHeightAt(24)));
  expect(_centerRed(pixels, xAt(-6)), 0, reason: 'Clip at the fill edge');
  expect(_centerRed(pixels, xAt(60)), 0, reason: 'Keep the tail short');
}

Future<TestGesture> _dragEndHandle(
  WidgetTester tester, {
  required bool range,
}) async {
  final rect = tester.getRect(find.byType(range ? RangeSlider : Slider));
  final x = _headX(range ? _initialRange.end : 0.4);
  final gesture = await tester.startGesture(
    Offset(rect.left + x, rect.center.dy),
  );
  await gesture.moveBy(const Offset(40, 0));
  await tester.pump();
  return gesture;
}

void main() {
  group('AppSlider and AppRangeSlider motion', () {
    for (final range in [false, true]) {
      final kind = range ? 'range' : 'single';
      Widget slider() => range
          ? AppRangeSlider(
              values: _initialRange,
              color: _fill,
              onChanged: (_) {},
            )
          : AppSlider(value: 0.4, color: _fill, onChanged: (_) {});

      testWidgets(
        'should settle and fade the $kind comet without idle frames',
        (tester) async {
          await _mount(tester, _state(), slider());
          final gesture = await _dragEndHandle(tester, range: range);
          final value = range
              ? tester.widget<RangeSlider>(find.byType(RangeSlider)).values.end
              : tester.widget<Slider>(find.byType(Slider)).value;
          final farTail = (_headX(value) - 44).floor();
          final moving = await _raster(tester);
          expect(_centerRed(moving, farTail), greaterThan(0));

          await tester.pump(const Duration(seconds: 1));
          final resting = await _raster(tester);
          expect(_centerRed(resting, farTail), 0);
          expect(_peakRed(resting), greaterThan(40));
          expect(tester.binding.transientCallbackCount, 0);

          await gesture.up();
          await tester.pump();
          final released = _peakRed(await _raster(tester));
          expect(released, greaterThan(40));
          await tester.pump(const Duration(milliseconds: 80));
          final fading = _peakRed(await _raster(tester));
          expect(fading, inExclusiveRange(0, released));
          await tester.pumpAndSettle();
          expect(_peakRed(await _raster(tester)), 0);
          expect(tester.binding.transientCallbackCount, 0);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );

      testWidgets(
        'should stop and resume the $kind comet with reduced motion',
        (tester) async {
          final state = _state();
          final child = slider();
          await _mount(tester, state, child);
          final gesture = await _dragEndHandle(tester, range: range);
          expect(_peakRed(await _raster(tester)), greaterThan(40));

          await _mount(tester, state, child, reduceMotion: true);
          await tester.pump(const Duration(milliseconds: 300));
          expect(_peakRed(await _raster(tester)), 0);
          expect(tester.binding.transientCallbackCount, 0);

          await _mount(tester, state, child);
          await gesture.moveBy(const Offset(-30, 0));
          await tester.pump();
          expect(_peakRed(await _raster(tester)), greaterThan(40));
          expect(tester.binding.transientCallbackCount, greaterThan(0));
          await gesture.up();
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  });

  group('AppSlider comet geometry', () {
    for (final direction in TextDirection.values) {
      testWidgets('should stay inside the fill when reversing in $direction', (
        tester,
      ) async {
        await _mount(
          tester,
          _state(),
          AppSlider(value: 0.4, color: _fill, onChanged: (_) {}),
          direction: direction,
        );
        final slider = find.byType(Slider);
        final rtl = direction == TextDirection.rtl;
        var lastValue = 0.0;
        final gesture = await tester.startGesture(tester.getCenter(slider));
        for (final dx in [60.0, -40.0]) {
          await gesture.moveBy(Offset(dx, 0));
          await tester.pump(const Duration(milliseconds: 20));
          final value = tester.widget<Slider>(slider).value;
          _expectTaper(
            await _raster(tester),
            _headX(value, rtl: rtl),
            rtl ? 1 : -1,
          );
          if (dx < 0) {
            expect(value, rtl ? greaterThan(lastValue) : lessThan(lastValue));
          }
          lastValue = value;
        }
        await gesture.up();
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('should follow the painted thumb during discrete snapping', (
      tester,
    ) async {
      await _mount(
        tester,
        _state(),
        AppSlider(value: 0.25, divisions: 4, color: _fill, onChanged: (_) {}),
      );
      final slider = find.byType(Slider);
      final rect = tester.getRect(slider);
      final gesture = await tester.startGesture(
        Offset(rect.left + _headX(0.25), rect.center.dy),
      );
      await gesture.moveBy(const Offset(75, 0));
      await tester.pump();
      expect(tester.widget<Slider>(slider).value, 0.5);

      final pixels = await _raster(tester);
      final row = pixels.height ~/ 2;
      // Locate the blue fill edge independently of the white highlight.
      final paintedEdge = Iterable<int>.generate(pixels.width).lastWhere((x) {
        final blue = pixels.data.getUint8((row * pixels.width + x) * 4 + 2);
        return blue - _red(pixels, x, row) > 20;
      });
      expect(paintedEdge, lessThan(_headX(0.5) - 10));
      expect(_red(pixels, paintedEdge - 3, row), greaterThan(40));
      expect(_red(pixels, paintedEdge + 6, row), 0);
      await gesture.up();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('should snap external slider values with reduced motion', (
      tester,
    ) async {
      final state = _state();
      for (final value in [0.2, 0.8]) {
        await _mount(
          tester,
          state,
          AppSlider(value: value, onChanged: (_) {}),
          reduceMotion: true,
        );
      }
      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.8);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('AppRangeSlider comet geometry', () {
    for (final direction in TextDirection.values) {
      for (final handle in Thumb.values) {
        testWidgets('should follow the $handle handle in $direction', (
          tester,
        ) async {
          await _mount(
            tester,
            _state(),
            AppRangeSlider(
              values: _initialRange,
              color: _fill,
              onChanged: (_) {},
            ),
            direction: direction,
          );
          final range = find.byType(RangeSlider);
          final rect = tester.getRect(range);
          final rtl = direction == TextDirection.rtl;
          final start = handle == Thumb.start;
          final towardFill = start != rtl ? 1 : -1;
          final initial = start ? _initialRange.start : _initialRange.end;
          final gesture = await tester.startGesture(
            Offset(rect.left + _headX(initial, rtl: rtl), rect.center.dy),
          );
          await gesture.moveBy(Offset(-36.0 * towardFill, 0));
          await tester.pump(const Duration(milliseconds: 20));
          final values = tester.widget<RangeSlider>(range).values;
          final value = start ? values.start : values.end;
          expect(value, start ? lessThan(initial) : greaterThan(initial));
          _expectTaper(
            await _raster(tester),
            _headX(value, rtl: rtl),
            towardFill,
          );
          await gesture.up();
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  });
}
