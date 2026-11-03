import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('determinate and indeterminate progress bars paint safely', (
    tester,
  ) async {
    final state = AppState();
    final semanticsHandle = tester.ensureSemantics();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                child: AppProgressBar(value: 0.62, semanticsLabel: 'Transfer'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppProgressBar), findsOneWidget);
    final semantics = tester
        .getSemantics(find.bySemanticsLabel('Transfer'))
        .getSemanticsData();
    expect(semantics.label, 'Transfer');
    expect(semantics.value, '62%');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: SizedBox(width: 240, child: AppProgressBar())),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(AppProgressBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    semanticsHandle.dispose();
    state.dispose();
  });

  testWidgets('reduced motion keeps indeterminate progress static in RTL', (
    tester,
  ) async {
    final state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                body: SizedBox(width: 240, child: AppProgressBar()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(AppProgressBar), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
