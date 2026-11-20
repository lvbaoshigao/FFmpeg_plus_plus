import 'dart:async';
import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/image_memory_budget.dart';
import 'package:ffmpegpp_gui/widgets/wallpaper_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<ui.Image> createImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(8, 8);
  } finally {
    picture.dispose();
  }
}

void main() {
  setUp(() {
    WallpaperBlurCache.release();
    WallpaperBlurCache.rasterizeForTesting = null;
  });
  tearDown(() {
    WallpaperBlurCache.release();
    WallpaperBlurCache.rasterizeForTesting = null;
  });
  group('Wallpaper image lifecycle', () {
    testWidgets(
      'should reuse blur across cloned source handles and release them',
      (tester) async {
        final source = await tester.runAsync(createImage);
        final clone = source!.clone();
        await tester.runAsync(() async {
          WallpaperBlurCache.request(
            src: source,
            screen: const Size(8, 8),
            dpr: 1,
            sigma: 0,
          );
          // Let the real engine complete toImage rather than mocking allocation.
          for (
            var i = 0;
            i < 100 && WallpaperBlurCache.image.value == null;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        final blurred = WallpaperBlurCache.image.value;
        expect(blurred, isNotNull);
        expect(
          WallpaperBlurCache.currentFor(clone, const Size(8, 8)),
          same(blurred),
        );
        WallpaperBlurCache.request(
          src: clone,
          screen: const Size(8, 8),
          dpr: 1,
          sigma: 5,
        );
        // Debounced rebuild must own a handle even if its caller releases one.
        source.dispose();
        await tester.pump(const Duration(milliseconds: 120));
        await tester.runAsync(() async {
          for (
            var i = 0;
            i < 100 && identical(WallpaperBlurCache.image.value, blurred);
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        final rebuilt = WallpaperBlurCache.image.value;
        expect(rebuilt, isNotNull);
        expect(rebuilt, isNot(same(blurred)));
        expect(
          WallpaperBlurCache.currentFor(clone, const Size(8, 8)),
          same(rebuilt),
        );
        WallpaperBlurCache.release();
        await tester.pump();
        expect(clone.debugGetOpenHandleStackTraces(), hasLength(1));
        clone.dispose();
      },
    );

    testWidgets(
      'should serialize allocations and coalesce startup resize requests',
      (tester) async {
        final source = (await tester.runAsync(createImage))!;
        addTearDown(source.dispose);
        final allocations = <Completer<ui.Image>>[];
        var active = 0;
        var peakActive = 0;
        WallpaperBlurCache.rasterizeForTesting = (picture, width, height) {
          final allocation = Completer<ui.Image>();
          allocations.add(allocation);
          active++;
          if (active > peakActive) peakActive = active;
          return allocation.future.whenComplete(() => active--);
        };
        for (var i = 0; i <= 20; i++) {
          WallpaperBlurCache.request(
            src: source,
            screen: Size(800 + i.toDouble(), 600),
            dpr: 4,
            sigma: 0,
          );
        }
        expect(allocations, hasLength(1));
        expect(
          source.debugGetOpenHandleStackTraces(),
          hasLength(3),
          reason:
              'One caller, one active raster, and only the latest pending request.',
        );
        allocations.first.complete(source.clone());
        await tester.pump();
        expect(allocations, hasLength(2));
        allocations.last.complete(source.clone());
        await tester.pump();
        expect(peakActive, 1);
        expect(
          WallpaperBlurCache.currentFor(source, const Size(820, 600)),
          isNotNull,
        );
        expect(
          WallpaperBlurCache.currentFor(source, const Size(800, 600)),
          isNull,
        );
        WallpaperBlurCache.release();
        await tester.pump();
        expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
      },
    );

    testWidgets(
      'should cancel a queued resize when returning to the current crop',
      (tester) async {
        final source = (await tester.runAsync(createImage))!;
        addTearDown(source.dispose);
        var allocations = 0;
        WallpaperBlurCache.rasterizeForTesting =
            (picture, width, height) async {
              allocations++;
              return source.clone();
            };
        WallpaperBlurCache.request(
          src: source,
          screen: const Size(8, 8),
          dpr: 1,
          sigma: 0,
        );
        await tester.pump();
        final original = WallpaperBlurCache.image.value;
        WallpaperBlurCache.request(
          src: source,
          screen: const Size(16, 8),
          dpr: 1,
          sigma: 0,
        );
        WallpaperBlurCache.request(
          src: source,
          screen: const Size(8, 8),
          dpr: 1,
          sigma: 0,
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(allocations, 1);
        expect(WallpaperBlurCache.image.value, same(original));
        expect(
          WallpaperBlurCache.currentFor(source, const Size(8, 8)),
          same(original),
        );
        WallpaperBlurCache.release();
        await tester.pump();
        expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
      },
    );

    testWidgets(
      'should discard in-flight work and pending handles after release',
      (tester) async {
        final source = (await tester.runAsync(createImage))!;
        addTearDown(source.dispose);
        final allocation = Completer<ui.Image>();
        var calls = 0;
        WallpaperBlurCache.rasterizeForTesting = (picture, width, height) {
          calls++;
          return allocation.future;
        };
        WallpaperBlurCache.request(
          src: source,
          screen: const Size(100, 80),
          dpr: 3,
          sigma: 0,
        );
        WallpaperBlurCache.request(
          src: source,
          screen: const Size(200, 80),
          dpr: 3,
          sigma: 0,
        );
        WallpaperBlurCache.release();
        allocation.complete(source.clone());
        await tester.pump();
        expect(calls, 1);
        expect(WallpaperBlurCache.image.value, isNull);
        expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
      },
    );

    testWidgets('should drop raster handles on system memory pressure', (
      tester,
    ) async {
      final source = (await tester.runAsync(createImage))!;
      addTearDown(source.dispose);
      WallpaperBlurCache.rasterizeForTesting = (picture, width, height) async =>
          source.clone();
      WallpaperBlurCache.request(
        src: source,
        screen: const Size(8, 8),
        dpr: 1,
        sigma: 0,
      );
      await tester.pump();
      expect(WallpaperBlurCache.image.value, isNotNull);
      tester.binding.handleMemoryPressure();
      await tester.pump();
      expect(WallpaperBlurCache.image.value, isNull);
      expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
    });

    testWidgets(
      'should rasterize a bounded 4K blur and reuse only matching crops',
      (tester) async {
        final source = (await tester.runAsync(createImage))!;
        addTearDown(source.dispose);
        await tester.runAsync(() async {
          WallpaperBlurCache.request(
            src: source,
            screen: const Size(3840, 2160),
            dpr: 4,
            sigma: 24,
          );
          for (
            var i = 0;
            i < 100 && WallpaperBlurCache.image.value == null;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        final blur = WallpaperBlurCache.image.value!;
        expect(
          blur.width * blur.height * 4,
          lessThanOrEqualTo(ImageMemoryBudget.maxBlurBytes),
        );
        expect(
          WallpaperBlurCache.currentFor(source, const Size(7680, 4320)),
          same(blur),
        );
        expect(
          WallpaperBlurCache.currentFor(source, const Size(2160, 3840)),
          isNull,
          reason:
              'An old viewport crop must not stretch to a different aspect ratio.',
        );
        WallpaperBlurCache.release();
        await tester.pump();
        expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
      },
    );

    testWidgets('should dispose listener image handles when scope unmounts', (
      tester,
    ) async {
      final source = await tester.runAsync(createImage);
      final provider = _ImageProvider(source!);
      final state = AppState();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            home: WallpaperWindowScope(
              provider: provider,
              screenSize: const Size(8, 8),
              overlayColor: Colors.transparent,
              child: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.pump();
      expect(
        source.debugGetOpenHandleStackTraces(),
        hasLength(1),
        reason: 'Only the test-owned source handle should remain.',
      );
      source.dispose();
      state.dispose();
    });
  });
}

class _ImageProvider extends ImageProvider<_ImageProvider> {
  _ImageProvider(this.source);
  final ui.Image source;

  @override
  Future<_ImageProvider> obtainKey(ImageConfiguration configuration) async =>
      this;

  @override
  ImageStreamCompleter loadImage(
    _ImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: source.clone())),
    );
  }
}
