import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/theme/app_press_feedback.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _imageKey = ValueKey('press-capture');
const _buttonKey = ValueKey('press-button');

Widget _host(Widget child, {bool reduced = false}) => MaterialApp(
  theme: AppTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: AppPressTheme(
      child: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: _imageKey,
            child: SizedBox(width: 200, height: 80, child: child),
          ),
        ),
      ),
    ),
  ),
);

Future<List<int>> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_imageKey),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return bytes!.buffer.asUint8List().toList();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('ink lights the full contained shape and clears on cancellation', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        Material(
          color: Colors.white,
          child: Center(
            child: SizedBox(
              width: 160,
              height: 48,
              child: InkWell(
                key: _buttonKey,
                borderRadius: BorderRadius.circular(12),
                onTap: () => taps++,
                child: const Center(child: Text('Continue')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = await _pixels(tester);
    final button = find.byKey(_buttonKey);
    final box = tester.getRect(button);
    final press = await tester.startGesture(box.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getRect(button), box);
    final down = await _pixels(tester);
    int red(List<int> bytes, int x, int y) => bytes[(y * 200 + x) * 4];
    // Both sides light together; a travelling circular ripple has no delay.
    expect(red(down, 32, 40), lessThan(red(before, 32, 40)));
    expect(red(down, 168, 40), lessThan(red(before, 168, 40)));
    // The new feature is clipped to the control, leaving adjacent material alone.
    expect(red(down, 5, 40), red(before, 5, 40));
    expect(red(down, 195, 40), red(before, 195, 40));
    await press.cancel();
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(await _pixels(tester), before);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reduced motion releases immediately and factories remain stable',
    (tester) async {
      var taps = 0;
      const child = SizedBox(width: 160, height: 48);
      Widget button() => Material(
        color: Colors.white,
        child: InkWell(key: _buttonKey, onTap: () => taps++, child: child),
      );
      await tester.pumpWidget(_host(button(), reduced: true));
      await tester.pumpAndSettle();
      final control = find.byKey(_buttonKey);
      final factory = Theme.of(tester.element(control)).splashFactory;
      final before = await _pixels(tester);
      final press = await tester.startGesture(tester.getCenter(control));
      await tester.pump();
      final lit = await _pixels(tester);
      expect(lit, isNot(before));
      await tester.pump(const Duration(seconds: 1));
      expect(await _pixels(tester), lit);
      await press.up();
      await tester.pump();
      expect(taps, 1);
      expect(await _pixels(tester), before);
      await tester.pumpWidget(_host(button(), reduced: true));
      await tester.pump();
      expect(Theme.of(tester.element(control)).splashFactory, same(factory));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('native disabled and keyboard controls preserve their actions', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        Row(
          children: [
            const IconButton(
              onPressed: null,
              tooltip: 'Unavailable',
              icon: Icon(Icons.close),
            ),
            Expanded(
              child: FilledButton(
                key: _buttonKey,
                onPressed: () => taps++,
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byTooltip('Unavailable'));
    await tester.pumpAndSettle();
    expect(taps, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
