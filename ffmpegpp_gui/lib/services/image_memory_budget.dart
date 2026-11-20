import 'dart:math' as math;

/// Pixel limits for wallpaper source decoding and its shared blurred derivative.
///
/// These bounds describe RGBA raster storage, not the whole process RSS or codec
/// scratch memory. A source is at most 8 MiB; a Gaussian working surface is at
/// most 2 MiB, including both the explicit gutter and the filter's own expansion.
abstract final class ImageMemoryBudget {
  static const bytesPerPixel = 4;
  static const maxWallpaperPixels = 2 * 1024 * 1024;
  static const maxWallpaperBytes = maxWallpaperPixels * bytesPerPixel;
  static const maxBlurPixels = 512 * 1024;
  static const maxBlurBytes = maxBlurPixels * bytesPerPixel;

  /// Bounding decode dimensions, bucketed downward to reduce resize variants.
  /// ResizeImagePolicy.fit must still preserve the source's aspect ratio.
  static ({int width, int height}) wallpaperSize(
    double logicalWidth,
    double logicalHeight,
    double devicePixelRatio,
  ) {
    final size = _physicalSize(logicalWidth, logicalHeight, devicePixelRatio);
    final scale = math.min(
      1.0,
      math.sqrt(maxWallpaperPixels / (size.width * size.height)),
    );
    int bucket(double dimension) {
      final value = math.max(1, (dimension * scale).floor());
      return value < 64 ? value : value ~/ 64 * 64;
    }

    return (width: bucket(size.width), height: bucket(size.height));
  }

  /// Raster plan whose Gaussian-expanded intermediate remains within 2 MiB.
  /// The visible image has the viewport aspect ratio up to integer rounding.
  static BlurRasterBudget blurSize(
    double logicalWidth,
    double logicalHeight,
    double devicePixelRatio,
    double logicalSigma,
  ) {
    final size = _physicalSize(logicalWidth, logicalHeight, devicePixelRatio);
    final sigma = logicalSigma.isFinite
        ? logicalSigma.clamp(0.0, 30.0).toDouble()
        : 0.0;
    final width = _positive(logicalWidth);
    final height = _positive(logicalHeight);
    final density = math.min(size.width / width, size.height / height);
    BlurRasterBudget at(double scale) {
      final radius = (sigma * density * scale).clamp(0.0, 32.0);
      return BlurRasterBudget(
        math.max(1, (size.width * scale).floor()),
        math.max(1, (size.height * scale).floor()),
        radius,
        (3 * radius).ceil(),
      );
    }

    final full = at(1.0);
    if (full.workingPixels <= maxBlurPixels) return full;
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 48; i++) {
      final middle = (low + high) / 2;
      if (at(middle).workingPixels <= maxBlurPixels) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return at(low);
  }

  static double _positive(double value) =>
      value.isFinite && value > 0 ? value : 1.0;

  static ({double width, double height}) _physicalSize(
    double logicalWidth,
    double logicalHeight,
    double devicePixelRatio,
  ) {
    final width = _positive(logicalWidth);
    final height = _positive(logicalHeight);
    final density = math.min(
      _positive(devicePixelRatio),
      8192 / math.max(width, height),
    );
    return (
      width: math.max(1.0, width * density),
      height: math.max(1.0, height * density),
    );
  }
}

/// One bounded preblur: a cropped output, its gutter and Gaussian expansion.
final class BlurRasterBudget {
  const BlurRasterBudget(this.width, this.height, this.sigma, this.padding);

  final int width;
  final int height;
  final double sigma;
  final int padding;

  int get pixels => width * height;
  int get bytes => pixels * ImageMemoryBudget.bytesPerPixel;
  int get paddedWidth => width + 2 * padding;
  int get paddedHeight => height + 2 * padding;
  int get paddedPixels => paddedWidth * paddedHeight;
  int get paddedBytes => paddedPixels * ImageMemoryBudget.bytesPerPixel;
  int get workingPixels => (width + 4 * padding) * (height + 4 * padding);
  int get workingBytes => workingPixels * ImageMemoryBudget.bytesPerPixel;
}
