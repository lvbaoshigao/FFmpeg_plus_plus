import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as lgw;

void main() {
  tearDown(resetDesktopGlassForTesting);

  testWidgets(
    'real asset initialization mounts shader or safe degraded fallback',
    (tester) async {
      final ready = await tester.runAsync(initializeDesktopGlass) ?? false;
      await tester.pumpWidget(
        MaterialApp(
          home: LiquidGlassBackdrop(
            borderRadius: BorderRadius.circular(18),
            child: const SizedBox(width: 120, height: 44),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byType(lgw.LightweightLiquidGlass),
        ready ? findsOneWidget : findsNothing,
      );
      if (!ready) expect(find.byType(BackdropFilter), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('uninitialized desktop glass stays on safe fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LiquidGlassBackdrop(
          borderRadius: BorderRadius.circular(18),
          child: const SizedBox(width: 120, height: 44),
        ),
      ),
    );
    expect(find.byType(lgw.LightweightLiquidGlass), findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('failed loader is contained and initialized only once', () async {
    var calls = 0;
    resetDesktopGlassForTesting(
      loader: () async {
        calls++;
        throw StateError('shader unavailable');
      },
    );
    expect(await initializeDesktopGlass(), isFalse);
    expect(await initializeDesktopGlass(), isFalse);
    expect(calls, 1);
  });

  testWidgets(
    'ready desktop shell constructs standard shader without capture or duplicate tint',
    (tester) async {
      resetDesktopGlassForTesting(loader: () async => true);
      expect(await initializeDesktopGlass(), isTrue);
      Widget? surface;
      const content = SizedBox(width: 120, height: 44);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              // Inspect composition without mounting the native shader in flutter_tester.
              surface = LiquidGlassBackdrop(
                borderRadius: BorderRadius.circular(18),
                tuning: const GlassTuning(
                  blur: 30,
                  highlight: 1.2,
                  lightPos: 0.5,
                  edge: 1.5,
                ),
                opacity: 0.7,
                child: content,
              ).build(context);
              return content;
            },
          ),
        ),
      );
      final clip = surface as ClipRRect;
      final glass = clip.child as lgw.LightweightLiquidGlass;
      expect(glass.backgroundKey, isNull);
      expect(glass.settings!.blur, 8);
      expect(glass.settings!.glassColor.a, 0);
      expect(glass.settings!.lightAngle, closeTo(3.141592653589793, 0.00001));
      expect(glass.settings!.rimLight, closeTo(1.05, 0.00001));
      expect(glass.child, same(content));
      expect(clip.borderRadius, BorderRadius.circular(18));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nonuniform corners retain exact legacy clipping', (
    tester,
  ) async {
    resetDesktopGlassForTesting(loader: () async => true);
    await initializeDesktopGlass();
    const corners = BorderRadius.only(
      topLeft: Radius.circular(12),
      bottomRight: Radius.elliptical(8, 4),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: LiquidGlassBackdrop(
          borderRadius: corners,
          child: SizedBox(width: 120, height: 44),
        ),
      ),
    );
    expect(find.byType(lgw.LightweightLiquidGlass), findsNothing);
    expect(
      tester.widget<ClipRRect>(find.byType(ClipRRect)).borderRadius,
      corners,
    );
    expect(tester.takeException(), isNull);
  });
}
