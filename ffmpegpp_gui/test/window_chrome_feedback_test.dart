import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/window_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('window actions keep their hit area and cancel a dragged press', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: WindowChromeButton(
              icon: Icons.close,
              color: Colors.black,
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    final button = find.byType(WindowChromeButton);
    expect(tester.getSize(button), const Size(46, kWindowChromeHeight));
    final gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(100, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 0);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('window actions can be focused and activated with the keyboard', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: WindowChromeButton(
              icon: Icons.close,
              color: Colors.white,
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
