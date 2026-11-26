import 'dart:io';

import 'package:ffmpegpp_gui/main.dart' as entry;
import 'package:ffmpegpp_gui/services/multi_window.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('image budget is applied before a detached-engine early return', () async {
    addTearDown(resetDesktopGlassForTesting);
    resetDesktopGlassForTesting(loader: () async => true);
    // An invalid Linux panel request safely returns before plugin/window/backend
    // initialization, exercising the common budget before either panel branch.
    entry.main([MultiWindowService.linuxProcessArgument]);
    await Future<void>.delayed(Duration.zero);
    final cache = PaintingBinding.instance.imageCache;
    expect(cache.maximumSizeBytes, 12 << 20);
    expect(cache.maximumSize, 64);
  }, skip: !Platform.isLinux);
}
