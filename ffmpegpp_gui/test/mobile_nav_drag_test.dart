import 'dart:ui' show Tristate;

import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/mobile_bottom_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Finder _railItem(int index) => find.byKey(ValueKey('mobile-rail-item-$index'));

Future<void> _pumpLandscapeRail(
  WidgetTester tester, {
  required ValueChanged<int> onSelected,
}) async {
  tester.view.physicalSize = const Size(568, 320);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState();
  state.config
    ..navStyle = 'gray'
    ..language = 'en';
  addTearDown(state.dispose);
  var selected = 0;
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: true, highContrast: true),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: StatefulBuilder(
              builder: (context, setState) => MobileNavRail(
                selectedIndex: selected,
                placement: MobileNavPlacement.left,
                onSelected: (index) {
                  setState(() => selected = index);
                  onSelected(index);
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dragging nav rail from first to last item selects last item', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(120, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.updateConfig((c) => c..navStyle = 'gray');
    var selected = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerLeft,
              child: MobileNavRail(
                selectedIndex: 0,
                onSelected: (index) => selected = index,
                placement: MobileNavPlacement.left,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byType(MobileNavRail));
    final start = Offset(bounds.center.dx, bounds.top + 30);
    final end = Offset(bounds.center.dx, bounds.bottom - 30);
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(end, timeStamp: const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 4);
    await tester.pump(const Duration(seconds: 1));
  });

  group('MobileNavRail accessibility', () {
    testWidgets('compacts then scrolls when the landscape IME opens', (
      tester,
    ) async {
      final selections = <int>[];
      await _pumpLandscapeRail(tester, onSelected: selections.add);
      final rail = find.byType(MobileNavRail);
      final railElement = tester.element(rail);
      final scroll = find.descendant(
        of: rail,
        matching: find.byType(SingleChildScrollView),
      );
      expect(tester.getSize(_railItem(4)).height, 54);

      tester.view.viewInsets = const FakeViewPadding(bottom: 85);
      await tester.pumpAndSettle();
      expect(tester.element(rail), same(railElement));
      expect(tester.getSize(_railItem(4)).height, inExclusiveRange(44, 54));
      expect(_railItem(4).hitTestable(), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 140);
      await tester.pumpAndSettle();
      expect(tester.element(rail), same(railElement));
      for (final index in [0, 1, 3, 4]) {
        expect(tester.getSize(_railItem(index)).height, 44);
      }
      expect(_railItem(4).hitTestable(), findsNothing);
      await tester.drag(scroll, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(selections, isEmpty);
      expect(_railItem(4).hitTestable(), findsOneWidget);
      await tester.tap(_railItem(4));
      await tester.pump();
      expect(selections, [4]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('activates named destinations through semantics and keyboard', (
      tester,
    ) async {
      final manager = FocusManager.instance;
      final previousStrategy = manager.highlightStrategy;
      manager.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => manager.highlightStrategy = previousStrategy);

      final selections = <int>[];
      await _pumpLandscapeRail(tester, onSelected: selections.add);
      tester.semantics.tap(find.semantics.byLabel('Queue'));
      await tester.pump();
      expect(selections, [1]);
      expect(
        tester.getSemantics(_railItem(1)).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      final mask = find.descendant(
        of: find.byType(MobileNavRail),
        matching: find.byType(AnimatedPositioned),
      );
      expect(tester.widget<AnimatedPositioned>(mask).duration, Duration.zero);

      tester.view.viewInsets = const FakeViewPadding(bottom: 140);
      await tester.pumpAndSettle();
      final ring = find.byKey(const ValueKey('mobile-rail-focus-ring'));
      for (final index in [0, 1, 3, 4]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: _railItem(index), matching: ring),
          findsOneWidget,
        );
      }
      final border =
          tester.widget<DecoratedBox>(ring).decoration as BoxDecoration;
      expect((border.border! as Border).top.width, 3);
      expect(_railItem(4).hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selections, [1, 4]);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(selections, [1, 4, 4]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
