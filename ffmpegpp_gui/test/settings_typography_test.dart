import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/settings_typography.dart';
import 'package:ffmpegpp_gui/widgets/app_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget harness(AppState state, Widget child, {double scale = 1}) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );

AppState settingsState() {
  final state = AppState();
  state.updateConfig(
    (c) => c
      ..language = 'en'
      ..cardStyle = 'gray'
      ..pillStyle = 'gray'
      ..mcpEnabled = false,
  );
  return state;
}

void main() {
  group('SettingsTypography', () {
    testWidgets('should wrap headings at large text scale and keep actions', (
      tester,
    ) async {
      var pressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SizedBox(
                width: 250,
                child: SettingsSectionHeading(
                  title: 'A long descriptive settings group heading',
                  trailing: IconButton(
                    tooltip: 'Delete',
                    onPressed: () => pressed = true,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final text = tester.widget<Text>(
        find.text('A long descriptive settings group heading'),
      );
      expect(text.style?.fontSize, 12);
      expect(text.maxLines, isNull);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Delete'));
      expect(pressed, isTrue);
      final headingSemantics = tester.widgetList<Semantics>(
        find.ancestor(
          of: find.text('A long descriptive settings group heading'),
          matching: find.byType(Semantics),
        ),
      );
      expect(headingSemantics.any((s) => s.properties.header == true), isTrue);
    });

    testWidgets('should put general group headings outside cards', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = settingsState();
      await tester.pumpWidget(harness(state, const SettingsPage()));
      await tester.pumpAndSettle();
      final headings = find.byType(SettingsSectionHeading);
      expect(headings, findsWidgets);
      for (final element in headings.evaluate()) {
        expect(
          find.ancestor(
            of: find.byWidget(element.widget),
            matching: find.byType(AppCard),
          ),
          findsNothing,
        );
      }
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('should separate AI headings and keep switch labels in cards', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = settingsState();
      await tester.pumpWidget(
        harness(
          state,
          SingleChildScrollView(
            child: Builder(
              builder: (context) => mobileAiSettingsContent(context, state),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final headings = find.byType(SettingsSectionHeading);
      expect(headings, findsWidgets);
      for (final element in headings.evaluate()) {
        expect(
          find.ancestor(
            of: find.byWidget(element.widget),
            matching: find.byType(AppCard),
          ),
          findsNothing,
        );
      }
      // Primary option labels stay within their interactive surfaces.
      for (final label in [
        'Read Access',
        'Write Access',
        'MCP Server',
        'Advanced',
      ]) {
        expect(find.text(label), findsOneWidget);
        expect(
          find.ancestor(of: find.text(label), matching: find.byType(AppCard)),
          findsOneWidget,
        );
      }
      final readDescription = tester.widget<Text>(
        find.text('Allow AI to read files and directories'),
      );
      expect(readDescription.style?.fontSize, 10.5);
      final switches = tester.widgetList<Switch>(find.byType(Switch));
      expect(switches.length, greaterThanOrEqualTo(4));
      final descriptions = tester
          .widgetList<Text>(find.byType(Text))
          .where(
            (text) =>
                text.style?.fontSize == SettingsTypography.description.fontSize,
          );
      expect(descriptions, isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    });
  });
}
