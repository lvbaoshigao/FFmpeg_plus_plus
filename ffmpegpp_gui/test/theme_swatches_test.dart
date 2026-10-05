import 'package:ffmpegpp_gui/pages/settings_page.dart' show SettingsPage;
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('theme color controls remain usable on a narrow viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig(
      (c) => c
        ..cardStyle = 'gray'
        ..navStyle = 'gray'
        ..pillStyle = 'gray',
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
    final errors = <Object>[];
    Object? error;
    while ((error = tester.takeException()) != null) {
      errors.add(error!);
    }
    expect(errors, isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });
}
