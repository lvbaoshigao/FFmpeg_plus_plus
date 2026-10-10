import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/providers/app_state.dart';
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
