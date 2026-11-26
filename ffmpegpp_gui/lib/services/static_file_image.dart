import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A file image that decodes only its first frame, including for animated files.
///
/// [FileImage]'s runtime-type equality keeps static and animated cache entries
/// separate. The supplied decoder still applies an outer [ResizeImage]'s sizing.
class StaticFileImage extends FileImage {
  const StaticFileImage(super.file, {super.scale});

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) =>
      _load(key, decode);

  @override
  // Retain FileImage's legacy entry point for callers using loadBuffer.
  ImageStreamCompleter loadBuffer(
    FileImage key,
    // ignore: deprecated_member_use
    DecoderBufferCallback decode,
  ) => _load(key, decode);

  ImageStreamCompleter _load(
    FileImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode,
  ) {
    final image = _loadFirstFrame(key, decode);
    final completer = OneFrameImageStreamCompleter(
      image,
      informationCollector: () => [ErrorDescription('Path: ${file.path}')],
    )..debugLabel = key.file.path;
    // Eviction can remove every listener while the first frame is still loading.
    // Keep the completer alive until it receives that frame, so a discarded
    // decode releases its image instead of delivering it to a disposed stream.
    final pendingHandle = completer.keepAlive();
    unawaited(
      image.then<void>(
        (_) => pendingHandle.dispose(),
        onError: (Object _, StackTrace _) => pendingHandle.dispose(),
      ),
    );
    return completer;
  }

  Future<ImageInfo> _loadFirstFrame(
    FileImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer buffer) decode,
  ) async {
    // Mirror FileImage's empty-file eviction and File test-double support.
    if (await key.file.length() == 0) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError(
        '${key.file} is empty and cannot be loaded as an image.',
      );
    }
    final buffer = key.file.runtimeType == File
        ? await ui.ImmutableBuffer.fromFilePath(key.file.path)
        : await ui.ImmutableBuffer.fromUint8List(await key.file.readAsBytes());
    final codec = await decode(buffer);
    try {
      final frame = await codec.getNextFrame();
      return ImageInfo(
        image: frame.image,
        scale: key.scale,
        debugLabel: key.file.path,
      );
    } finally {
      codec.dispose();
    }
  }
}
