import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/animated_popup.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _applyLabel =
    'Apply to file (does not change container pipeline)';

Future<void> _openMenu(
  WidgetTester tester, {
  required bool mobile,
  double textScale = 1,
  required List<AnimatedMenuEntry<String>> items,
  ValueChanged<String?>? onResult,
}) async {
  final oldPlatform = debugIsMobilePlatformOverride;
  debugIsMobilePlatformOverride = mobile;
  addTearDown(() => debugIsMobilePlatformOverride = oldPlatform);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = mobile
      ? const Size(320, 720)
      : const Size(1440, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark().copyWith(
        platform: mobile ? TargetPlatform.android : TargetPlatform.windows,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showAnimatedMenu<String>(
                context: context,
                position: const Offset(312, 100),
                width: 240,
                items: items,
              );
              onResult?.call(result);
            },
            child: const Text('Open menu'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open menu'));
  await tester.pumpAndSettle();
}

void _expectUnclippedLabel(WidgetTester tester) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(_applyLabel));
  final fullHeight = paragraph.getMaxIntrinsicHeight(paragraph.size.width);
  expect(fullHeight, greaterThan(40));
  expect(
    paragraph.size.height,
    greaterThanOrEqualTo(fullHeight - 0.01),
    reason: 'The complete wrapped label must fit vertically in the menu row.',
  );
}

void main() {
  for (final textScale in [1.0, 2.4]) {
    testWidgets('mobile long menu label remains readable at $textScale scale', (
      tester,
    ) async {
      String? selected;
      await _openMenu(
        tester,
        mobile: true,
        textScale: textScale,
        onResult: (value) => selected = value,
        items: const [
          AnimatedMenuEntry(value: 'apply', child: Text(_applyLabel)),
          AnimatedMenuEntry(value: 'up', child: Text('Move up')),
        ],
      );
      _expectUnclippedLabel(tester);
      final row = find.ancestor(
        of: find.text(_applyLabel),
        matching: find.byType(InkWell),
      );
      final bounds = tester.getRect(row);
      expect(bounds.left, greaterThanOrEqualTo(8));
      expect(bounds.right, lessThanOrEqualTo(312));
      expect(bounds.width, lessThanOrEqualTo(200));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(_applyLabel));
      await tester.pumpAndSettle();
      expect(selected, 'apply');
      expect(find.text(_applyLabel), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disabled long labels grow without becoming selectable', (
    tester,
  ) async {
    var callbacks = 0;
    await _openMenu(
      tester,
      mobile: true,
      textScale: 2.4,
      items: [
        const AnimatedMenuEntry(child: Text(_applyLabel)),
        AnimatedMenuEntry(
          onTap: () => callbacks++,
          child: const Text('Custom action'),
        ),
      ],
    );
    _expectUnclippedLabel(tester);
    await tester.tap(find.text(_applyLabel));
    await tester.pumpAndSettle();
    expect(find.text(_applyLabel), findsOneWidget);
    expect(callbacks, 0);
    await tester.ensureVisible(find.text('Custom action'));
    await tester.tap(find.text('Custom action'));
    await tester.pumpAndSettle();
    expect(callbacks, 1);
    expect(find.text(_applyLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop short items keep their height and selection result', (
    tester,
  ) async {
    String? selected;
    await _openMenu(
      tester,
      mobile: false,
      onResult: (value) => selected = value,
      items: const [
        AnimatedMenuEntry(value: 'up', child: Text('Move up')),
        AnimatedMenuEntry.divider(),
        AnimatedMenuEntry(value: 'remove', child: Text('Remove')),
      ],
    );
    for (final label in ['Move up', 'Remove']) {
      final row = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(row).height, 40);
    }
    expect(tester.getSize(find.byType(Divider)).height, 9);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(selected, 'remove');
    expect(find.text('Remove'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
