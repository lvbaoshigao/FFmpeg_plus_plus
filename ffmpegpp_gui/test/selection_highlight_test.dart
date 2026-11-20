import 'dart:ui' show Tristate;

import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/desktop_resize_scope.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_fallback.dart';
import 'package:ffmpegpp_gui/widgets/selection_highlight.dart';
import 'package:ffmpegpp_gui/widgets/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _State extends AppState {
  void changed() => notifyListeners();
}

Widget _host(
  Widget child, {
  AppState? state,
  Brightness brightness = Brightness.dark,
  Color seed = Colors.blue,
  bool highContrast = false,
  bool reducedMotion = false,
}) {
  final host = MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
      ),
    ),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(800, 600),
        highContrast: highContrast,
        disableAnimations: reducedMotion,
      ),
      child: Scaffold(body: child),
    ),
  );
  return state == null
      ? host
      : ChangeNotifierProvider<AppState>.value(value: state, child: host);
}

const _highlightKey = ValueKey('test_highlight');

Widget _sample({String? style, double radius = 12}) => Center(
  child: SizedBox(
    width: 160,
    height: 40,
    child: SelectionHighlight(key: _highlightKey, style: style, radius: radius),
  ),
);

Finder get _highlight => find.byKey(_highlightKey);

BoxDecoration _decoration(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find
                  .descendant(
                    of: _highlight,
                    matching: find.byType(DecoratedBox),
                  )
                  .first,
            )
            .decoration
        as BoxDecoration;

void _expectNeutral(Color color) {
  expect(color.r, closeTo(color.g, 0.00001));
  expect(color.g, closeTo(color.b, 0.00001));
}

void main() {
  setUp(resetDesktopGlassForTesting);
  tearDown(resetDesktopGlassForTesting);

  group('SelectionHighlight', () {
    testWidgets('should use the active theme without an AppState provider', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_sample(radius: 9)));
      final originalElement = tester.element(_highlight);
      var scheme = Theme.of(tester.element(_highlight)).colorScheme;
      final first = _decoration(tester).color;
      expect(first, scheme.secondaryContainer.withAlpha(200));
      expect(_decoration(tester).borderRadius, BorderRadius.circular(9));
      expect(tester.getSize(_highlight), const Size(160, 40));
      expect(find.byType(BackdropFilter), findsNothing);

      await tester.pumpWidget(
        _host(
          _sample(radius: 9),
          brightness: Brightness.light,
          seed: Colors.orange,
        ),
      );
      await tester.pumpAndSettle();
      scheme = Theme.of(tester.element(_highlight)).colorScheme;
      expect(
        _decoration(tester).color,
        scheme.secondaryContainer.withAlpha(200),
      );
      expect(_decoration(tester).color, isNot(first));
      expect(tester.element(_highlight), same(originalElement));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'should let taps reach controls beneath its decorative surface',
      (tester) async {
        var tapped = 0;
        await tester.pumpWidget(
          _host(
            Center(
              child: SizedBox(
                width: 160,
                height: 40,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    TextButton(
                      key: const ValueKey('underlying_control'),
                      onPressed: () => tapped++,
                      child: const Text('Open'),
                    ),
                    const SelectionHighlight(style: 'blur'),
                  ],
                ),
              ),
            ),
          ),
        );
        final highlight = find.byType(SelectionHighlight);
        expect(
          find.descendant(
            of: highlight,
            matching: find.byType(ExcludeSemantics),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('underlying_control')));
        await tester.pump();
        expect(tapped, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'should update configured styles while honoring a local override',
      (tester) async {
        final state = _State();
        addTearDown(state.dispose);
        state.config.selectionIndicatorStyle = 'theme';
        await tester.pumpWidget(_host(_sample(), state: state));
        expect(find.byType(BackdropFilter), findsNothing);
        state.config.selectionIndicatorStyle = 'blur';
        state.changed();
        await tester.pump();
        expect(find.byType(BackdropFilter), findsOneWidget);
        final body = _decoration(tester);
        _expectNeutral(body.color!);
        _expectNeutral((body.border! as Border).top.color);
        expect((body.border! as Border).top.width, greaterThan(0));

        state.config.selectionIndicatorStyle = 'outline';
        state.changed();
        await tester.pump();
        expect(find.byType(BackdropFilter), findsNothing);
        expect(_decoration(tester).color, isNull);
        expect((_decoration(tester).border! as Border).top.width, 1.5);

        await tester.pumpWidget(_host(_sample(style: 'blur'), state: state));
        await tester.pump();
        expect(find.byType(BackdropFilter), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final style in ['liquid', 'blur']) {
      testWidgets('should keep $style neutral and respond to glass tuning', (
        tester,
      ) async {
        final state = _State();
        addTearDown(state.dispose);
        state.config.glassFollowTheme = true;
        state.config.useThemeColor = true;
        state.config.glassClarity = 0;
        await tester.pumpWidget(
          _host(
            _sample(style: style),
            state: state,
            seed: Colors.deepOrange,
          ),
        );
        final firstColor = _decoration(tester).color!;
        _expectNeutral(firstColor);
        state.config.glassClarity = 1;
        state.config.glassEdge = 0;
        state.config.cardOpacity = 0;
        state.changed();
        await tester.pump();
        expect(_decoration(tester).color!.a, lessThan(firstColor.a));
        expect(
          (_decoration(tester).border! as Border).top.color.a,
          greaterThan(0),
        );
        // A root view may have repaint boundaries, but the backdrop must not.
        final localBoundaries = find.descendant(
          of: _highlight,
          matching: find.byType(RepaintBoundary),
        );
        expect(localBoundaries, findsNothing);
        expect(
          find.descendant(of: _highlight, matching: find.byType(Opacity)),
          findsNothing,
        );
        await tester.pumpWidget(
          _host(
            _sample(style: style),
            state: state,
            brightness: Brightness.light,
            seed: Colors.green,
          ),
        );
        await tester.pumpAndSettle();
        _expectNeutral(_decoration(tester).color!);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets(
        'should render $style without a provider or initialized shader',
        (tester) async {
          await tester.pumpWidget(_host(_sample(style: style)));
          expect(find.byType(BackdropFilter), findsOneWidget);
          _expectNeutral(_decoration(tester).color!);
          expect(
            (_decoration(tester).border! as Border).top.color.a,
            greaterThan(0),
          );
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'should suspend $style filtering during desktop resizing',
        (tester) async {
          tester.view.physicalSize = const Size(800, 600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            _host(DesktopResizeScope(child: _sample(style: style))),
          );
          final element = tester.element(_highlight);
          expect(
            tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
            isTrue,
          );
          tester.view.physicalSize = const Size(900, 650);
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            tester
                .widgetList<BackdropFilter>(find.byType(BackdropFilter))
                .every((filter) => !filter.enabled),
            isTrue,
          );
          expect(tester.element(_highlight), same(element));
          await tester.pump(const Duration(milliseconds: 60));
          expect(
            tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        skip: !isDesktopPlatform,
      );
    }

    testWidgets('should retain a solid selection boundary in high contrast', (
      tester,
    ) async {
      for (final style in ['theme', 'liquid', 'blur', 'outline']) {
        await tester.pumpWidget(
          _host(_sample(style: style), highContrast: true),
        );
        final scheme = Theme.of(tester.element(_highlight)).colorScheme;
        final border = _decoration(tester).border! as Border;
        expect(border.top.color, scheme.onSurface);
        expect(border.top.width, 2);
        expect(_decoration(tester).color!.a, 1);
        expect(find.byType(BackdropFilter), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('Sidebar selection', () {
    for (final style in ['liquid', 'outline']) {
      testWidgets(
        'should keep row taps live beneath a moving $style highlight',
        (tester) async {
          final state = _State();
          state.config.language = 'en';
          state.config.menuStyle = 'gray';
          state.config.selectionIndicatorStyle = style;
          addTearDown(state.dispose);
          var selected = 0;
          await tester.pumpWidget(
            _host(
              StatefulBuilder(
                builder: (context, setState) => Align(
                  alignment: Alignment.topLeft,
                  child: Sidebar(
                    selectedIndex: selected,
                    onSelected: (value) => setState(() => selected = value),
                  ),
                ),
              ),
              state: state,
            ),
          );
          await tester.pumpAndSettle();
          final highlight = find.byKey(const ValueKey('sidebar_selection'));
          final element = tester.element(highlight);
          final boundaries = find.descendant(
            of: find.byType(Sidebar),
            matching: find.byType(RepaintBoundary),
          );
          for (final boundary in boundaries.evaluate()) {
            expect(
              find.descendant(
                of: find.byWidget(boundary.widget),
                matching: highlight,
              ),
              findsNothing,
            );
          }
          Finder row(int index) => find.byKey(ValueKey('sidebar_nav_$index'));
          final initialTop = tester.getTopLeft(highlight).dy;
          await tester.tap(row(2));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final movingTop = tester.getTopLeft(highlight).dy;
          expect(movingTop, greaterThan(initialTop));
          expect(movingTop, lessThan(tester.getTopLeft(row(2)).dy));
          await tester.tap(row(4));
          await tester.pumpAndSettle();
          expect(selected, 4);
          expect(tester.element(highlight), same(element));
          expect(tester.getTopLeft(highlight).dy, tester.getTopLeft(row(4)).dy);
          expect(
            tester.getSemantics(row(4)).flagsCollection.isSelected,
            Tristate.isTrue,
          );
          expect(
            tester.getSemantics(row(2)).flagsCollection.isSelected,
            Tristate.isFalse,
          );
          await tester.tap(find.text('FFmpeg++'));
          await tester.pumpAndSettle();
          expect(tester.getSize(find.byType(Sidebar)).width, 72);
          await tester.tap(row(1));
          await tester.pumpAndSettle();
          expect(selected, 1);
          expect(tester.getSize(highlight).height, 40);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets('should keep drag selection and honor reduced motion', (
      tester,
    ) async {
      final state = _State();
      state.config.menuStyle = 'gray';
      state.config.selectionIndicatorStyle = 'blur';
      addTearDown(state.dispose);
      var selected = 0;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.topLeft,
              child: Sidebar(
                selectedIndex: selected,
                onSelected: (value) => setState(() => selected = value),
              ),
            ),
          ),
          state: state,
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      final position = find.byKey(const ValueKey('sidebar_selection_position'));
      expect(
        tester.widget<AnimatedPositioned>(position).duration,
        Duration.zero,
      );
      final firstRow = find.byKey(const ValueKey('sidebar_nav_0'));
      await tester.dragFrom(tester.getCenter(firstRow), const Offset(0, 80));
      await tester.pumpAndSettle();
      expect(selected, greaterThan(0));
      final highlight = find.byKey(const ValueKey('sidebar_selection'));
      final selectedRow = find.byKey(ValueKey('sidebar_nav_$selected'));
      expect(
        tester.getTopLeft(highlight).dy,
        tester.getTopLeft(selectedRow).dy,
      );
      await tester.tap(find.text('FFmpeg++'));
      await tester.pump();
      expect(tester.getSize(find.byType(Sidebar)).width, 72);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
