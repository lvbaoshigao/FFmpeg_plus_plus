import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/widgets/window_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('clips window content with Linux corner radius', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LinuxWindowFrame(
          child: ColoredBox(color: Colors.blue, child: SizedBox.expand()),
        ),
      ),
    );

    final clips = tester.widgetList<ClipRRect>(find.byType(ClipRRect));
    if (isLinuxPlatform) {
      expect(
        clips.any(
          (clip) =>
              clip.borderRadius ==
              BorderRadius.circular(kLinuxWindowCornerRadius),
        ),
        isTrue,
      );
    } else {
      expect(clips, isEmpty);
    }
  });
}
