import 'package:flutter/material.dart';

/// Date picker with the same defaults as [showDatePicker], plus the app's
/// reduced-motion route behavior.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  DateTime? initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  if (!MediaQuery.disableAnimationsOf(context)) {
    return showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
  }

  // showDatePicker applies the date-picker theme's locale outside its dialog.
  // Keep that behavior when constructing the zero-duration route ourselves.
  final locale = DatePickerTheme.of(context).locale;
  Widget dialog = DatePickerDialog(
    initialDate: initialDate,
    firstDate: firstDate,
    lastDate: lastDate,
  );
  if (locale != null) {
    dialog = Localizations.override(
      context: context,
      locale: locale,
      child: dialog,
    );
  }
  return showDialog<DateTime>(
    context: context,
    animationStyle: AnimationStyle.noAnimation,
    builder: (_) => dialog,
  );
}

/// Time picker with the same defaults as [showTimePicker], plus the app's
/// reduced-motion route behavior.
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  TimePickerEntryMode initialEntryMode = TimePickerEntryMode.dial,
}) {
  if (!MediaQuery.disableAnimationsOf(context)) {
    return showTimePicker(
      context: context,
      initialTime: initialTime,
      initialEntryMode: initialEntryMode,
    );
  }

  return showDialog<TimeOfDay>(
    context: context,
    animationStyle: AnimationStyle.noAnimation,
    builder: (_) => TimePickerDialog(
      initialTime: initialTime,
      initialEntryMode: initialEntryMode,
    ),
  );
}
