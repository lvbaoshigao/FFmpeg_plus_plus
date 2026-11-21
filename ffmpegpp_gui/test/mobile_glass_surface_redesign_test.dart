import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_card.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _host(
  AppState state,
  Widget child, {
  bool highContrast = false,
  bool disableAnimations = false,
  bool dark = false,
}) => ChangeNotifierProvider<AppState>.value(
  value: state,
  child: MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        highContrast: highContrast,
        disableAnimations: disableAnimations || highContrast,
      ),
      child: child!,
    ),
    home: Scaffold(body: child),
  ),
);

BoxDecoration _surfaceFor(WidgetTester tester, String label) {
  final containers = tester.widgetList<Container>(
    find.ancestor(of: find.text(label), matching: find.byType(Container)),
  );
  return containers
      .map((container) => container.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((decoration) => decoration.borderRadius != null);
}

void main() {
  test('legacy none value resolves to the theme surface', () {
    expect(SurfaceStyle.normalize('none'), SurfaceStyle.theme);
    expect(SurfaceStyle.normalize(SurfaceStyle.liquid), SurfaceStyle.liquid);
  });

  late AppState state;
  bool? previousMobileOverride;

  setUp(() {
    previousMobileOverride = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = true;
    state = AppState()
      ..config.language = 'en'
      ..config.cardOpacity = 0.7
      ..config.glassBlur = 30
      ..config.glassHighlight = 1.6
      ..config.glassEdge = 2
      ..config.glassFollowTheme = true
      ..config.settingsGlassMode = 'follow'
      ..config.themeColor = 0xFF8D35B5
      ..config.themeColor2 = 0xFFFF8A00;
  });

  tearDown(() {
    state.dispose();
    debugIsMobilePlatformOverride = previousMobileOverride;
  });

  test('smoke tint keeps matched strength and only a slight theme tint', () {
    final light = MobileSmokeGlassSurface.tint(
      brightness: Brightness.light,
      opacity: 0.7,
      tintScale: 1,
    );
    final dark = MobileSmokeGlassSurface.tint(
      brightness: Brightness.dark,
      opacity: 0.7,
      tintScale: 1,
    );
    final accented = MobileSmokeGlassSurface.tint(
      brightness: Brightness.light,
      opacity: 0.7,
      tintScale: 1,
      themeAccent: const Color(0xFF8D35B5),
    );
    final highContrast = MobileSmokeGlassSurface.tint(
      brightness: Brightness.light,
      opacity: 0.7,
      tintScale: 1,
      highContrast: true,
    );

    expect(light.alpha, dark.alpha);
    expect(light.alpha, greaterThanOrEqualTo(219));
    expect(light.alpha, lessThan(255));
    expect(highContrast.alpha, 255);
    for (final shift in [16, 8, 0]) {
      final neutralChannel = (light.toARGB32() >> shift) & 0xff;
      final accentedChannel = (accented.toARGB32() >> shift) & 0xff;
      expect((neutralChannel - accentedChannel).abs(), lessThanOrEqualTo(16));
    }
  });

  testWidgets('liquid cards and blurred panels share a matte smoke surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        state,
        const Column(
          children: [
            AppCard(
              style: SurfaceStyle.liquid,
              radius: 18,
              padding: EdgeInsets.zero,
              child: Text('App card'),
            ),
            GlassPanel(
              style: SurfaceStyle.blur,
              radius: 18,
              padding: EdgeInsets.zero,
              child: Text('Glass panel'),
            ),
          ],
        ),
      ),
    );

    final appCard = _surfaceFor(tester, 'App card');
    final glassPanel = _surfaceFor(tester, 'Glass panel');
    expect(appCard.color, isNotNull);
    expect(appCard.gradient, isNull);
    expect(appCard.boxShadow ?? const <BoxShadow>[], isEmpty);
    expect(appCard.border, isA<Border>());
    expect((appCard.border! as Border).top.width, lessThanOrEqualTo(0.9));
    expect(glassPanel.color, appCard.color);
    expect(glassPanel.gradient, isNull);
    expect(glassPanel.boxShadow ?? const <BoxShadow>[], isEmpty);

    final filters = tester.widgetList<BackdropFilter>(
      find.byType(BackdropFilter),
    );
    expect(filters, hasLength(2));
    for (final filter in filters) {
      expect(filter.filter, same(cachedGlassBlur(8)));
    }
  });

  testWidgets('dark-theme mobile cards keep the shared neutral material', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        state,
        const Column(
          children: [
            AppCard(style: SurfaceStyle.liquid, child: Text('Dark app card')),
            GlassPanel(style: SurfaceStyle.liquid, child: Text('Dark panel')),
          ],
        ),
        dark: true,
      ),
    );

    final appCard = _surfaceFor(tester, 'Dark app card');
    final panel = _surfaceFor(tester, 'Dark panel');
    expect(appCard.color!.alpha, greaterThanOrEqualTo(219));
    expect(appCard.color!.alpha, lessThan(255));
    expect(panel.color, appCard.color);
    expect(appCard.gradient, isNull);
    expect(appCard.boxShadow ?? const <BoxShadow>[], isEmpty);
  });

  testWidgets('mobile glass skips backdrop work at zero blur', (tester) async {
    state.config.glassBlur = 0;
    await tester.pumpWidget(
      _host(
        state,
        const Column(
          children: [
            AppCard(style: SurfaceStyle.liquid, child: Text('App card')),
            GlassPanel(style: SurfaceStyle.liquid, child: Text('Glass panel')),
          ],
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion skips mobile glass backdrop work', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        state,
        const AppCard(
          style: SurfaceStyle.liquid,
          child: Text('Reduced motion'),
        ),
        disableAnimations: true,
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(find.text('Reduced motion'), findsOneWidget);
  });

  testWidgets('high contrast skips blur and prioritizes opaque readability', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        state,
        const Column(
          children: [
            AppCard(style: SurfaceStyle.liquid, child: Text('App card')),
            GlassPanel(style: SurfaceStyle.liquid, child: Text('Glass panel')),
          ],
        ),
        highContrast: true,
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    final appCard = _surfaceFor(tester, 'App card');
    final panel = _surfaceFor(tester, 'Glass panel');
    expect(appCard.color!.alpha, 255);
    expect(panel.color, appCard.color);
    expect(appCard.gradient, isNull);
  });

  testWidgets('solid, theme, and gray settings keep opaque semantics', (
    tester,
  ) async {
    state.config.settingsGlassMode = 'solid';
    await tester.pumpWidget(
      _host(
        state,
        const Column(
          children: [
            AppCard(style: SurfaceStyle.liquid, child: Text('No glass')),
            AppCard(style: SurfaceStyle.theme, child: Text('Theme style')),
            AppCard(style: SurfaceStyle.gray, child: Text('Gray style')),
            AppCard(style: 'none', child: Text('Legacy none card')),
            GlassPanel(
              style: SurfaceStyle.liquid,
              child: Text('No glass panel'),
            ),
          ],
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    final noGlass = _surfaceFor(tester, 'No glass');
    expect(noGlass.color, isNull);
    expect(noGlass.gradient, isNotNull);
    expect(noGlass.gradient!.colors.every((color) => color.a == 1), isTrue);
    expect(_surfaceFor(tester, 'No glass panel').color, isNull);
    expect(_surfaceFor(tester, 'No glass panel').gradient, isNotNull);
    expect(_surfaceFor(tester, 'Theme style').gradient, isNotNull);
    expect(_surfaceFor(tester, 'Gray style').color!.alpha, 255);
    expect(_surfaceFor(tester, 'Gray style').gradient, isNull);
    expect(find.text('Legacy none card'), findsOneWidget);
    expect(find.byType(MobileSmokeGlassSurface), findsNothing);
  });

  testWidgets(
    'legacy none surface style resolves to an opaque mobile surface',
    (tester) async {
      await tester.pumpWidget(
        _host(
          state,
          const GlassPanel(style: 'none', child: Text('Legacy none')),
        ),
      );

      expect(find.text('Legacy none'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(MobileGlassSurface), findsNothing);
    },
  );
}
