import 'dart:ui' show Tristate;

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_press_feedback.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/liquid_modality_pills.dart';
import 'package:ffmpegpp_gui/widgets/mobile_top_bar.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:ffmpegpp_gui/widgets/selection_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _State extends AppState {
  void setSelectionStyle(String style) {
    config.selectionIndicatorStyle = style;
    notifyListeners();
  }
}

// Record native InkWell input, then delegate to the real themed feedback.
class _PressTracker extends InteractiveInkFeatureFactory {
  _PressTracker(this.delegate);

  InteractiveInkFeatureFactory delegate;
  final colors = <Color>[];
  final contained = <bool>[];

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    colors.add(color);
    contained.add(containedInkWell);
    return delegate.create(
      controller: controller,
      referenceBox: referenceBox,
      position: position,
      color: color,
      textDirection: textDirection,
      containedInkWell: containedInkWell,
      rectCallback: rectCallback,
      borderRadius: borderRadius,
      customBorder: customBorder,
      radius: radius,
      onRemoved: onRemoved,
    );
  }
}

Widget _host(_State state, _PressTracker tracker, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: AppPressTheme(
            child: Builder(
              builder: (context) {
                final theme = Theme.of(context);
                tracker.delegate = theme.splashFactory;
                return Theme(
                  data: theme.copyWith(splashFactory: tracker),
                  child: child!,
                );
              },
            ),
          ),
        ),
        home: Scaffold(body: Center(child: child)),
      ),
    );

Future<void> _press(
  WidgetTester tester,
  Finder target,
  _PressTracker tracker,
) async {
  final previous = tracker.colors.length;
  final gesture = await tester.startGesture(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 120));
  expect(tracker.colors.length, previous + 1);
  expect(tracker.colors.last.a, greaterThan(0));
  expect(tracker.contained.last, isTrue);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('Custom menu feedback', () {
    late _State state;
    late _PressTracker tracker;

    setUp(() {
      state = _State();
      state.config
        ..cardStyle = 'gray'
        ..pillStyle = 'gray'
        ..glassEffect = 'none'
        ..language = 'en';
      tracker = _PressTracker(AppTheme.light().splashFactory);
    });
    tearDown(() => state.dispose());

    testWidgets('should preserve inline selection and keyboard activation', (
      tester,
    ) async {
      var selected = 0;
      await tester.pumpWidget(
        _host(
          state,
          tracker,
          StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 300,
              child: OptionMenuBar<int>(
                expandable: false,
                value: selected,
                items: const [OptionItem(0, 'Alpha'), OptionItem(1, 'Beta')],
                onChanged: (value) => setState(() => selected = value),
              ),
            ),
          ),
        ),
      );
      final menuState = tester.state(find.byType(OptionMenuBar<int>));
      final betaInk = find
          .ancestor(of: find.text('Beta'), matching: find.byType(InkWell))
          .first;
      final inkElement = tester.element(betaInk);
      expect(tester.getSize(betaInk).width, greaterThan(100));
      for (final style in ['theme', 'liquid', 'blur', 'outline']) {
        state.setSelectionStyle(style);
        await tester.pumpAndSettle();
        expect(find.byType(SelectionHighlight), findsOneWidget);
        expect(tester.state(find.byType(OptionMenuBar<int>)), same(menuState));
        expect(tester.element(betaInk), same(inkElement));
      }
      await _press(tester, find.text('Beta'), tracker);
      expect(selected, 1);
      expect(
        tester.getSemantics(find.text('Beta')).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      Focus.of(tester.element(find.text('Alpha'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 0);
      expect(
        find.descendant(
          of: find.byType(Opacity),
          matching: find.byType(SelectionHighlight),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('should keep search input when feedback opens a lazy menu', (
      tester,
    ) async {
      int? picked;
      await tester.pumpWidget(
        _host(
          state,
          tracker,
          SizedBox(
            width: 240,
            child: OptionMenuBar<int>(
              value: 179,
              searchable: true,
              items: List.generate(180, (i) => OptionItem(i, 'Model $i')),
              onChanged: (value) => picked = value,
            ),
          ),
        ),
      );
      await _press(tester, find.text('Model 179'), tracker);
      final field = tester.state(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Model 17');
      await tester.pumpAndSettle();
      state.setSelectionStyle('outline');
      await tester.pump();
      expect(tester.state(find.byType(TextField)), same(field));
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(find.byType(ListView), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, 170);
      expect(find.byType(ListView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('should retain modality drag reorder and disabled semantics', (
      tester,
    ) async {
      var selected = <String>{LiquidModalities.text};
      final order = List<String>.of(LiquidModalities.all);
      var enabled = true;
      var toggles = 0;
      late StateSetter refresh;
      state.setSelectionStyle('liquid');
      await tester.pumpWidget(
        _host(
          state,
          tracker,
          StatefulBuilder(
            builder: (context, setState) {
              refresh = setState;
              return SizedBox(
                width: 320,
                child: LiquidModalityPills(
                  order: List.of(order),
                  selected: selected,
                  enabled: enabled,
                  onToggle: (value) => setState(() {
                    toggles++;
                    selected = Set.of(selected);
                    if (!selected.add(value)) selected.remove(value);
                  }),
                  onReorder: (from, to) => setState(() {
                    final value = order.removeAt(from);
                    order.insert(to, value);
                  }),
                  labelOf: (value) => value,
                  iconOf: (_) => Icons.text_fields,
                ),
              );
            },
          ),
        ),
      );
      final text = find.byKey(const ValueKey('modality_text'));
      final image = find.byKey(const ValueKey('modality_image'));
      await _press(tester, image, tracker);
      expect(selected, contains(LiquidModalities.image));
      expect(
        tester.getSemantics(image).flagsCollection.isToggled,
        Tristate.isTrue,
      );
      final target = tester.getCenter(image);
      final drag = await tester.startGesture(tester.getCenter(text));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(target);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(Opacity),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      await drag.up();
      await tester.pumpAndSettle();
      expect(order, ['image', 'text', 'voice']);
      refresh(() => enabled = false);
      await tester.pumpAndSettle();
      final presses = tracker.colors.length;
      final previousToggles = toggles;
      await tester.tap(text);
      await tester.pumpAndSettle();
      expect(tracker.colors.length, presses);
      expect(toggles, previousToggles);
      expect(
        tester.getSemantics(text).flagsCollection.isEnabled,
        Tristate.isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('should preserve overflow tooltip and Escape dismissal', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          state,
          tracker,
          SizedBox(
            width: 300,
            child: MobilePillBarLayout(
              titlePill: const Text('Actions'),
              actions: [
                for (var i = 0; i < 3; i++)
                  IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
              ],
            ),
          ),
        ),
      );
      await _press(tester, find.byTooltip('More actions'), tracker);
      expect(find.byTooltip('Collapse'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('More actions'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'should keep AI filter actions while inheriting themed presses',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        state.config.aiProfiles = [
          AiProfile(name: 'Enabled provider'),
          AiProfile(name: 'Disabled provider')..enabled = false,
        ];
        await tester.pumpWidget(
          _host(state, tracker, MobileAiProvidersPage(state: state)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Disabled provider'), findsOneWidget);
        await _press(tester, find.text('Enabled only'), tracker);
        expect(find.text('Disabled provider'), findsNothing);
        await _press(tester, find.byIcon(Icons.tune), tracker);
        expect(find.text('Disabled provider'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
