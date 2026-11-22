import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/pages/config_library_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/services/quick_config_storage.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_card.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_mobile_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _LibraryConfigService extends ConfigService {
  @override
  Future<List<Map<String, dynamic>>> loadLibrary() async => [];
}

class _LibraryState extends AppState {
  final _libraryConfig = _LibraryConfigService();

  @override
  ConfigService get configService => _libraryConfig;
}

Widget _host(
  AppState state,
  Widget child, {
  Brightness brightness = Brightness.dark,
  bool highContrast = false,
  bool reducedMotion = false,
  double textScale = 1,
}) => ChangeNotifierProvider<AppState>.value(
  value: state,
  child: MaterialApp(
    theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        highContrast: highContrast,
        disableAnimations: reducedMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}

void main() {
  late AppState state;
  bool? previousMobileOverride;

  setUp(() {
    previousMobileOverride = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = true;
    state = _LibraryState()..config.language = 'en';
  });

  tearDown(() {
    state.dispose();
    debugIsMobilePlatformOverride = previousMobileOverride;
  });

  for (final brightness in Brightness.values) {
    for (final settings in [
      (name: 'default', opacity: 0.76, tintScale: 1.0),
      (
        name: 'airy low opacity',
        opacity: 0.1,
        tintScale: const GlassTuning(clarity: 0.95).tintScale,
      ),
    ]) {
      test(
        'smoke $brightness ${settings.name} preserves body text contrast',
        () {
          final scheme = brightness == Brightness.dark
              ? AppTheme.dark().colorScheme
              : AppTheme.light().colorScheme;
          final tint = MobileSmokeGlassSurface.tint(
            brightness: brightness,
            opacity: settings.opacity,
            tintScale: settings.tintScale,
            themeAccent: Colors.purple,
          );
          expect(
            tint.a,
            lessThan(1),
            reason: 'Smoke still transmits the backdrop',
          );
          for (final backdrop in [Colors.black, Colors.white]) {
            final composite = Color.alphaBlend(tint, backdrop);
            for (final foreground in [
              scheme.onSurface,
              scheme.onSurfaceVariant,
            ]) {
              expect(
                _contrast(foreground, composite),
                greaterThanOrEqualTo(4.5),
                reason:
                    'Small card labels need contrast even on opposing wallpaper',
              );
            }
          }
        },
      );
    }

    testWidgets('high contrast $brightness smoke is opaque at zero opacity', (
      tester,
    ) async {
      state.config.cardOpacity = 0;
      await tester.pumpWidget(
        _host(
          state,
          const AppCard(
            style: SurfaceStyle.liquid,
            child: Text('Readable card'),
          ),
          brightness: brightness,
          highContrast: true,
        ),
      );
      final decoration = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(MobileSmokeGlassSurface),
              matching: find.byType(Container),
            ),
          )
          .map((container) => container.decoration)
          .whereType<BoxDecoration>()
          .single;
      expect(decoration.color!.a, 1);
      expect(find.byType(BackdropFilter), findsNothing);
    });
  }

  testWidgets('mobile glass paints one restrained contour', (tester) async {
    final capture = GlobalKey();
    await tester.pumpWidget(
      _host(
        state,
        RepaintBoundary(
          key: capture,
          child: MobileGlassSurface(
            borderRadius: BorderRadius.circular(22),
            tuning: const GlassTuning(blur: 0),
            opacity: 0.76,
            liquid: false,
            child: const SizedBox(width: 180, height: 44),
          ),
        ),
      ),
    );
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final samples = await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (final y in [1, 4]) data.getUint8((y * image.width + 90) * 4),
        ];
      } finally {
        image.dispose();
      }
    });
    expect(
      samples![0],
      closeTo(samples[1], 2),
      reason: 'The inset content must not carry a second bright rim',
    );
  });

  testWidgets('theme mobile tab track stays neutral with a purple theme', (
    tester,
  ) async {
    state.config
      ..navStyle = 'theme'
      ..selectionIndicatorStyle = 'theme'
      ..themeColor = Colors.purple.toARGB32()
      ..glassFollowTheme = true;
    await tester.pumpWidget(
      _host(
        state,
        SizedBox(
          width: 320,
          child: AppLiquidTabBar(
            currentIndex: 0,
            onTap: (_) {},
            items: const [
              LiquidGlassTabItem(icon: Icon(Icons.folder), label: 'Projects'),
              LiquidGlassTabItem(icon: Icon(Icons.list), label: 'Queue'),
            ],
          ),
        ),
      ),
    );
    final row = find.byKey(const ValueKey('app-tab-drag-surface'));
    final track = tester
        .widgetList<DecoratedBox>(
          find.ancestor(of: row, matching: find.byType(DecoratedBox)),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .firstWhere(
          (decoration) => decoration.color != null && decoration.color!.a > 0,
        );
    expect(
      HSLColor.fromColor(track.color!).saturation,
      lessThanOrEqualTo(0.02),
    );
    final selection =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byType(MobileGlassSelection),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(
      HSLColor.fromColor(selection.color!).saturation,
      lessThanOrEqualTo(0.02),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets(
    'large text config selector keeps its labels within the surface',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 720);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
      addTearDown(tester.view.reset);
      final temporary = Directory.systemTemp.createTempSync(
        'mobile-glass-geometry-',
      );
      final previousDirectory = QuickConfigStorage.directoryOverride;
      QuickConfigStorage.directoryOverride = temporary;
      addTearDown(() async {
        QuickConfigStorage.directoryOverride = previousDirectory;
        await temporary.delete(recursive: true);
      });
      state.config
        ..navStyle = 'liquid'
        ..selectionIndicatorStyle = 'liquid';
      await tester.runAsync(() async {
        await tester.pumpWidget(
          _host(
            state,
            const ConfigLibraryPage(),
            textScale: 3,
            reducedMotion: true,
          ),
        );
        await QuickConfigStorage.loadAll(null);
      });
      await tester.pumpAndSettle();
      final selector = find.byType(AppLiquidTabBar);
      expect(selector, findsOneWidget);
      final surface = tester.getRect(
        find.descendant(
          of: selector,
          matching: find.byType(MobileGlassSurface),
        ),
      );
      for (final label in ['Nodes', 'Quick']) {
        final text = tester.getRect(find.text(label));
        expect(text.top, greaterThanOrEqualTo(surface.top));
        expect(text.bottom, lessThanOrEqualTo(surface.bottom));
        expect(text.height, greaterThanOrEqualTo(31));
      }
      final first = tester.getRect(find.byKey(const ValueKey('app-tab-0')));
      expect(first.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
