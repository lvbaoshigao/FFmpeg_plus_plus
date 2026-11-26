import 'package:ffmpegpp_gui/widgets/app_animated_size.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required bool disabled, required Size size, Widget? child}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disabled),
        child: Scaffold(
          body: Center(
            child: AppAnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('disabled motion snaps size changes and viewport reflow', (
    tester,
  ) async {
    await tester.pumpWidget(_host(disabled: true, size: const Size(200, 100)));
    await tester.pumpWidget(_host(disabled: true, size: const Size(400, 180)));
    expect(tester.getSize(find.byType(AppAnimatedSize)), const Size(400, 180));
    await tester.pumpWidget(_host(disabled: true, size: const Size(250, 120)));
    expect(tester.getSize(find.byType(AppAnimatedSize)), const Size(250, 120));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal sizing animates and disabling mid-animation snaps', (
    tester,
  ) async {
    await tester.pumpWidget(_host(disabled: false, size: const Size(200, 100)));
    await tester.pumpWidget(_host(disabled: false, size: const Size(400, 180)));
    await tester.pump(const Duration(milliseconds: 60));
    final intermediate = tester.getSize(find.byType(AppAnimatedSize));
    expect(intermediate.height, inExclusiveRange(100, 180));
    expect(intermediate.width, inExclusiveRange(200, 400));
    await tester.pumpWidget(_host(disabled: true, size: const Size(400, 180)));
    expect(tester.getSize(find.byType(AppAnimatedSize)), const Size(400, 180));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime motion changes preserve form state, text and focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        disabled: false,
        size: const Size(240, 100),
        child: const TextField(),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Unsaved prompt');
    final input = tester.state<EditableTextState>(find.byType(EditableText));
    final focus = input.widget.focusNode;
    expect(focus.hasFocus, isTrue);
    for (final disabled in [true, false, true]) {
      await tester.pumpWidget(
        _host(
          disabled: disabled,
          size: const Size(400, 140),
          child: const TextField(),
        ),
      );
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(input),
      );
      expect(input.widget.controller.text, 'Unsaved prompt');
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
