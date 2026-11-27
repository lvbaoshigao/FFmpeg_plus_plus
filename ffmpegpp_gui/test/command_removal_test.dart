import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  for (final language in ['en', 'zh']) {
    testWidgets('mobile settings removes the command tool in $language', (
      tester,
    ) async {
      final previousMobile = debugIsMobilePlatformOverride;
      debugIsMobilePlatformOverride = true;
      addTearDown(() => debugIsMobilePlatformOverride = previousMobile);
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      state.config
        ..language = language
        ..autoCheckUpdate = false
        ..veryVerboseLogs = true
        ..cardStyle = 'gray'
        ..menuStyle = 'gray';
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      final search = find.byType(TextField).first;
      for (final query in ['command', '命令']) {
        await tester.enterText(search, query);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.terminal), findsNothing);
        expect(
          find.text(language == 'zh' ? '没有匹配的设置项' : 'No matching settings'),
          findsOneWidget,
        );
      }
      await tester.enterText(search, 'logs');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.receipt_long_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
