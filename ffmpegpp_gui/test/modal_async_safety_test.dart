import 'dart:async';

import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/fppx_password.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'password verification blocks back until its result is returned',
    (tester) async {
      final verification = Completer<String?>();
      Future<String?>? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  result = showDialog<String>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => FppxPasswordDialog(
                      zh: false,
                      attempt: (_) => verification.future,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'secret');
      await tester.tap(find.text('Unlock'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FppxPasswordDialog), findsOneWidget);
      verification.complete(null);
      await tester.pumpAndSettle();
      expect(await result, 'secret');
      expect(find.byType(FppxPasswordDialog), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final zh in [false, true]) {
    testWidgets('password failure allows recovery with zh=$zh', (tester) async {
      var attempts = 0;
      Future<String?>? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  result = showDialog<String>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => FppxPasswordDialog(
                      zh: zh,
                      attempt: (_) async {
                        if (attempts++ == 0) {
                          throw StateError('Private backend details');
                        }
                        return null;
                      },
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'secret');
      final unlock = find.widgetWithText(FilledButton, zh ? '解密并打开' : 'Unlock');
      final cancel = find.widgetWithText(TextButton, zh ? '取消' : 'Cancel');
      await tester.tap(unlock);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Private backend details'), findsNothing);
      expect(
        find.text(
          zh ? '验证口令失败，请重试' : 'Unable to verify password. Please try again.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(unlock).onPressed, isNotNull);
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
      if (zh) {
        await tester.tap(cancel);
      } else {
        await tester.tap(unlock);
      }
      await tester.pumpAndSettle();
      expect(await result, zh ? isNull : 'secret');
      expect(find.byType(FppxPasswordDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
