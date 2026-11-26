import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/services/image_memory_budget.dart';
import 'package:ffmpegpp_gui/services/wallpaper_image_optimizer.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xFF0000FF), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width, height);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _fixture(String filename) =>
    File('test/services/fixtures/$filename').readAsBytes();

Future<(int, int)> _dimensions(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (descriptor.width, descriptor.height);
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

void main() {
  group('WallpaperImageOptimizer', () {
    test(
      'should bound target dimensions by viewport and 2MP raster budget',
      () {
        final target = WallpaperImageOptimizer.targetSize(
          12000,
          8000,
          maxWidth: 7680,
          maxHeight: 4320,
        )!;
        expect(target.width, lessThanOrEqualTo(7680));
        expect(target.height, lessThanOrEqualTo(4320));
        expect(
          target.width * target.height,
          lessThanOrEqualTo(ImageMemoryBudget.maxWallpaperPixels),
        );
        expect(target.width / target.height, closeTo(1.5, 0.002));
      },
    );

    test(
      'should decode oversized images directly to the bounded target',
      () async {
        final source = await _png(400, 200);
        final result = await WallpaperImageOptimizer.optimize(
          source,
          maxWidth: 100,
          maxHeight: 100,
        );

        expect(result, isNotNull);
        expect(identical(result, source), isFalse);
        expect(await _dimensions(result!), (100, 50));
      },
    );

    test('should preserve bytes for images already within budget', () async {
      final source = await _png(32, 20);
      final result = await WallpaperImageOptimizer.optimize(
        source,
        maxWidth: 100,
        maxHeight: 100,
      );

      expect(identical(result, source), isTrue);
    });

    test('should reject invalid dimensions before allocating a codec', () {
      expect(
        WallpaperImageOptimizer.targetSize(
          0,
          100,
          maxWidth: 100,
          maxHeight: 100,
        ),
        isNull,
      );
      expect(
        WallpaperImageOptimizer.targetSize(
          100,
          100,
          maxWidth: 0,
          maxHeight: 100,
        ),
        isNull,
      );
    });
    test('should resize safe APNG frames to the bounded output', () async {
      final source = await _fixture('animated_400x200.png');
      final result = await WallpaperImageOptimizer.optimize(
        source,
        maxWidth: 100,
        maxHeight: 100,
      );

      expect(result, isNotNull);
      expect(await _dimensions(result!), (100, 50));
    });

    test(
      'should reject animated images requiring an over-budget full decode',
      () async {
        await expectLater(
          WallpaperImageOptimizer.optimize(
            await _fixture('animated_over_budget.png'),
            maxWidth: 100,
            maxHeight: 100,
          ),
          throwsA(isA<WallpaperImageTooLargeToResizeException>()),
        );
      },
    );

    test('content-addressed names separate colliding Unicode filenames', () {
      final firstBytes = Uint8List.fromList([1, 2, 3]);
      final secondBytes = Uint8List.fromList([4, 5, 6]);
      final first = WallpaperImageOptimizer.contentAddressedFileName(
        '夏天_opt.png',
        firstBytes,
      );
      final sameContent = WallpaperImageOptimizer.contentAddressedFileName(
        '冬天_opt.png',
        firstBytes,
      );
      final second = WallpaperImageOptimizer.contentAddressedFileName(
        '冬天_opt.png',
        secondBytes,
      );

      expect(sameContent, first);
      expect(second, isNot(first));
      expect(first, matches(RegExp(r'^___opt_[0-9a-f]{64}\.png$')));
    });
  });
}
