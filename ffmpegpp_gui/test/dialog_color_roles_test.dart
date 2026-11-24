import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_alert_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Dialog color roles', () {
    final themes = [
      AppTheme.light(seedColor: 0xff0068c9),
      AppTheme.dark(seedColor: 0xff0068c9),
      AppTheme.light(seedColor: 0xff009967),
      AppTheme.dark(useThemeColor: false),
      AppTheme.light(dynamicSeed: 0xffa020b0),
    ];

    test('should use the current scheme in date and time pickers', () {
      const selected = {WidgetState.selected};
      for (final theme in themes) {
        final colors = theme.colorScheme;
        final date = theme.datePickerTheme;
        final time = theme.timePickerTheme;
        expect(date.dayBackgroundColor!.resolve(selected), colors.primary);
        expect(date.dayForegroundColor!.resolve(selected), colors.onPrimary);
        expect(date.dayBackgroundColor!.resolve({}), isNull);
        expect(date.todayBackgroundColor!.resolve(selected), colors.primary);
        expect(date.todayForegroundColor!.resolve(selected), colors.onPrimary);
        expect(date.todayBorder!.color, colors.primary);
        expect(
          date.confirmButtonStyle!.backgroundColor!.resolve({}),
          colors.primary,
        );
        expect(
          date.confirmButtonStyle!.foregroundColor!.resolve({}),
          colors.onPrimary,
        );
        expect(time.dialHandColor, colors.primary);
        expect(time.entryModeIconColor, colors.primary);
        expect(
          (time.dialTextColor! as WidgetStateColor).resolve(selected),
          colors.onPrimary,
        );
        expect(
          (time.dayPeriodColor! as WidgetStateColor).resolve(selected),
          colors.primary,
        );
        expect(
          (time.dayPeriodTextColor! as WidgetStateColor).resolve(selected),
          colors.onPrimary,
        );
        expect(
          (time.hourMinuteColor! as WidgetStateColor).resolve(selected),
          colors.primary,
        );
        expect(
          (time.hourMinuteTextColor! as WidgetStateColor).resolve(selected),
          colors.onPrimary,
        );
        expect(
          time.confirmButtonStyle!.backgroundColor!.resolve({}),
          colors.primary,
        );
        expect(
          time.confirmButtonStyle!.foregroundColor!.resolve({}),
          colors.onPrimary,
        );
      }
      expect(
        themes[0].colorScheme.primary,
        isNot(themes[2].colorScheme.primary),
      );
    });

    testWidgets('should theme ordinary actions and retain destructive colors', (
      tester,
    ) async {
      for (final theme in themes) {
        var pressed = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: AppAlertDialog(
                actions: [
                  AppDialogAction(
                    role: AppDialogActionRole.destructive,
                    child: TextButton(
                      onPressed: () {},
                      child: const Text('Delete'),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      pressed = true;
                    },
                    child: const Text('Continue'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final primary = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Continue'),
        );
        final destructive = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Delete'),
        );
        expect(
          primary.style!.backgroundColor!.resolve({}),
          theme.colorScheme.primary,
        );
        expect(
          primary.style!.foregroundColor!.resolve({}),
          theme.colorScheme.onPrimary,
        );
        expect(
          primary.style!.backgroundColor!.resolve({WidgetState.disabled}),
          isNot(theme.colorScheme.primary),
        );
        expect(
          destructive.style!.backgroundColor!.resolve({}),
          theme.colorScheme.error,
        );
        expect(
          destructive.style!.foregroundColor!.resolve({}),
          theme.colorScheme.onError,
        );
        await tester.tap(find.text('Continue'));
        expect(pressed, isTrue);
      }
    });
  });
}
