import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:ffmpegpp_gui/widgets/liquid_modality_pills.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _State extends AppState {
  void changed() => notifyListeners();
}

Widget _host(Widget child, [_State? state]) {
  final app = MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
  return state == null
      ? app
      : ChangeNotifierProvider<AppState>.value(value: state, child: app);
}

Widget _pills() => SizedBox(
  width: 320,
  child: LiquidModalityPills(
    selected: const {'text'},
    onToggle: (_) {},
    onReorder: (_, _) {},
    labelOf: (value) => value,
    iconOf: (_) => Icons.text_fields,
  ),
);

LiquidGlassPainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<LiquidGlassPainter>()
    .first;

void main() {
  test('effective sigma rejects non-finite input', () {
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      -1.0,
    ]) {
      expect(effectiveGlassSigma(value), 0);
    }
    expect(effectiveGlassSigma(16), 8);
    expect(tunedGlassSigma(6, const GlassTuning()), 6);
  });

  testWidgets('backdrop clamps implicit and explicit sigma at the boundary', (
    tester,
  ) async {
    final state = _State();
    for (final sigma in [null, 30.0, double.nan, double.infinity, -1.0]) {
      await tester.pumpWidget(
        _host(
          LiquidGlassBackdrop(
            borderRadius: BorderRadius.circular(12),
            sigma: sigma,
            child: const SizedBox(width: 120, height: 44),
          ),
          state,
        ),
      );
      final filter = tester
          .widget<BackdropFilter>(find.byType(BackdropFilter))
          .filter;
      expect(
        identical(
          filter,
          cachedGlassBlur(sigma == null || sigma == 30 ? 8 : 0),
        ),
        isTrue,
      );
    }
  });

  testWidgets('backdrop builds without an AppState provider', (tester) async {
    await tester.pumpWidget(
      _host(
        LiquidGlassBackdrop(
          borderRadius: BorderRadius.circular(12),
          child: const SizedBox(width: 120, height: 44),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('public panel uses explicit tuning without a provider', (
    tester,
  ) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    const tuning = GlassTuning(
      blur: 2,
      clarity: 1,
      highlight: 0.3,
      lightPos: 0.6,
      edge: 0,
    );
    await tester.pumpWidget(
      _host(
        optionMenuPanel(
          scheme: scheme,
          appearance: 'liquid',
          tuning: tuning,
          child: const SizedBox(width: 120, height: 44),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(_painter(tester).highlight, 0.3);
    expect(_painter(tester).lightPos, 0.6);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  for (final appearance in ['theme', 'frosted', 'highlight']) {
    testWidgets('$appearance panel retains visuals when tuning changes', (
      tester,
    ) async {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
      Future<void> build(GlassTuning tuning) => tester.pumpWidget(
        _host(
          optionMenuPanel(
            scheme: scheme,
            appearance: appearance,
            tuning: tuning,
            child: const SizedBox(width: 120, height: 44),
          ),
        ),
      );
      await build(const GlassTuning());
      final color = tester.widget<Material>(find.byType(Material).last).color;
      final decoration = tester
          .widget<DecoratedBox>(find.byType(DecoratedBox).last)
          .decoration;
      final filters = tester
          .widgetList<BackdropFilter>(find.byType(BackdropFilter))
          .map((w) => w.filter)
          .toList();
      await build(
        const GlassTuning(
          blur: 0,
          clarity: 1,
          highlight: 0,
          lightPos: 1,
          edge: 0,
        ),
      );
      expect(tester.widget<Material>(find.byType(Material).last).color, color);
      expect(
        tester.widget<DecoratedBox>(find.byType(DecoratedBox).last).decoration,
        decoration,
      );
      expect(
        tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .map((w) => w.filter)
            .toList(),
        filters,
      );
      expect(find.byType(LiquidGlassBackdrop), findsNothing);
    });
  }

  for (final scale in [false, true]) {
    testWidgets(
      '${scale ? 'ScaleMenuButton' : 'OptionMenuBar'} subscribes to liquid tuning',
      (tester) async {
        final state = _State();
        state.config.dropdownAppearance = 'liquid';
        final menu = scale
            ? ScaleMenuButton<String>(
                icon: Icons.more_vert,
                items: const [OptionItem('one', 'One')],
                onSelected: (_) {},
              )
            : SizedBox(
                width: 160,
                child: OptionMenuBar<String>(
                  value: 'one',
                  items: const [OptionItem('one', 'One')],
                  onChanged: (_) {},
                ),
              );
        await tester.pumpWidget(_host(menu, state));
        await tester.tap(
          scale ? find.byIcon(Icons.more_vert) : find.text('One'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LiquidGlassBackdrop), findsOneWidget);
        expect(find.byType(BackdropFilter), findsOneWidget);
        state.config
          ..glassBlur = 3
          ..glassClarity = 1
          ..glassHighlight = 0.2
          ..glassLightPos = 0.8
          ..glassEdge = 0;
        state.changed();
        await tester.pumpAndSettle();
        final glass = tester.widget<LiquidGlassBackdrop>(
          find.byType(LiquidGlassBackdrop),
        );
        expect(glass.sigma, tunedGlassSigma(18, const GlassTuning(blur: 3)));
        final painter = _painter(tester);
        expect(painter.highlight, 0.2);
        expect(painter.lightPos, 0.8);
        expect(painter.edge, 0);
        final materials = tester.widgetList<Material>(
          find.descendant(
            of: find.byType(LiquidGlassBackdrop),
            matching: find.byType(Material),
          ),
        );
        expect(materials.first.color!.a, 0);
      },
    );
  }

  testWidgets(
    'modality pills safely switch liquid on and off without changing widths',
    (tester) async {
      final state = _State();
      state.config.glassEffect = 'none';
      await tester.pumpWidget(_host(_pills(), state));
      final width = tester
          .getSize(find.byKey(const ValueKey('modality_text')))
          .width;
      expect(find.byType(LiquidGlassBackdrop), findsNothing);
      state.config
        ..glassEffect = 'liquid'
        ..glassBlur = 2
        ..glassHighlight = 0.4
        ..glassLightPos = 0.7
        ..glassEdge = 0;
      state.changed();
      await tester.pumpAndSettle();
      expect(find.byType(LiquidGlassBackdrop), findsNWidgets(3));
      expect(_painter(tester).highlight, 0.4);
      expect(_painter(tester).lightPos, 0.7);
      expect(_painter(tester).edge, 0);
      expect(
        tester.getSize(find.byKey(const ValueKey('modality_text'))).width,
        width,
      );
      state.config.glassEffect = 'none';
      state.changed();
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpWidget(_host(_pills()));
      expect(tester.takeException(), isNull);
    },
  );
}
