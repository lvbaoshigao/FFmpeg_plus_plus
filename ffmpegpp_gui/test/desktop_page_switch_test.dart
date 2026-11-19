import 'dart:ui' show Tristate;

import 'package:ffmpegpp_gui/app.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _TickingPage extends StatefulWidget {
  const _TickingPage({super.key});
  @override
  State<_TickingPage> createState() => _TickingPageState();
}

class _TickingPageState extends State<_TickingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  int ticks = 0;
  @override
  void initState() {
    super.initState();
    controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(() => ticks++)
          ..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Finder _settingsRow(String section) =>
    find.byKey(ValueKey('settings_section_$section'));

Iterable<TextSpan> _textSpans(InlineSpan span) sync* {
  if (span is! TextSpan) return;
  yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _textSpans(child);
  }
}

String _highlightedText(Text widget) => _textSpans(widget.textSpan!)
    .where((span) => span.style?.backgroundColor != null)
    .map((span) => span.text ?? '')
    .join();

Finder get _settingsSelection =>
    find.byKey(const ValueKey('settings_section_selection'));

Future<void> _pumpDesktopSettings(
  WidgetTester tester, {
  bool disableAnimations = false,
  Size size = const Size(1280, 1100),
  String language = 'en',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState();
  state.config.cardStyle = 'gray';
  state.config.menuStyle = 'gray';
  state.config.language = language;
  addTearDown(state.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: child!,
        ),
        home: const SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('hidden cached slots silence tickers and preserve page State', (
    tester,
  ) async {
    final key = GlobalKey<_TickingPageState>();
    Widget tree(bool active) => MaterialApp(
      home: IndexedStack(
        index: active ? 0 : 1,
        children: [
          CachedPageSlot(
            key: const ValueKey(0),
            active: active,
            child: _TickingPage(key: key),
          ),
          CachedPageSlot(
            key: const ValueKey(1),
            active: !active,
            child: const SizedBox(),
          ),
        ],
      ),
    );
    await tester.pumpWidget(tree(true));
    await tester.pump(const Duration(milliseconds: 50));
    final page = key.currentState!;
    expect(page.ticks, greaterThan(0));
    await tester.pumpWidget(tree(false));
    final hiddenTicks = page.ticks;
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.ticks, hiddenTicks);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(tree(true));
    await tester.pump(const Duration(milliseconds: 50));
    expect(key.currentState, same(page));
    expect(page.ticks, greaterThan(hiddenTicks));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop settings keeps one pane across rapid section switches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.config.cardStyle = 'gray';
    state.config.menuStyle = 'gray';
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    final panes = find.byWidgetPredicate(
      (w) =>
          w is SingleChildScrollView &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('pane_'),
    );
    expect(panes, findsOneWidget);
    for (final section in ['advanced', 'processing', 'general', 'advanced']) {
      final icon = find.byKey(ValueKey('${section}_false')).first;
      await tester.tap(
        find.ancestor(of: icon, matching: find.byType(InkWell)).first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(panes, findsOneWidget);
      expect(find.byKey(ValueKey('pane_$section')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'preload');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(TextButton, Icons.my_location).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pane_advanced')), findsOneWidget);
    expect(panes, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  group('SettingsPage desktop navigation', () {
    testWidgets('should open the shared language dropdown', (tester) async {
      await _pumpDesktopSettings(tester);
      final selector = find.byKey(const ValueKey('settings_language_menu'));
      expect(find.text('简体中文'), findsNothing);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      expect(find.text('简体中文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('should keep row hit testing live while one selection moves', (
      tester,
    ) async {
      await _pumpDesktopSettings(tester);
      final general = _settingsRow('general');
      final advanced = _settingsRow('advanced');
      final generalBounds = tester.getRect(general);
      final advancedBounds = tester.getRect(advanced);
      expect(_settingsSelection, findsOneWidget);
      expect(tester.getRect(_settingsSelection), generalBounds);

      await tester.tap(advanced);
      await tester.pump();
      expect(find.byKey(const ValueKey('pane_advanced')), findsOneWidget);
      expect(find.byKey(const ValueKey('pane_general')), findsNothing);
      expect(tester.getRect(_settingsSelection), generalBounds);
      await tester.pump(const Duration(milliseconds: 40));
      final movingBounds = tester.getRect(_settingsSelection);
      expect(movingBounds.top, greaterThan(generalBounds.top));
      expect(movingBounds.top, lessThan(advancedBounds.top));
      expect(tester.getRect(general), generalBounds);
      expect(tester.getRect(advanced), advancedBounds);

      // The decoration can overlap another row without taking its input.
      await tester.tapAt(generalBounds.center);
      await tester.pump();
      expect(find.byKey(const ValueKey('pane_general')), findsOneWidget);
      expect(find.byKey(const ValueKey('pane_advanced')), findsNothing);
      expect(_settingsSelection, findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.getRect(_settingsSelection), generalBounds);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'should match aliases, fuzzy terms, and highlight result labels',
      (tester) async {
        await _pumpDesktopSettings(tester);
        final search = find.byType(TextField).first;

        await tester.enterText(search, 'GROU');
        await tester.pumpAndSettle();
        final background = tester.widget<Text>(
          find.byKey(const ValueKey('settings-search-result-background')),
        );
        expect(background.textSpan!.toPlainText(), 'Background');
        expect(_highlightedText(background), 'grou');

        await tester.enterText(search, 'wallp');
        await tester.pumpAndSettle();
        final keyword = tester.widget<Text>(
          find.byKey(const ValueKey('settings-search-evidence-background')),
        );
        expect(keyword.textSpan!.toPlainText(), 'wallpaper');
        expect(_highlightedText(keyword), 'wallp');

        await tester.enterText(search, 'autsave');
        await tester.pumpAndSettle();
        final autosave = tester.widget<Text>(
          find.byKey(const ValueKey('settings-search-result-autosave')),
        );
        expect(autosave.textSpan!.toPlainText(), 'Autosave');
        expect(
          _textSpans(autosave.textSpan!)
              .where((span) => span.style?.backgroundColor != null)
              .map((span) => span.text ?? '')
              .join(),
          'Autosave',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('should match Chinese aliases and highlight visible labels', (
      tester,
    ) async {
      await _pumpDesktopSettings(tester, language: 'zh');
      await tester.enterText(find.byType(TextField).first, '壁纸');
      await tester.pumpAndSettle();
      final background = tester.widget<Text>(
        find.byKey(const ValueKey('settings-search-result-background')),
      );
      expect(background.textSpan!.toPlainText(), '背景');
      expect(
        _textSpans(background.textSpan!)
            .where((span) => span.style?.backgroundColor != null)
            .map((span) => span.text ?? '')
            .join(),
        '背景',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('should leave search through the active row and still Locate', (
      tester,
    ) async {
      await _pumpDesktopSettings(tester);
      final search = find.byType(TextField).first;
      await tester.enterText(search, 'preload');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane_general')), findsNothing);
      await tester.tap(_settingsRow('general'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(find.byKey(const ValueKey('pane_general')), findsOneWidget);
      expect(find.widgetWithIcon(TextButton, Icons.my_location), findsNothing);

      await tester.enterText(search, 'preload');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithIcon(TextButton, Icons.my_location).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane_advanced')), findsOneWidget);
      expect(
        tester.getRect(_settingsSelection),
        tester.getRect(_settingsRow('advanced')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'should match scaled hit bounds throughout collapse and search',
      (tester) async {
        await _pumpDesktopSettings(tester);
        final initialHeight = tester.getSize(_settingsRow('general')).height;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pump();
        expect(
          tester.getSize(_settingsRow('general')).height,
          greaterThan(initialHeight),
        );
        expect(
          tester.getRect(_settingsSelection),
          tester.getRect(_settingsRow('general')),
        );
        await tester.enterText(find.byType(TextField).first, 'no-such-setting');
        await tester.pumpAndSettle();
        final rowHeight = tester.getSize(_settingsRow('general')).height;
        await tester.tap(
          find.byKey(const ValueKey('settings_section_nav_toggle')),
        );
        await tester.pump();
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          expect(
            tester.getRect(_settingsSelection),
            tester.getRect(_settingsRow('general')),
          );
          expect(tester.getSize(_settingsRow('general')).height, rowHeight);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(_settingsRow('general'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('pane_general')), findsOneWidget);
        expect(tester.getSize(_settingsRow('general')).height, rowHeight);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('should honor reduced motion, keyboard and compact resizing', (
      tester,
    ) async {
      await _pumpDesktopSettings(
        tester,
        disableAnimations: true,
        size: const Size(1280, 400),
      );
      final advanced = _settingsRow('advanced');
      // InkWell leaves Focus.focusNode null when Focus owns the node itself.
      final focus = Focus.of(
        tester.element(
          find.descendant(of: advanced, matching: find.byType(Icon)).first,
        ),
      );
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      final pane = find.byKey(const ValueKey('pane_advanced'));
      expect(pane, findsOneWidget);
      expect(tester.getRect(_settingsSelection), tester.getRect(advanced));
      expect(
        tester.getSemantics(advanced).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      final paneElement = tester.element(pane);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: pane, matching: find.byType(Scrollable)).first,
      );
      // Track a real, in-range scroll offset instead of transient overscroll.
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      final offset = scrollable.position.maxScrollExtent / 2;
      scrollable.position.jumpTo(offset);
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, closeTo(offset, 0.01));
      for (final width in [620.0, 1280.0, 620.0]) {
        tester.view.physicalSize = Size(width, 400);
        await tester.pumpAndSettle();
        expect(tester.element(pane), same(paneElement));
        expect(
          scrollable.position.maxScrollExtent,
          greaterThanOrEqualTo(offset),
        );
        expect(scrollable.position.pixels, closeTo(offset, 0.01));
        expect(_settingsSelection, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await Scrollable.ensureVisible(
        tester.element(_settingsRow('processing')),
      );
      await tester.tap(_settingsRow('processing'));
      await tester.pump();
      expect(find.byKey(const ValueKey('pane_processing')), findsOneWidget);
      expect(pane, findsNothing);
      expect(
        tester.getRect(_settingsSelection),
        tester.getRect(_settingsRow('processing')),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
