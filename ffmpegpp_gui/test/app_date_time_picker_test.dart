import 'package:ffmpegpp_gui/theme/app_motion.dart';
import 'package:ffmpegpp_gui/widgets/app_date_time_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _host(
  WidgetTester tester, {
  required bool disabled,
  required VoidCallback Function(BuildContext) onOpen,
  Locale? datePickerLocale,
}) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('en'), Locale('zh')],
    theme: ThemeData(
      datePickerTheme: DatePickerThemeData(locale: datePickerLocale),
    ),
    builder: (context, child) => AppMotion(disabled: disabled, child: child!),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: onOpen(context),
          child: const Text('Open picker'),
        ),
      ),
    ),
  ),
);

void main() {
  for (final disabled in [false, true]) {
    testWidgets(
      'date picker preserves its value with motion disabled=$disabled',
      (tester) async {
        DateTime? result;
        final initialDate = DateTime(2026, 11, 26, 17, 30);
        await _host(
          tester,
          disabled: disabled,
          onOpen: (context) => () async {
            result = await showAppDatePicker(
              context: context,
              initialDate: initialDate,
              firstDate: DateTime(2025),
              lastDate: DateTime(2028),
            );
          },
        );
        await tester.tap(find.text('Open picker'));
        await tester.pump();
        final picker = find.byType(DatePickerDialog);
        expect(picker, findsOneWidget);
        final route = ModalRoute.of(tester.element(picker))!;
        expect(
          route.transitionDuration,
          disabled ? Duration.zero : const Duration(milliseconds: 150),
        );
        expect(route.reverseTransitionDuration, route.transitionDuration);
        if (disabled) expect(route.animation!.value, 1);
        final dialog = tester.widget<DatePickerDialog>(picker);
        expect(dialog.initialDate, DateTime(2026, 11, 26));
        expect(dialog.firstDate, DateTime(2025));
        expect(dialog.lastDate, DateTime(2028));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(result, DateTime(2026, 11, 26));
        expect(picker, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'time picker preserves input mode with motion disabled=$disabled',
      (tester) async {
        TimeOfDay? result;
        const initialTime = TimeOfDay(hour: 9, minute: 42);
        await _host(
          tester,
          disabled: disabled,
          onOpen: (context) => () async {
            result = await showAppTimePicker(
              context: context,
              initialTime: initialTime,
              initialEntryMode: TimePickerEntryMode.input,
            );
          },
        );
        await tester.tap(find.text('Open picker'));
        await tester.pump();
        final picker = find.byType(TimePickerDialog);
        expect(picker, findsOneWidget);
        final route = ModalRoute.of(tester.element(picker))!;
        expect(
          route.transitionDuration,
          disabled ? Duration.zero : const Duration(milliseconds: 150),
        );
        expect(route.reverseTransitionDuration, route.transitionDuration);
        if (disabled) expect(route.animation!.value, 1);
        final dialog = tester.widget<TimePickerDialog>(picker);
        expect(dialog.initialTime, initialTime);
        expect(dialog.initialEntryMode, TimePickerEntryMode.input);
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(result, initialTime);
        expect(picker, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('static date picker keeps the date-picker theme locale', (
    tester,
  ) async {
    await _host(
      tester,
      disabled: true,
      datePickerLocale: const Locale('zh'),
      onOpen: (context) => () {
        showAppDatePicker(
          context: context,
          initialDate: DateTime(2026, 11, 26),
          firstDate: DateTime(2025),
          lastDate: DateTime(2028),
        );
      },
    );
    await tester.tap(find.text('Open picker'));
    await tester.pump();
    final picker = find.byType(DatePickerDialog);
    expect(Localizations.localeOf(tester.element(picker)), const Locale('zh'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(picker, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
