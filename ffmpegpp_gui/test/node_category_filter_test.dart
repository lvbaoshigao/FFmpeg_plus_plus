import 'dart:ui' show Tristate;

import 'package:ffmpegpp_gui/models/node_picker_options.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/node_category_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _categories = [
  NodePickerCategory.video,
  NodePickerCategory.audio,
  NodePickerCategory.image,
  NodePickerCategory.generic,
  NodePickerCategory.control,
];

Finder _chip(NodePickerCategory category) =>
    find.byKey(ValueKey('node-picker-category-${category.name}'));

Future<List<NodePickerCategory>> _mount(
  WidgetTester tester, {
  ThemeData? theme,
  double width = 464,
  double textScale = 1,
  bool dense = true,
  bool isZh = false,
  bool highContrast = false,
}) async {
  final changes = <NodePickerCategory>[];
  var value = NodePickerCategory.video;
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      theme: theme ?? AppTheme.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          highContrast: highContrast,
        ),
        child: child!,
      ),
      home: Scaffold(
        backgroundColor: Colors.deepOrange,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: StatefulBuilder(
              builder: (context, setState) => NodeCategoryFilter(
                categories: _categories,
                value: value,
                isZh: isZh,
                dense: dense,
                onChanged: (category) => setState(() {
                  changes.add(category);
                  value = category;
                }),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return changes;
}

Material _surface(WidgetTester tester, NodePickerCategory category) =>
    tester.widget<Material>(
      find
          .descendant(of: _chip(category), matching: find.byType(Material))
          .first,
    );

Color _fill(WidgetTester tester, NodePickerCategory category) =>
    (tester
                .widget<Ink>(
                  find
                      .descendant(
                        of: _chip(category),
                        matching: find.byType(Ink),
                      )
                      .first,
                )
                .decoration!
            as ShapeDecoration)
        .color!;

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}

void main() {
  testWidgets(
    'selects one category without moving or resizing its neighbours',
    (tester) async {
      final changes = await _mount(tester);
      final bounds = {
        for (final category in _categories)
          category: tester.getRect(_chip(category)),
      };
      await tester.tap(_chip(NodePickerCategory.audio));
      await tester.pumpAndSettle();
      expect(changes, [NodePickerCategory.audio]);
      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .where((chip) => chip.selected),
        hasLength(1),
      );
      expect(
        tester.widget<ChoiceChip>(_chip(NodePickerCategory.audio)).selected,
        isTrue,
      );
      for (final category in _categories) {
        expect(tester.getRect(_chip(category)), bounds[category]);
      }
      expect(find.text('Container'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retains keyboard activation and selected semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      final changes = await _mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(changes, [NodePickerCategory.audio]);
      final audio = tester.getSemantics(_chip(NodePickerCategory.audio));
      expect(audio.label, 'Audio');
      expect(audio.flagsCollection.isSelected, Tristate.isTrue);
      expect(audio.flagsCollection.isFocused, Tristate.isTrue);
      expect(audio.flagsCollection.isButton, isTrue);
      expect(
        tester
            .getSemantics(_chip(NodePickerCategory.video))
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(changes, [NodePickerCategory.audio, NodePickerCategory.image]);
      expect(
        tester.widget<ChoiceChip>(_chip(NodePickerCategory.image)).selected,
        isTrue,
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets(
    'keeps readable opaque surfaces in light dark and fallback themes',
    (tester) async {
      for (final theme in [
        AppTheme.light(seedColor: 0xFFFFCC00),
        AppTheme.dark(seedColor: 0xFFFFCC00),
        AppTheme.light(useThemeColor: false),
        AppTheme.dark(useThemeColor: false),
      ]) {
        await _mount(tester, theme: theme);
        for (final category in _categories) {
          final material = _surface(tester, category);
          final fill = _fill(tester, category);
          final text = tester.element(
            find.descendant(of: _chip(category), matching: find.byType(Text)),
          );
          final foreground = DefaultTextStyle.of(text).style.color!;
          expect(fill.a, 1, reason: 'wallpaper must not change label contrast');
          expect(_contrast(foreground, fill), greaterThanOrEqualTo(4.5));
          expect(
            tester.getSize(_chip(category)).height,
            inInclusiveRange(32, 40),
          );
          final shape = material.shape! as RoundedRectangleBorder;
          expect(shape.borderRadius, BorderRadius.circular(10));
          expect(shape.side.width, greaterThan(0));
          expect(shape.side.color.a, greaterThan(0));
        }
        final unselected = _fill(tester, NodePickerCategory.audio);
        expect(unselected.r, closeTo(unselected.g, 1 / 255));
        expect(unselected.g, closeTo(unselected.b, 1 / 255));
        expect(_fill(tester, NodePickerCategory.video), isNot(unselected));
        final video = tester.getRect(_chip(NodePickerCategory.video));
        final audio = tester.getRect(_chip(NodePickerCategory.audio));
        expect(audio.left - video.right, 6);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'wraps long localized labels in narrow panels at large text scales',
    (tester) async {
      for (final scenario in [
        (90.0, 2.0, false, true),
        (232.0, 1.0, true, true),
        (464.0, 1.0, true, true),
        (280.0, 2.0, true, false),
        (232.0, 1.6, false, true),
        (500.0, 1.0, false, false),
      ]) {
        await _mount(
          tester,
          width: scenario.$1,
          textScale: scenario.$2,
          isZh: scenario.$3,
          dense: scenario.$4,
        );
        for (final category in _categories) {
          final bounds = tester.getRect(_chip(category));
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(scenario.$1 + 0.01));
          expect(
            find.text(nodePickerCategoryLabel(category, isZh: scenario.$3)),
            findsOneWidget,
          );
          if (!scenario.$4) {
            expect(bounds.height, greaterThanOrEqualTo(48));
          }
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'high contrast keeps strong boundaries and a visible focus ring',
    (tester) async {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        await _mount(tester, theme: theme, highContrast: true);
        for (final category in _categories) {
          final shape =
              _surface(tester, category).shape! as RoundedRectangleBorder;
          expect(shape.side.width, greaterThanOrEqualTo(1.5));
          expect(shape.side.color, theme.colorScheme.onSurface);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final focused =
            _surface(tester, NodePickerCategory.video).shape!
                as RoundedRectangleBorder;
        expect(focused.side.color, theme.colorScheme.primary);
        expect(focused.side.width, greaterThanOrEqualTo(1.5));
      }
    },
  );
}
