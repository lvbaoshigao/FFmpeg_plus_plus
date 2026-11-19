import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _capture = Key('progress track');
const _width = 240;
const _fill = Color(0xFF00009C);

typedef _Pixels = ({int width, int height, ByteData data});

AppState _state({bool comet = true}) {
  final state = AppState()..config.sliderParticles = comet;
  addTearDown(state.dispose);
  return state;
}

Future<void> _mount(
  WidgetTester tester,
  AppState state, {
  double? value,
  bool reduceMotion = false,
  TextDirection direction = TextDirection.ltr,
}) => tester.pumpWidget(
  ChangeNotifierProvider.value(
    value: state,
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: _capture,
                child: SizedBox(
                  width: _width.toDouble(),
                  child: AppProgressBar(
                    value: value,
                    color: _fill,
                    backgroundColor: Colors.black,
                    semanticsLabel: 'Transfer',
                  ),
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

int _red(_Pixels pixels, int x) =>
    pixels.data.getUint8((pixels.height ~/ 2 * pixels.width + x) * 4);

int _blue(_Pixels pixels, int x) =>
    pixels.data.getUint8((pixels.height ~/ 2 * pixels.width + x) * 4 + 2);

void _expectUnadorned(_Pixels pixels) {
  expect(
    Iterable<int>.generate(
      pixels.width * pixels.height,
    ).every((pixel) => pixels.data.getUint8(pixel * 4) == 0),
    isTrue,
    reason: 'Only the white highlight contributes any red',
  );
}

void main() {
  group('AppProgressBar comet', () {
    for (final direction in TextDirection.values) {
      final rtl = direction == TextDirection.rtl;

      testWidgets('should draw a short determinate comet in $direction', (
        tester,
      ) async {
        await _mount(tester, _state(), value: 0.62, direction: direction);
        await tester.pumpAndSettle();
        final pixels = await _raster(tester);
        final head = _width * (rtl ? 0.38 : 0.62);
        int xAt(int distance) => (head + (rtl ? distance : -distance)).floor();

        final headLight = _red(pixels, xAt(4));
        expect(headLight, greaterThan(40));
        expect(_red(pixels, xAt(22)), inExclusiveRange(0, headLight));
        expect(_red(pixels, xAt(-5)), 0);
        expect(_red(pixels, xAt(50)), 0);
        expect(_blue(pixels, xAt(50)), greaterThan(0));

        final data = tester
            .getSemantics(find.bySemanticsLabel('Transfer'))
            .getSemanticsData();
        expect(data.label, 'Transfer');
        expect(data.value, '62%');
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets(
        'should move and wrap the indeterminate comet in $direction',
        (tester) async {
          await _mount(tester, _state(), direction: direction);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 900));
          final first = await _raster(tester);
          final beforeHead = rtl ? 125 : 114;
          final pastHead = rtl ? 114 : 125;
          expect(_red(first, beforeHead), greaterThan(40));
          expect(_red(first, pastHead), 0);

          await tester.pump(const Duration(milliseconds: 350));
          final moving = await _raster(tester);
          expect(_red(moving, rtl ? 54 : 185), greaterThan(40));
          expect(_red(moving, beforeHead), 0);

          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(milliseconds: 850));
          final wrapped = await _raster(tester);
          expect(_red(wrapped, beforeHead), greaterThan(40));
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets('should keep reduced-motion RTL loading visible and static', (
      tester,
    ) async {
      await _mount(
        tester,
        _state(),
        reduceMotion: true,
        direction: TextDirection.rtl,
      );
      final initial = await _raster(tester);
      _expectUnadorned(initial);
      expect(_blue(initial, 150), greaterThan(0));
      expect(_blue(initial, 90), 0);
      await tester.pump(const Duration(seconds: 3));
      final later = await _raster(tester);
      expect(
        later.data.buffer.asUint8List(),
        initial.data.buffer.asUint8List(),
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('should stop and resume loading without optional decoration', (
      tester,
    ) async {
      final state = _state(comet: false);
      for (final reduceMotion in [false, true, false, true, false]) {
        await _mount(tester, state, reduceMotion: reduceMotion);
        await tester.pump();
        // A resumed ticker can start anywhere in the cycle, including outside
        // the track. Sample until the undecorated loading segment is visible.
        var visible = false;
        for (var frame = 0; frame < 4; frame++) {
          final pixels = await _raster(tester);
          _expectUnadorned(pixels);
          visible = Iterable<int>.generate(
            pixels.width,
          ).any((x) => _blue(pixels, x) > 0);
          if (visible || reduceMotion) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 450));
        }
        expect(visible, isTrue);
        expect(
          tester.binding.transientCallbackCount,
          reduceMotion ? 0 : greaterThan(0),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
