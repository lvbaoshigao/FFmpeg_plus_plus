import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/widgets/polygon_morph_loader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Captured from PolyMorph.sample(t) in both reference SVG scripts. The scripts
// produce identical vertices, including the loop correction in the last 2 steps.
const _svgSamples = <int, List<Offset>>{
  225: [
    Offset(271.770734713, 99.030179154),
    Offset(199.309952565, 209.623117615),
    Offset(-297.457845576, 108.182945708),
    Offset(-19.589112862, -315.912941004),
  ],
  1234: [
    Offset(-276.915513656, -26.559131947),
    Offset(-230.398191196, -155.898244656),
    Offset(136.011994682, -252.600461863),
    Offset(276.378924594, 99.400771253),
    Offset(-56.031115510, 281.365900786),
  ],
  4500: [
    Offset(-228.087995459, 144.509836020),
    Offset(-263.466453295, -59.098683298),
    Offset(-144.509836020, -228.087995459),
    Offset(59.098683298, -263.466453295),
    Offset(228.087995459, -144.509836020),
    Offset(263.466453295, 59.098683298),
    Offset(144.509836020, 228.087995459),
    Offset(-59.098683298, 263.466453295),
  ],
  7650: [
    Offset(-74.541528057, -266.138383415),
    Offset(100.990745578, -257.268241023),
    Offset(277.850147717, 67.018651139),
    Offset(-14.777328719, 292.430267050),
    Offset(-283.190776322, 38.667665986),
  ],
  8550: [
    Offset(90.670247923, -265.358136075),
    Offset(258.250863203, -109.281864436),
    Offset(35.627466451, 310.042198608),
    Offset(-311.789300663, -13.524543437),
  ],
};

Widget _host({
  Widget loader = const PolygonMorphLoader(size: 160),
  Color primary = const Color(0xffb3261e),
  bool reduceMotion = false,
  bool tickers = true,
}) => MaterialApp(
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
    ).copyWith(primary: primary),
  ),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: TickerMode(
      enabled: tickers,
      child: Center(child: loader),
    ),
  ),
);

CustomPainter _painter(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(
        of: find.byType(PolygonMorphLoader),
        matching: find.byType(CustomPaint),
      ),
    )
    .painter!;

Future<Uint8List> _rasterize(
  WidgetTester tester, {
  void Function(Canvas)? reference,
}) async {
  final painter = _painter(tester);
  final pixels = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (reference == null) {
      painter.paint(canvas, const Size(160, 160));
    } else {
      reference(canvas);
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(160, 160);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  });
  return pixels!;
}

// Independent SVG rendering: fill + 104-unit round stroke, then a clear mask.
void _paintSvg(Canvas canvas, List<Offset> vertices, {required bool hollow}) {
  canvas.translate(80, 80);
  canvas.scale(0.2);
  if (hollow) {
    canvas.saveLayer(const Rect.fromLTWH(-400, -400, 800, 800), Paint());
  }
  void shape(double scale, BlendMode blend) {
    final path = Path()
      ..addPolygon(vertices.map((p) => p * scale).toList(), true);
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xffb3261e)
        ..blendMode = blend,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xffb3261e)
        ..blendMode = blend
        ..style = PaintingStyle.stroke
        ..strokeWidth = 104
        ..strokeJoin = StrokeJoin.round,
    );
  }

  shape(1, BlendMode.srcOver);
  if (hollow) {
    shape(0.72, BlendMode.clear);
    canvas.restore();
  }
}

List<int> _pixel(Uint8List pixels, int x, int y) =>
    pixels.sublist((y * 160 + x) * 4, (y * 160 + x + 1) * 4);

double _vertexDistance(List<Offset> a, List<Offset> b) => a
    .map((p) => b.map((q) => (p - q).distance).reduce(math.min))
    .reduce(math.max);

void main() {
  test('native samples match the hollow and solid SVG geometry and timing', () {
    expect(PolygonMorphLoader.cycleDuration, const Duration(seconds: 9));
    for (final sample in _svgSamples.entries) {
      final actual = polygonMorphVerticesAt(Duration(milliseconds: sample.key));
      expect(actual.length, sample.value.length);
      for (var i = 0; i < actual.length; i++) {
        expect(
          (actual[i] - sample.value[i]).distance,
          lessThan(1e-6),
          reason: 'SVG sample at t=${sample.key}, vertex $i',
        );
      }
    }
  });

  test('every phase keeps perimeter, center, bounds and room for the icon', () {
    for (var ms = 0; ms < 9000; ms += 37) {
      final points = polygonMorphVerticesAt(Duration(milliseconds: ms));
      var perimeter = 0.0;
      var crossSum = 0.0;
      var centroidSum = Offset.zero;
      for (var i = 0; i < points.length; i++) {
        final p = points[i];
        final q = points[(i + 1) % points.length];
        final edge = q - p;
        final cross = p.dx * q.dy - q.dx * p.dy;
        perimeter += edge.distance;
        crossSum += cross;
        centroidSum += (p + q) * cross;
        expect(p.distance + 52, lessThan(400));
        if (edge.distance > 1e-6) {
          final holeInradius = cross.abs() / edge.distance * 0.72 + 52;
          expect(
            holeInradius,
            greaterThan(112 * math.sqrt2),
            reason: 'The stationary icon must fit the rotating hole at $ms ms',
          );
        }
      }
      expect(perimeter, closeTo(1980 - 2 * math.pi * 52, 1e-8));
      expect((centroidSum / (3 * crossSum)).distance, lessThan(1e-8));
    }
  });

  test('all ten transitions and the loop seam are continuous', () {
    for (var boundary = 900000; boundary <= 9000000; boundary += 900000) {
      final before = polygonMorphVerticesAt(
        Duration(microseconds: boundary - 1),
      );
      final after = polygonMorphVerticesAt(Duration(microseconds: boundary));
      // The reference moves at most 0.001673 SVG units during this 1 µs.
      expect(_vertexDistance(before, after), lessThan(0.002));
      expect(_vertexDistance(after, before), lessThan(0.002));
    }
    expect(
      polygonMorphVerticesAt(const Duration(milliseconds: -1)),
      polygonMorphVerticesAt(const Duration(milliseconds: 8999)),
    );
  });

  testWidgets('native rounded outlines match SVG fill and round stroke masks', (
    tester,
  ) async {
    for (final hollow in [false, true]) {
      await tester.pumpWidget(
        _host(
          loader: hollow
              ? const PolygonMorphLoader.hollow()
              : const PolygonMorphLoader(size: 160),
        ),
      );
      var previousMs = 0;
      for (final sample in _svgSamples.entries) {
        await tester.pump(Duration(milliseconds: sample.key - previousMs));
        previousMs = sample.key;
        final actual = await _rasterize(tester);
        final reference = await _rasterize(
          tester,
          reference: (canvas) =>
              _paintSvg(canvas, sample.value, hollow: hollow),
        );
        var alphaDifference = 0;
        for (var i = 3; i < actual.length; i += 4) {
          alphaDifference += (actual[i] - reference[i]).abs();
        }
        // Different AA of an outlined fill and combined arcs only affects edges.
        expect(
          alphaDifference / (255 * 160 * 160),
          lessThan(0.005),
          reason: 'SVG mask parity at t=${sample.key}, hollow=$hollow',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('solid paints the theme color with a transparent background', (
    tester,
  ) async {
    await tester.pumpWidget(_host(reduceMotion: true));
    await tester.pumpAndSettle();
    var pixels = await _rasterize(tester);
    expect(_pixel(pixels, 0, 0), [0, 0, 0, 0]);
    expect(_pixel(pixels, 80, 80), [179, 38, 30, 255]);
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(
      _host(primary: const Color(0xff146c2e), reduceMotion: true),
    );
    await tester.pumpAndSettle();
    pixels = await _rasterize(tester);
    expect(_pixel(pixels, 80, 80), [20, 108, 46, 255]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hollow keeps the hole transparent and the app icon centered', (
    tester,
  ) async {
    const loader = PolygonMorphLoader.hollow(semanticsLabel: '正在加载');
    await tester.pumpWidget(_host(loader: loader));
    final imageFinder = find.descendant(
      of: find.byType(PolygonMorphLoader),
      matching: find.byType(Image),
    );
    final image = tester.widget<Image>(imageFinder);
    expect(image.image, isA<ResizeImage>());
    expect(
      ((image.image as ResizeImage).imageProvider as AssetImage).assetName,
      'rele/icon.png',
    );
    final iconBounds = tester.getRect(imageFinder);
    expect(
      iconBounds.center,
      tester.getCenter(find.byType(PolygonMorphLoader)),
    );
    expect(iconBounds.size.width, closeTo(160 * 0.28, 0.001));
    var pixels = await _rasterize(tester);
    expect(_pixel(pixels, 80, 80), [0, 0, 0, 0]);
    expect(_pixel(pixels, 145, 80), [179, 38, 30, 255]);
    await tester.pump(const Duration(milliseconds: 450));
    pixels = await _rasterize(tester);
    expect(_pixel(pixels, 80, 80), [0, 0, 0, 0]);
    expect(tester.getRect(imageFinder), iconBounds);
    expect(find.bySemanticsLabel('正在加载'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('animation repaints without rebuilding and disposes its ticker', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    final painter = _painter(tester);
    final initial = await _rasterize(tester);
    await tester.pump(const Duration(milliseconds: 450));
    expect(identical(_painter(tester), painter), isTrue);
    expect(listEquals(await _rasterize(tester), initial), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TickerMode freezes and resumes from the same phase without catching up',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 450));
      final visible = await _rasterize(tester);
      await tester.pumpWidget(_host(tickers: false));
      await tester.pump(const Duration(seconds: 5));
      expect(listEquals(await _rasterize(tester), visible), isTrue);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(_host());
      expect(listEquals(await _rasterize(tester), visible), isTrue);
      await tester.pump(const Duration(milliseconds: 150));
      expect(listEquals(await _rasterize(tester), visible), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'system and explicit reduced motion remain static and react to changes',
    (tester) async {
      await tester.pumpWidget(_host(reduceMotion: true));
      await tester.pumpAndSettle();
      final triangle = await _rasterize(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(listEquals(await _rasterize(tester), triangle), isTrue);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 450));
      expect(listEquals(await _rasterize(tester), triangle), isFalse);
      await tester.pumpWidget(_host(reduceMotion: true));
      await tester.pumpAndSettle();
      expect(listEquals(await _rasterize(tester), triangle), isTrue);
      await tester.pumpWidget(
        _host(loader: const PolygonMorphLoader(size: 160, reduceMotion: true)),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(listEquals(await _rasterize(tester), triangle), isTrue);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
