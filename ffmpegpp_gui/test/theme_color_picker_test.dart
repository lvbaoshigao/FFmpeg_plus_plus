import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/theme_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Outcome {
  bool closed = false;
  ThemeColorSelection? result;
}

Future<_Outcome> _open(
  WidgetTester tester, {
  Size size = const Size(1000, 860),
  double textScale = 1,
  bool bottomSheet = false,
  bool dark = false,
  bool allowGradient = true,
  bool isZh = false,
  Color initial = const Color(0xFF5E6AD2),
  Color? initial2,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final outcome = _Outcome();
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                outcome.result = await showThemeColorPicker(
                  context,
                  initial: initial,
                  initial2: initial2,
                  isZh: isZh,
                  useBottomSheet: bottomSheet,
                  allowGradient: allowGradient,
                );
                outcome.closed = true;
              },
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open picker'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return outcome;
}

Finder _key(String value) => find.byKey(ValueKey(value));

BoxDecoration _preview(WidgetTester tester) =>
    tester.widget<Container>(_key('theme-color-preview')).decoration!
        as BoxDecoration;

Future<void> _tap(WidgetTester tester, String key) async {
  final target = _key(key);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String text, [int index = 0]) async {
  final target = _key('theme-color-hex-$index');
  await tester.ensureVisible(target);
  await tester.enterText(target, text);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('valid HEX previews immediately and only Apply returns a color', (
    tester,
  ) async {
    final outcome = await _open(tester);
    await _enter(tester, ' #aBc ');
    expect(_preview(tester).color, const Color(0xFFAABBCC));
    expect(outcome.closed, isFalse);
    await _enter(tester, '01020f');
    expect(_preview(tester).color, const Color(0xFF01020F));
    await _tap(tester, 'theme-color-apply');
    expect(outcome.closed, isTrue);
    expect(outcome.result?.c1, 0xFF01020F);
    expect(outcome.result?.c2, isNull);
  });

  testWidgets('invalid HEX keeps the last valid preview and blocks Apply', (
    tester,
  ) async {
    await _open(tester);
    for (final value in ['', '#12', '#GGGGGG', '#80112233', '#12345Z']) {
      await _enter(tester, value);
      expect(find.text('Enter 3 or 6 hex digits'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('theme-color-apply')).onPressed,
        isNull,
      );
      expect(_preview(tester).color, const Color(0xFF5E6AD2));
    }
    await _enter(tester, '#00ffcc');
    expect(find.text('Enter 3 or 6 hex digits'), findsNothing);
    expect(
      tester.widget<FilledButton>(_key('theme-color-apply')).onPressed,
      isNotNull,
    );
    expect(_preview(tester).color, const Color(0xFF00FFCC));
  });

  testWidgets('gradient endpoints survive mode switches and swap together', (
    tester,
  ) async {
    final outcome = await _open(tester);
    await _enter(tester, '#112233');
    await _tap(tester, 'theme-color-gradient');
    await _tap(tester, 'theme-color-endpoint-1');
    await _enter(tester, '#446677', 1);
    expect((_preview(tester).gradient! as LinearGradient).colors, [
      const Color(0xFF112233),
      const Color(0xFF446677),
    ]);
    await _tap(tester, 'theme-color-solid');
    expect(_preview(tester).color, const Color(0xFF112233));
    await _tap(tester, 'theme-color-gradient');
    await _tap(tester, 'theme-color-swap');
    expect((_preview(tester).gradient! as LinearGradient).colors, [
      const Color(0xFF446677),
      const Color(0xFF112233),
    ]);
    await _tap(tester, 'theme-color-apply');
    expect(outcome.result?.c1, 0xFF446677);
    expect(outcome.result?.c2, 0xFF112233);
  });

  testWidgets('invalid end drafts remain invalid after switching endpoints', (
    tester,
  ) async {
    await _open(tester, initial2: Colors.blue);
    await _tap(tester, 'theme-color-endpoint-1');
    await _enter(tester, '#bad input', 1);
    await _tap(tester, 'theme-color-endpoint-0');
    expect(
      tester.widget<FilledButton>(_key('theme-color-apply')).onPressed,
      isNull,
    );
    await _tap(tester, 'theme-color-solid');
    expect(
      tester.widget<FilledButton>(_key('theme-color-apply')).onPressed,
      isNotNull,
    );
    await _tap(tester, 'theme-color-gradient');
    expect(
      tester.widget<FilledButton>(_key('theme-color-apply')).onPressed,
      isNull,
    );
    await _tap(tester, 'theme-color-endpoint-1');
    expect(
      tester.widget<TextField>(_key('theme-color-hex-1')).controller!.text,
      '#bad input',
    );
    await _enter(tester, '#abcdef', 1);
    expect(
      tester.widget<FilledButton>(_key('theme-color-apply')).onPressed,
      isNotNull,
    );
  });

  testWidgets('near-red seeds wrap the default gradient hue into range', (
    tester,
  ) async {
    final color = const HSVColor.fromAHSV(1, 350, 0.8, 0.9).toColor();
    await _open(tester, initial: color);
    await _tap(tester, 'theme-color-gradient');
    expect(tester.takeException(), isNull);
    final colors = (_preview(tester).gradient! as LinearGradient).colors;
    expect(HSVColor.fromColor(colors.last).hue, closeTo(25, 1));
  });

  testWidgets('SV field and hue slider update both HEX and preview', (
    tester,
  ) async {
    await _open(tester, initial: Colors.red);
    final field = _key('theme-color-sv');
    await tester.ensureVisible(field);
    final rect = tester.getRect(field);
    await tester.tapAt(
      rect.topLeft + Offset(rect.width * 0.25, rect.height * 0.25),
    );
    await tester.pumpAndSettle();
    final hsv = HSVColor.fromColor(_preview(tester).color!);
    expect(hsv.saturation, closeTo(0.25, 0.01));
    expect(hsv.value, closeTo(0.75, 0.01));
    final hue = find.descendant(
      of: _key('theme-color-hue'),
      matching: find.byType(Slider),
    );
    await tester.ensureVisible(hue);
    final slider = tester.getRect(hue);
    await tester.tapAt(slider.centerLeft + Offset(slider.width * 0.75, 0));
    await tester.pumpAndSettle();
    final updated = _preview(tester).color!;
    expect(HSVColor.fromColor(updated).hue, inInclusiveRange(255, 285));
    final hex = tester
        .widget<TextField>(_key('theme-color-hex-0'))
        .controller!
        .text;
    expect(
      hex,
      '#${(updated.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
    );
  });

  for (final bottomSheet in [false, true]) {
    testWidgets(
      'Cancel discards local edits (${bottomSheet ? 'sheet' : 'dialog'})',
      (tester) async {
        final outcome = await _open(tester, bottomSheet: bottomSheet);
        await _enter(tester, '#123456');
        await _tap(tester, 'theme-color-gradient');
        await _tap(tester, 'theme-color-cancel');
        expect(outcome.closed, isTrue);
        expect(outcome.result, isNull);
      },
    );
  }

  testWidgets('closing or dismissing the modal does not return a selection', (
    tester,
  ) async {
    var outcome = await _open(tester);
    await _enter(tester, '#123456');
    await _tap(tester, 'theme-color-close');
    expect(outcome.result, isNull);
    expect(outcome.closed, isTrue);
    outcome = await _open(tester);
    await _enter(tester, '#654321');
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(outcome.result, isNull);
    expect(outcome.closed, isTrue);
  });

  testWidgets('the border picker exposes only solid colors', (tester) async {
    final outcome = await _open(
      tester,
      allowGradient: false,
      initial2: Colors.red,
    );
    expect(_key('theme-color-gradient'), findsNothing);
    expect(_preview(tester).gradient, isNull);
    await _tap(tester, 'theme-color-apply');
    expect(outcome.result?.c2, isNull);
  });

  for (final scenario in [
    (const Size(280, 640), 1.6, false, false, 0.0),
    (const Size(390, 700), 1.0, true, true, 280.0),
    (const Size(800, 300), 1.4, false, true, 0.0),
    (const Size(280, 500), 2.0, true, false, 220.0),
  ]) {
    testWidgets(
      'no overflow at ${scenario.$1}, scale ${scenario.$2}, sheet ${scenario.$3}',
      (tester) async {
        final outcome = await _open(
          tester,
          size: scenario.$1,
          textScale: scenario.$2,
          bottomSheet: scenario.$3,
          dark: scenario.$4,
          initial2: Colors.white,
          isZh: scenario.$3,
        );
        tester.view.viewInsets = FakeViewPadding(bottom: scenario.$5);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _enter(tester, '#wrong');
        expect(tester.takeException(), isNull);
        await _enter(tester, '#fafafa');
        await _tap(tester, 'theme-color-apply');
        expect(outcome.result?.c1, 0xFFFAFAFA);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'light and dark modals inherit the shared dialog shape and surface',
    (tester) async {
      for (final dark in [false, true]) {
        await _open(
          tester,
          dark: dark,
          initial: Colors.white,
          initial2: Colors.black,
        );
        final theme = dark ? AppTheme.dark() : AppTheme.light();
        final surface = tester.widget<Material>(
          find
              .descendant(
                of: find.byType(ThemeColorPicker),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(surface.shape, theme.dialogTheme.shape);
        expect(surface.color, theme.dialogTheme.backgroundColor);
        final sample = tester.widget<Text>(find.text('Aa'));
        expect(sample.style!.color, theme.colorScheme.onSurface);
        await _tap(tester, 'theme-color-close');
      }
    },
  );
}
