import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'image_memory_budget.dart';

/// Decodes oversized wallpapers only to the size the app can display and cache.
abstract final class WallpaperImageOptimizer {
  static ({int width, int height})? targetSize(
    int sourceWidth,
    int sourceHeight, {
    required int maxWidth,
    required int maxHeight,
  }) {
    if (sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        maxWidth <= 0 ||
        maxHeight <= 0) {
      return null;
    }

    final pixelScale = math.sqrt(
      ImageMemoryBudget.maxWallpaperPixels /
          (sourceWidth.toDouble() * sourceHeight),
    );
    final scale = math.min(
      1.0,
      math.min(
        maxWidth / sourceWidth,
        math.min(maxHeight / sourceHeight, pixelScale),
      ),
    );
    return (
      width: math.max(1, (sourceWidth * scale).floor()),
      height: math.max(1, (sourceHeight * scale).floor()),
    );
  }

  /// Produces a filesystem-safe, content-addressed name.
  static String contentAddressedFileName(
    String requestedName,
    Uint8List bytes,
  ) {
    final safeName = requestedName.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final dot = safeName.lastIndexOf('.');
    final base = dot > 0 ? safeName.substring(0, dot) : safeName;
    final extension = dot > 0 ? safeName.substring(dot) : '';
    final prefix = base.isEmpty ? 'wallpaper' : base;
    final boundedPrefix = prefix.length > 80 ? prefix.substring(0, 80) : prefix;
    final digest = sha256.convert(bytes).toString();
    return '${boundedPrefix}_$digest$extension';
  }

  /// Renders one already-decoded frame into the requested output dimensions.
  static Future<ui.Image> _resizeRaster(
    ui.Image source,
    ({int width, int height}) target,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      source,
      ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, target.width.toDouble(), target.height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(target.width, target.height);
    } finally {
      picture.dispose();
    }
  }

  /// Returns the original bytes when no resize is needed, or a bounded PNG.
  /// A null result means the image could not be inspected or encoded.
  /// Oversized animated inputs are rejected before a full-size frame decode.
  static Future<Uint8List?> optimize(
    Uint8List bytes, {
    required int maxWidth,
    required int maxHeight,
  }) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final target = targetSize(
        descriptor.width,
        descriptor.height,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );
      if (target == null) return null;
      if (target.width == descriptor.width &&
          target.height == descriptor.height) {
        return bytes;
      }

      codec = await descriptor.instantiateCodec(
        targetWidth: target.width,
        targetHeight: target.height,
      );
      if (codec.frameCount > 1 &&
          descriptor.width * descriptor.height >
              ImageMemoryBudget.maxWallpaperPixels) {
        // Multi-frame codecs ignore targetWidth/targetHeight and decode at
        // the source dimensions. Reject unsafe inputs before decoding a frame.
        throw const WallpaperImageTooLargeToResizeException();
      }

      decoded = (await codec.getNextFrame()).image;
      if (decoded.width != target.width || decoded.height != target.height) {
        if (decoded.width * decoded.height >
            ImageMemoryBudget.maxWallpaperPixels) {
          throw const WallpaperImageTooLargeToResizeException();
        }
        final source = decoded;
        decoded = null;
        try {
          decoded = await _resizeRaster(source, target);
        } finally {
          source.dispose();
        }
      }
      final output = decoded;
      final data = await output.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on WallpaperImageTooLargeToResizeException {
      rethrow;
    } catch (_) {
      return null;
    } finally {
      decoded?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

/// Raised when resizing would require a full-size, over-budget frame decode.
class WallpaperImageTooLargeToResizeException implements Exception {
  const WallpaperImageTooLargeToResizeException();
}
