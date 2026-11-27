import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_mobile_nav.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart'
    show LiquidGlassTabBar;
import 'package:provider/provider.dart';

Widget _host(
  AppState state,
  Widget child, {
  bool reducedMotion = false,
  bool highContrast = false,
  ThemeData? theme,
}) => ChangeNotifierProvider<AppState>.value(
  value: state,
  child: MaterialApp(
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: reducedMotion, highContrast: highContrast),
      child: child!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  late AppState state;
  bool? previousMobileOverride;

  setUp(() {
    previousMobileOverride = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = true;
    state = AppState()..config.language = 'en';
  });

  tearDown(() {
    state.dispose();
    debugIsMobilePlatformOverride = previousMobileOverride;
  });

  testWidgets('floating pills cap mobile backdrop blur', (tester) async {
    state.config.glassBlur = 30;
    await tester.pumpWidget(
      _host(
        state,
        const MobileGlassPill(
          style: 'blur',
          child: SizedBox(width: 160, height: 44),
        ),
      ),
    );
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    // 悬浮药丸磨砂上限为 kMobileFloatingGlassMaxSigma（卡片等仍为 8）。
    expect(filter.filter, same(cachedGlassBlur(kMobileFloatingGlassMaxSigma)));
    expect(
      find.ancestor(
        of: find.byType(BackdropFilter),
        matching: find.byType(ClipRRect),
      ),
      findsOneWidget,
    );
  });

  for (final style in ['liquid', 'blur']) {
    testWidgets('$style pill skips backdrop work in reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          state,
          MobileGlassPill(style: style, child: const Text('Readable')),
          reducedMotion: true,
        ),
      );
      expect(find.text('Readable'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'neutral $brightness pill retains contrast on opposing backdrops',
      (tester) async {
        state.config
          ..glassBlur = 0
          ..glassHighlight = 0
          ..glassEdge = 0;
        final key = GlobalKey();
        final scheme = ColorScheme.fromSeed(
          seedColor: Colors.purple,
          brightness: brightness,
        );
        final foreground = scheme.onSurface.computeLuminance();
        await tester.pumpWidget(
          _host(
            state,
            RepaintBoundary(
              key: key,
              child: const Stack(
                children: [
                  Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: ColoredBox(color: Colors.black)),
                        Expanded(child: ColoredBox(color: Colors.white)),
                      ],
                    ),
                  ),
                  MobileGlassPill(
                    style: 'blur',
                    radius: 22,
                    padding: EdgeInsets.zero,
                    child: SizedBox(width: 160, height: 44),
                  ),
                ],
              ),
            ),
            theme: ThemeData.from(colorScheme: scheme),
          ),
        );
        expect(find.byType(BackdropFilter), findsNothing);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final pixels = await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final rgba = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            return [
              for (final x in [40, 120])
                Color.fromARGB(
                  255,
                  rgba.getUint8((22 * image.width + x) * 4),
                  rgba.getUint8((22 * image.width + x) * 4 + 1),
                  rgba.getUint8((22 * image.width + x) * 4 + 2),
                ),
            ];
          } finally {
            image.dispose();
          }
        });
        expect(
          pixels!.first,
          isNot(pixels.last),
          reason: 'Glass still transmits backdrop detail',
        );
        for (final pixel in pixels) {
          expect(pixel.r, closeTo(pixel.b, 0.005));
          expect(pixel.g, closeTo(pixel.b, 0.005));
          final luminance = pixel.computeLuminance();
          final ratio = luminance > foreground
              ? (luminance + 0.05) / (foreground + 0.05)
              : (foreground + 0.05) / (luminance + 0.05);
          expect(ratio, greaterThanOrEqualTo(4.5));
        }
      },
    );
  }

  testWidgets('compact pill action accepts taps outside its visible disk', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        state,
        MobileGlassPillAction(
          icon: Icons.search,
          tooltip: 'Search',
          color: null,
          onTap: () => taps++,
        ),
      ),
    );
    final target = tester.getRect(find.byTooltip('Search'));
    expect(target.width, greaterThanOrEqualTo(44));
    expect(target.height, greaterThanOrEqualTo(44));
    await tester.tapAt(target.centerLeft + const Offset(2, 0));
    expect(taps, 1);
  });

  testWidgets('pressable pill has an accessible keyboard activation', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        state,
        MobileGlassPill(
          height: 36,
          onTap: () => taps++,
          child: const Text('Choose'),
        ),
      ),
    );
    final pill = find.byType(MobileGlassPill);
    expect(tester.getSize(pill).height, greaterThanOrEqualTo(44));
    expect(
      tester.getSemantics(find.text('Choose')).flagsCollection.isButton,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 1);
  });

  testWidgets('mobile liquid indicator keeps the hosted droplet bar', (
    tester,
  ) async {
    state.config
      ..navStyle = 'liquid'
      ..selectionIndicatorStyle = 'liquid';
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
    expect(find.byType(LiquidGlassTabBar), findsOneWidget);
    expect(find.byKey(const ValueKey('app-tab-selection')), findsNothing);
  });

  testWidgets(
    'mobile theme tabs have one selection surface and stable tap targets',
    (tester) async {
      state.config
        ..navStyle = 'liquid'
        ..selectionIndicatorStyle = 'theme';
      const items = [
        LiquidGlassTabItem(icon: Icon(Icons.folder), label: 'Projects'),
        LiquidGlassTabItem(icon: Icon(Icons.list), label: 'Queue'),
        LiquidGlassTabItem(icon: Icon(Icons.add), label: 'Add'),
      ];
      var selected = 0;
      var intercepted = 0;
      await tester.pumpWidget(
        _host(
          state,
          SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) => AppLiquidTabBar(
                items: items,
                currentIndex: selected,
                onTap: (index) => setState(() => selected = index),
                onTapIntercept: (index) {
                  if (index != 2) return false;
                  intercepted++;
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      expect(find.byType(LiquidGlassTabBar), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('Queue'), findsOneWidget);
      final queue = find.bySemanticsLabel('Queue');
      final target = tester.getRect(find.byKey(const ValueKey('app-tab-1')));
      expect(target.width, greaterThanOrEqualTo(48));
      expect(target.height, greaterThanOrEqualTo(48));
      await tester.tapAt(target.topLeft + const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(queue).flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      tester.semantics.tap(find.semantics.byLabel('Add'));
      await tester.pumpAndSettle();
      expect(intercepted, 1);
      expect(selected, 1);
    },
  );

  testWidgets('mobile tabs keep drag and long-press selection in RTL', (
    tester,
  ) async {
    state.config
      ..navStyle = 'blur'
      ..selectionIndicatorStyle = 'outline';
    var selected = 0;
    await tester.pumpWidget(
      _host(
        state,
        Directionality(
          textDirection: TextDirection.rtl,
          child: SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) => AppLiquidTabBar(
                currentIndex: selected,
                onTap: (index) => setState(() => selected = index),
                items: const [
                  LiquidGlassTabItem(
                    icon: Icon(Icons.folder),
                    label: 'Projects',
                  ),
                  LiquidGlassTabItem(icon: Icon(Icons.list), label: 'Queue'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final first = find.byKey(const ValueKey('app-tab-0'));
    final second = find.byKey(const ValueKey('app-tab-1'));
    expect(
      tester.getCenter(first).dx,
      greaterThan(tester.getCenter(second).dx),
    );
    await tester.dragFrom(
      tester.getCenter(first),
      tester.getCenter(second) - tester.getCenter(first),
    );
    await tester.pumpAndSettle();
    expect(selected, 1);
    final hold = await tester.startGesture(tester.getCenter(second));
    await tester.pump(const Duration(milliseconds: 600));
    await hold.moveTo(tester.getCenter(first));
    await hold.up();
    await tester.pumpAndSettle();
    expect(selected, 0);
    final mask = tester.getRect(
      find.byKey(const ValueKey('app-tab-selection')),
    );
    expect(mask.center.dx, closeTo(tester.getCenter(first).dx, 0.01));
  });

  testWidgets(
    'press feedback and unrelated logs retain the same glass subtree',
    (tester) async {
      await tester.pumpWidget(
        _host(
          state,
          const MobileGlassPill(
            pressable: true,
            child: SizedBox(width: 120, height: 44),
          ),
        ),
      );
      final surface = tester.widget<LiquidGlassBackdrop>(
        find.byType(LiquidGlassBackdrop),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(MobileGlassPill)),
      );
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.widget<LiquidGlassBackdrop>(find.byType(LiquidGlassBackdrop)),
        same(surface),
      );
      state.addLog('Background progress');
      await tester.pump();
      expect(
        tester.widget<LiquidGlassBackdrop>(find.byType(LiquidGlassBackdrop)),
        same(surface),
      );
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'reduced-motion main navigation preserves page mapping and selection',
    (tester) async {
      state.config
        ..navStyle = 'liquid'
        ..selectionIndicatorStyle = 'liquid';
      var page = 0;
      await tester.pumpWidget(
        _host(
          state,
          SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) => LiquidGlassMobileNav(
                selectedIndex: page,
                onSelected: (index) => setState(() => page = index),
              ),
            ),
          ),
          reducedMotion: true,
          highContrast: true,
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      final configs = find.bySemanticsLabel('Configs');
      tester.semantics.tap(find.semantics.byLabel('Configs'));
      await tester.pump();
      expect(page, 2);
      expect(
        tester.getSemantics(configs).flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
