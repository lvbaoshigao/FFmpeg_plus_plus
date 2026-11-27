import 'dart:ui' show Tristate;

import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/theme/mobile_ui.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_mobile_nav.dart';
import 'package:ffmpegpp_gui/widgets/mobile_bottom_nav.dart';
import 'package:ffmpegpp_gui/widgets/selection_highlight.dart';
import 'package:ffmpegpp_gui/widgets/tabler_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_tab_bar/liquid_glass_tab_bar.dart';
import 'package:provider/provider.dart';

AppState _state(String indicator, {String shell = 'gray'}) {
  final state = AppState();
  state.config
    ..language = 'en'
    ..navStyle = shell
    ..selectionIndicatorStyle = indicator;
  addTearDown(state.dispose);
  return state;
}

Future<void> _mount(
  WidgetTester tester,
  AppState state,
  Widget child, {
  bool reducedMotion = true,
  bool highContrast = false,
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reducedMotion,
            highContrast: highContrast,
            textScaler: TextScaler.linear(textScale),
            padding: padding,
          ),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool _hasLocalBoundary(WidgetTester tester, Finder mask, Type owner) {
  var found = false;
  tester.element(mask).visitAncestorElements((element) {
    if (element.widget.runtimeType == owner) return false;
    found |= element.widget is RepaintBoundary;
    return true;
  });
  return found;
}

void _expectMaterial(WidgetTester tester, Finder mask, String style) {
  if (style == 'liquid' || style == 'blur') {
    expect(
      find.descendant(of: mask, matching: find.byType(BackdropFilter)),
      findsWidgets,
    );
  } else {
    final surface =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(of: mask, matching: find.byType(DecoratedBox))
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(surface.color, style == 'theme' ? isNotNull : isNull);
    expect(surface.border, style == 'outline' ? isNotNull : isNull);
  }
}

const _items = [
  LiquidGlassTabItem(
    icon: TablerIcon(TablerGlyph.movie),
    label: 'Projects',
    semanticLabel: 'Projects tab',
  ),
  LiquidGlassTabItem(
    icon: TablerIcon(TablerGlyph.listDetails),
    label: 'Queue',
    semanticLabel: 'Queue tab',
  ),
  LiquidGlassTabItem(
    icon: TablerIcon(TablerGlyph.settings),
    label: 'Actions',
    semanticLabel: 'Actions tab',
  ),
];

void main() {
  testWidgets('scaled mobile list keeps its last row above the nav', (
    tester,
  ) async {
    final previousMobile = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = true;
    addTearDown(() => debugIsMobilePlatformOverride = previousMobile);
    final state = _state('liquid', shell: 'gray');
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    late double clearance;
    late double barClearance;
    await _mount(
      tester,
      state,
      Builder(
        builder: (context) {
          clearance = MobileUi.mainListPadding(context: context).bottom;
          barClearance = AppLiquidTabBar.clearanceOf(context);
          return Stack(
            children: [
              ListView(
                controller: scroll,
                padding: MobileUi.mainListPadding(context: context),
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(
                      key: ValueKey('clearance-row-$i'),
                      height: 80,
                      child: Text('Row $i'),
                    ),
                ],
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LiquidGlassMobileNav(
                  selectedIndex: 0,
                  onSelected: (_) {},
                ),
              ),
            ],
          );
        },
      ),
      textScale: 2,
      padding: const EdgeInsets.only(bottom: 34),
    );
    expect(clearance, closeTo(117.2, 0.01));
    expect(clearance, closeTo(barClearance, 0.01));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    final lastRow = tester.getRect(
      find.byKey(const ValueKey('clearance-row-19')),
    );
    final nav = tester.getRect(find.byType(LiquidGlassMobileNav));
    expect(lastRow.bottom, lessThanOrEqualTo(nav.top + 0.01));
    expect(tester.takeException(), isNull);
  });

  group('MobileNavRail selection highlight', () {
    for (final style in ['theme', 'liquid', 'blur', 'outline']) {
      testWidgets(
        'should use $style while preserving rail selection and dragging',
        (tester) async {
          final state = _state(style);
          final selections = <int>[];
          var selected = 0;
          await _mount(
            tester,
            state,
            Align(
              alignment: Alignment.centerLeft,
              child: StatefulBuilder(
                builder: (context, setState) => MobileNavRail(
                  placement: MobileNavPlacement.left,
                  selectedIndex: selected,
                  onSelected: (index) {
                    setState(() => selected = index);
                    selections.add(index);
                  },
                ),
              ),
            ),
          );
          final mask = find.byType(SelectionHighlight);
          expect(mask, findsOneWidget);
          _expectMaterial(tester, mask, style);
          expect(_hasLocalBoundary(tester, mask, MobileNavRail), isFalse);
          final first = find.byKey(const ValueKey('mobile-rail-item-0'));
          final last = find.byKey(const ValueKey('mobile-rail-item-3'));
          await tester.dragFrom(
            tester.getCenter(first),
            tester.getCenter(last) - tester.getCenter(first),
          );
          await tester.pumpAndSettle();
          expect(selections.last, 3);
          expect(
            tester.getSemantics(last).flagsCollection.isSelected,
            Tristate.isTrue,
          );
          final positioned = find.descendant(
            of: find.byType(MobileNavRail),
            matching: find.byType(AnimatedPositioned),
          );
          expect(
            tester.widget<AnimatedPositioned>(positioned).duration,
            Duration.zero,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('should keep the mask following PageController movement', (
      tester,
    ) async {
      final state = _state('blur');
      final controller = PageController();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        state,
        Stack(
          children: [
            PageView(
              controller: controller,
              children: const [SizedBox(), SizedBox(), SizedBox(), SizedBox()],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: MobileNavRail(
                placement: MobileNavPlacement.left,
                selectedIndex: 0,
                pageController: controller,
                onSelected: (_) {},
              ),
            ),
          ],
        ),
      );
      final mask = find.byType(SelectionHighlight);
      final initialTop = tester.getTopLeft(mask).dy;
      final movement = controller.animateToPage(
        2,
        duration: const Duration(milliseconds: 400),
        curve: Curves.linear,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getTopLeft(mask).dy, greaterThan(initialTop + 20));
      await tester.pumpAndSettle();
      await movement;
      expect(tester.takeException(), isNull);
    });
  });

  group('LiquidGlassMobileNav flat selection', () {
    for (final style in ['theme', 'liquid', 'blur', 'outline']) {
      testWidgets(
        'should use $style without changing main navigation indices',
        (tester) async {
          final state = _state(style);
          var selected = 0;
          final selections = <int>[];
          await _mount(
            tester,
            state,
            Align(
              alignment: Alignment.bottomCenter,
              child: StatefulBuilder(
                builder: (context, setState) => LiquidGlassMobileNav(
                  selectedIndex: selected,
                  onSelected: (index) {
                    setState(() => selected = index);
                    selections.add(index);
                  },
                ),
              ),
            ),
          );
          final mask = find.byKey(const ValueKey('flat-nav-selection'));
          _expectMaterial(tester, mask, style);
          await tester.tap(find.byKey(const ValueKey('flat-nav-item-2')));
          await tester.pumpAndSettle();
          expect(selections, [2]);
          expect(
            tester
                .getSemantics(find.byKey(const ValueKey('flat-nav-item-2')))
                .flagsCollection
                .isSelected,
            Tristate.isTrue,
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('flat-nav-item-2')))
                .height,
            52,
          );
          expect(
            _hasLocalBoundary(tester, mask, LiquidGlassMobileNav),
            isFalse,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('AppLiquidTabBar configurable indicator', () {
    for (final style in ['theme', 'blur', 'outline']) {
      testWidgets(
        'should preserve callbacks interception and gestures in $style',
        (tester) async {
          final state = _state(style, shell: 'blur');
          final selections = <int>[];
          final intercepted = <int>[];
          var selected = 0;
          await _mount(
            tester,
            state,
            Align(
              alignment: Alignment.bottomCenter,
              child: StatefulBuilder(
                builder: (context, setState) => AppLiquidTabBar(
                  currentIndex: selected,
                  onTap: (index) {
                    setState(() => selected = index);
                    selections.add(index);
                  },
                  onTapIntercept: (index) {
                    if (index != 2) return false;
                    intercepted.add(index);
                    return true;
                  },
                  items: _items,
                ),
              ),
            ),
          );
          final mask = find.byKey(const ValueKey('app-tab-selection'));
          expect(mask, findsOneWidget);
          expect(find.byType(NavGlassShell), findsOneWidget);
          expect(find.byType(LiquidGlassTabBar), findsNothing);
          expect(find.text('Projects'), findsNWidgets(2));
          final first = find.byKey(const ValueKey('app-tab-0'));
          final second = find.byKey(const ValueKey('app-tab-1'));
          final action = find.byKey(const ValueKey('app-tab-2'));
          final initial = tester.getRect(mask);
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(intercepted, [2]);
          expect(selections, isEmpty);
          expect(tester.getRect(mask), initial);
          await tester.dragFrom(
            tester.getCenter(first),
            tester.getCenter(second) - tester.getCenter(first),
          );
          await tester.pumpAndSettle();
          expect(selections, [1]);
          expect(
            tester.getSemantics(second).flagsCollection.isSelected,
            Tristate.isTrue,
          );
          final hold = await tester.startGesture(tester.getCenter(second));
          await tester.pump(const Duration(milliseconds: 600));
          await hold.moveTo(tester.getCenter(first));
          await hold.up();
          await tester.pumpAndSettle();
          expect(selections.last, 0);
          expect(_hasLocalBoundary(tester, mask, AppLiquidTabBar), isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('should keep exact hosted geometry and explicit icon colors', (
      tester,
    ) async {
      final state = _state('outline');
      const style = LiquidGlassTabBarStyle(
        capsuleHeight: 48,
        capsuleInset: 5,
        capsuleOverhang: 7,
        horizontalMargin: 18,
        bottomGap: 11,
        iconSize: 20,
      );
      await _mount(
        tester,
        state,
        Align(
          alignment: Alignment.bottomCenter,
          child: AppLiquidTabBar(
            currentIndex: 0,
            onTap: (_) {},
            style: style,
            selectedColor: Colors.amber,
            unselectedColor: Colors.cyan,
            items: _items,
          ),
        ),
        padding: const EdgeInsets.only(bottom: 20),
        textScale: 2,
      );
      expect(tester.getSize(find.byType(AppLiquidTabBar)).height, 95);
      final mask = find.byKey(const ValueKey('app-tab-selection'));
      expect(tester.getSize(mask).height, 48);
      expect(
        tester.getSize(mask).width,
        closeTo((400 - 36 - 24) / 3 + 14, 0.01),
      );
      final icons = find.descendant(
        of: find.byType(AppLiquidTabBar),
        matching: find.byType(TablerIcon),
      );
      expect(IconTheme.of(tester.element(icons.first)).color, Colors.cyan);
      expect(IconTheme.of(tester.element(icons.last)).color, Colors.amber);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'should keep semantic and keyboard activation in high contrast',
      (tester) async {
        final state = _state('liquid');
        final selections = <int>[];
        var selected = 0;
        await _mount(
          tester,
          state,
          Align(
            alignment: Alignment.bottomCenter,
            child: StatefulBuilder(
              builder: (context, setState) => AppLiquidTabBar(
                currentIndex: selected,
                onTap: (index) {
                  setState(() => selected = index);
                  selections.add(index);
                },
                items: _items,
              ),
            ),
          ),
          highContrast: true,
        );
        expect(find.byType(LiquidGlassTabBar), findsNothing);
        tester.semantics.tap(find.semantics.byLabel('Queue tab'));
        await tester.pumpAndSettle();
        expect(selections, [1]);
        final mask = find.byKey(const ValueKey('app-tab-selection'));
        final surface =
            tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: mask,
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration;
        expect((surface.border! as Border).top.width, 2);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(selections, [1, 0]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('should retain the hosted bar only for regular liquid mode', (
      tester,
    ) async {
      final state = _state('liquid');
      await _mount(
        tester,
        state,
        Align(
          alignment: Alignment.bottomCenter,
          child: AppLiquidTabBar(currentIndex: 0, onTap: (_) {}, items: _items),
        ),
        reducedMotion: false,
      );
      expect(find.byType(LiquidGlassTabBar), findsOneWidget);
      expect(find.byKey(const ValueKey('app-tab-selection')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'should react to indicator changes without rebuilding for logs',
      (tester) async {
        final state = _state('theme');
        var builds = 0;
        var selected = 0;
        var label = 'Projects';
        late StateSetter setHostState;
        List<LiquidGlassTabItem> items() => [
          LiquidGlassTabItem.builder(
            label: label,
            iconBuilder: (color) {
              builds++;
              return Icon(Icons.movie_outlined, color: color);
            },
          ),
          _items[1],
        ];
        await _mount(
          tester,
          state,
          StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return Align(
                alignment: Alignment.bottomCenter,
                child: AppLiquidTabBar(
                  currentIndex: selected,
                  onTap: (index) => setState(() => selected = index),
                  items: items(),
                ),
              );
            },
          ),
        );
        final before = builds;
        final dragSurface = find
            .byKey(const ValueKey('app-tab-drag-surface'))
            .hitTestable();
        expect(dragSurface, findsOneWidget);
        final navRect = tester.getRect(dragSurface);
        final firstCenter = Offset(
          navRect.left + navRect.width / 4,
          navRect.center.dy,
        );
        final gesture = await tester.startGesture(firstCenter);
        final delta = Offset(navRect.width / 2 / 32, 0);
        for (var frame = 0; frame < 32; frame++) {
          await gesture.moveBy(delta);
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(builds, before, reason: 'drag frames only move the indicator');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(selected, 1);
        expect(
          builds,
          greaterThan(before),
          reason: 'committed selection rebuilds item colors',
        );
        setHostState(() => label = 'Workspaces');
        await tester.pumpAndSettle();
        expect(find.text('Workspaces'), findsNWidgets(2));
        expect(
          builds,
          greaterThan(before),
          reason: 'updated labels rebuild the static tab row',
        );
        final afterLabelUpdate = builds;
        state.addLog('Background progress');
        await tester.pump(const Duration(milliseconds: 200));
        expect(builds, afterLabelUpdate);
        await state.updateConfig(
          (config) => config..selectionIndicatorStyle = 'outline',
        );
        await tester.pumpAndSettle();
        final mask = find.byKey(const ValueKey('app-tab-selection'));
        expect(tester.widget<SelectionHighlight>(mask).style, 'outline');
        _expectMaterial(tester, mask, 'outline');
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
