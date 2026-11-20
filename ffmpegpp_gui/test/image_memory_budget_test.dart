import 'package:ffmpegpp_gui/services/image_memory_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageMemoryBudget', () {
    test('should cap RGBA decoding at 8 MiB regardless of 4K or high DPR', () {
      for (final (width, height) in const [
        (3840.0, 2160.0),
        (2160.0, 3840.0),
        (7680.0, 4320.0),
        (8192.0, 512.0),
      ]) {
        for (final dpr in [1.0, 1.25, 2.0, 3.0, 8.0]) {
          final size = ImageMemoryBudget.wallpaperSize(width, height, dpr);
          final rgbaBytes = size.width * size.height * 4;
          expect(rgbaBytes, lessThanOrEqualTo(8 * 1024 * 1024));
          expect(size.width, inInclusiveRange(1, 8192));
          expect(size.height, inInclusiveRange(1, 8192));
        }
      }
      expect(
        ImageMemoryBudget.wallpaperSize(3840, 2160, 3),
        ImageMemoryBudget.wallpaperSize(3840, 2160, 1),
      );
    });

    test('should share a decode bucket for nearby settled window sizes', () {
      expect(
        ImageMemoryBudget.wallpaperSize(1000, 700, 1),
        ImageMemoryBudget.wallpaperSize(1001, 701, 1),
      );
      expect(ImageMemoryBudget.wallpaperSize(48, 32, 1), (
        width: 48,
        height: 32,
      ));
    });

    test(
      'should budget Gaussian padding and filter expansion independently',
      () {
        for (final (width, height) in const [
          (3840.0, 2160.0),
          (2160.0, 3840.0),
          (7680.0, 4320.0),
          (100.0, 10000.0),
          (1.0, 1.0),
        ]) {
          for (final dpr in [1.0, 1.25, 3.0, 8.0]) {
            for (final sigma in [0.0, 8.0, 24.0, 30.0]) {
              final size = ImageMemoryBudget.blurSize(
                width,
                height,
                dpr,
                sigma,
              );
              // Account for the explicit 3-sigma gutter plus the Gaussian's own
              // 3-sigma expansion, rather than only counting the cropped output.
              final workingWidth = size.width + 4 * size.padding;
              final workingHeight = size.height + 4 * size.padding;
              expect(
                workingWidth * workingHeight * 4,
                lessThanOrEqualTo(2 * 1024 * 1024),
              );
              expect(size.bytes, lessThanOrEqualTo(size.paddedBytes));
              expect(size.paddedBytes, lessThanOrEqualTo(size.workingBytes));
              expect(size.sigma.isFinite, isTrue);
              expect(size.width, greaterThan(0));
              expect(size.height, greaterThan(0));
            }
          }
        }
      },
    );

    test('should preserve small rasters and guard invalid geometry', () {
      final tiny = ImageMemoryBudget.blurSize(8, 8, 1, 0);
      expect((tiny.width, tiny.height, tiny.padding), (8, 8, 0));
      expect(tiny.workingBytes, 8 * 8 * 4);
      for (final value in [double.nan, double.infinity, 0.0, -2.0]) {
        final source = ImageMemoryBudget.wallpaperSize(value, value, value);
        expect(
          source.width * source.height * 4,
          inInclusiveRange(4, ImageMemoryBudget.maxWallpaperBytes),
        );
        final blur = ImageMemoryBudget.blurSize(value, value, value, value);
        expect(
          blur.workingBytes,
          inInclusiveRange(4, ImageMemoryBudget.maxBlurBytes),
        );
      }
    });
  });
}
