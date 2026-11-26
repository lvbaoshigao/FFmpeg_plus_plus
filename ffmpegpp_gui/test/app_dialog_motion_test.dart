import 'package:ffmpegpp_gui/theme/app_motion.dart';
import 'package:ffmpegpp_gui/widgets/app_alert_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _MotionState = ({bool disabled, EdgeInsets insets});

Future<void> _host(
  WidgetTester tester,
  ValueNotifier<_MotionState> motion, {
  required bool alert,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        dialogTheme: const DialogThemeData(backgroundColor: Color(0xddffffff)),
      ),
      builder: (context, child) => ValueListenableBuilder<_MotionState>(
        valueListenable: motion,
        builder: (context, state, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(viewInsets: state.insets),
          child: AppMotion(disabled: state.disabled, child: child!),
        ),
      ),
      home: Scaffold(
        resizeToAvoidBottomInset: false,
        body: alert
            ? const AppAlertDialog(
                title: Text('Edit value'),
                content: TextField(),
              )
            : const AppModalSurface(
                child: SizedBox(width: 400, height: 180, child: TextField()),
              ),
      ),
    ),
  );
}

Finder _surface() => find.descendant(
  of: find.byType(Dialog),
  matching: find.byWidgetPredicate(
    (widget) => widget is Material && widget.type == MaterialType.card,
  ),
);

void main() {
  for (final alert in [true, false]) {
    final name = alert ? 'alert dialog' : 'modal surface';
    testWidgets('$name applies keyboard insets immediately without motion', (
      tester,
    ) async {
      final motion = ValueNotifier<_MotionState>((
        disabled: true,
        insets: EdgeInsets.zero,
      ));
      addTearDown(motion.dispose);
      await _host(tester, motion, alert: alert);
      final original = tester.getRect(_surface());
      const insets = EdgeInsets.fromLTRB(20, 30, 40, 200);
      motion.value = (disabled: true, insets: insets);
      await tester.pump();
      expect(
        tester.getRect(_surface()),
        original.shift(const Offset(-10, -85)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.getRect(_surface()),
        original.shift(const Offset(-10, -85)),
      );
      motion.value = (disabled: true, insets: EdgeInsets.zero);
      await tester.pump();
      expect(tester.getRect(_surface()), original);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$name snaps mid-animation and preserves entered text and focus',
      (tester) async {
        final motion = ValueNotifier<_MotionState>((
          disabled: false,
          insets: EdgeInsets.zero,
        ));
        addTearDown(motion.dispose);
        await _host(tester, motion, alert: alert);
        await tester.enterText(find.byType(TextField), 'unsaved draft');
        final inputState = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        final original = tester.getRect(_surface());
        motion.value = (
          disabled: false,
          insets: const EdgeInsets.only(bottom: 200),
        );
        await tester.pump();
        expect(tester.getRect(_surface()), original);
        await tester.pump(const Duration(milliseconds: 40));
        final moving = tester.getRect(_surface());
        expect(moving.top, lessThan(original.top));
        expect(moving.top, greaterThan(original.top - 100));
        motion.value = (
          disabled: true,
          insets: const EdgeInsets.only(bottom: 200),
        );
        await tester.pump();
        expect(
          tester.getRect(_surface()),
          original.shift(const Offset(0, -100)),
        );
        expect(tester.state(find.byType(EditableText)), same(inputState));
        expect(inputState.widget.controller.text, 'unsaved draft');
        expect(inputState.widget.focusNode.hasFocus, isTrue);
        motion.value = (
          disabled: false,
          insets: const EdgeInsets.only(bottom: 200),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(_surface()),
          original.shift(const Offset(0, -100)),
        );
        expect(tester.state(find.byType(EditableText)), same(inputState));
        expect(inputState.widget.controller.text, 'unsaved draft');
        expect(inputState.widget.focusNode.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
