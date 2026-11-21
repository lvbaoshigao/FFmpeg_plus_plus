import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:ffmpegpp_gui/widgets/liquid_modality_pills.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:ffmpegpp_gui/widgets/mobile_ui.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:ffmpegpp_gui/widgets/selection_highlight.dart';
import 'package:ffmpegpp_gui/widgets/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _host(
  Widget child, {
  AppState? state,
  bool disableAnimations = false,
  bool highContrast = false,
  double textScale = 1,
}) => ChangeNotifierProvider<AppState>.value(
  value: state ?? AppState(),
  child: MaterialApp(
    theme: AppTheme.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: disableAnimations,
        highContrast: highContrast,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

void _asMobile() {
  debugIsMobilePlatformOverride = true;
  addTearDown(() => debugIsMobilePlatformOverride = null);
}

AppState _state() {
  final state = AppState();
  addTearDown(state.dispose);
  return state;
}

void main() {
  test('mobile glass sigma remains capped at 8', () {
    expect(mobileGlassSigma(30), 8);
    expect(mobileGlassSigma(double.infinity), 0);
  });

  testWidgets('selection blur becomes static when mobile motion is reduced', (
    tester,
  ) async {
    _asMobile();
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 60,
          height: 40,
          child: SelectionHighlight(style: 'blur'),
        ),
        disableAnimations: true,
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slider track skips live blur in mobile high contrast', (
    tester,
  ) async {
    _asMobile();
    final state = _state();
    await tester.pumpWidget(
      _host(
        AppSlider(value: 0.5, onChanged: (_) {}),
        state: state,
        highContrast: true,
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct popup panel rendering honors mobile high contrast', (
    tester,
  ) async {
    _asMobile();
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => optionMenuPanel(
            context: context,
            scheme: Theme.of(context).colorScheme,
            appearance: 'frosted',
            tuning: const GlassTuning(),
            child: const SizedBox(width: 180, height: 80),
          ),
        ),
        highContrast: true,
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('modality selection uses only the parent glass track', (
    tester,
  ) async {
    _asMobile();
    final state = _state()..config.glassEffect = 'liquid';
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 340,
          child: MobileGlassPill(
            style: 'blur',
            height: 52,
            padding: EdgeInsets.zero,
            child: LiquidModalityPills(
              selected: const {'text'},
              onToggle: (_) {},
              onReorder: (_, _) {},
              labelOf: (value) => value,
              iconOf: (_) => Icons.circle,
            ),
          ),
        ),
        state: state,
      ),
    );

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('segmented pills expose selection and 44dp keyboard targets', (
    tester,
  ) async {
    _asMobile();
    final state = _state()..config.pillStyle = 'gray';
    var selectedIndex = 0;
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 340,
              child: MobileSegmentedPills(
                tabs: const [MobilePillTab('First'), MobilePillTab('Second')],
                selectedIndex: selectedIndex,
                onSelected: (index) => setState(() => selectedIndex = index),
              ),
            ),
          ),
          state: state,
          textScale: 1.6,
        ),
      );
      await tester.pumpAndSettle();

      final second = find.byKey(const ValueKey('mobile_segmented_tab_1'));
      expect(tester.getSize(second).height, greaterThanOrEqualTo(44));
      expect(
        tester.getSemantics(second).flagsCollection.isSelected,
        ui.Tristate.isFalse,
      );
      expect(tester.getSemantics(second).flagsCollection.isButton, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selectedIndex, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('toast stays below the mobile safe-area inset without blur', (
    tester,
  ) async {
    _asMobile();
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 70, bottom: 24);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showToast(context, 'Safe-area message'),
            child: const Text('show'),
          ),
        ),
        disableAnimations: true,
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();

    final toast = find.text('Safe-area message');
    expect(toast, findsOneWidget);
    final positioned = find
        .ancestor(of: toast, matching: find.byType(Positioned))
        .first;
    expect(tester.getTopLeft(positioned).dy, greaterThanOrEqualTo(78));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });
}
