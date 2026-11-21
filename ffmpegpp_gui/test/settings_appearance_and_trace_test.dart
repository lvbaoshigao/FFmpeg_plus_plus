import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _MemoryConfigService extends ConfigService {
  @override
  Future<void> save() async {}
}

class _SettingsState extends AppState {
  final _configService = _MemoryConfigService();

  @override
  ConfigService get configService => _configService;
}

void main() {
  group('SettingsPage appearance and diagnostics', () {
    late AppState state;

    setUp(() {
      state = _SettingsState();
      state.config
        ..language = 'en'
        ..cardStyle = 'gray'
        ..menuStyle = 'gray';
    });
    tearDown(() => state.dispose());

    Future<void> openSettings(WidgetTester tester, String section) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 960);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.tap(find.byKey(ValueKey('settings_section_$section')));
      await tester.pumpAndSettle();
    }

    testWidgets('should put common appearance controls before overrides', (
      tester,
    ) async {
      await openSettings(tester, 'appearance');
      final orderedTitles = [
        'Appearance mode',
        'Accent color',
        'Background',
        'Font',
        'Style presets',
        'Cards and popups',
        'Glass and borders',
        'Effects',
        'Navigation & selection',
        'Node editor',
      ];
      final positions = orderedTitles.map((title) {
        final heading = find.text(title);
        expect(heading, findsWidgets, reason: 'Missing heading: $title');
        return tester.getTopLeft(heading.first).dy;
      }).toList();
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], greaterThan(positions[i - 1]));
      }
    });

    testWidgets('should show a single shared blur control with details open', (
      tester,
    ) async {
      state.config.cardStyle = 'blur';
      await openSettings(tester, 'appearance');
      final blur = find.byKey(const ValueKey('settings_surface_blur'));
      final details = find.text('Glass details');
      expect(blur, findsOneWidget);
      expect(find.textContaining('Clarity:'), findsNothing);

      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();

      expect(blur, findsOneWidget);
      expect(find.textContaining('Clarity:'), findsOneWidget);
    });

    testWidgets('should require confirmation only when enabling probes', (
      tester,
    ) async {
      await openSettings(tester, 'advanced');
      final setting = find.byKey(const ValueKey('settings_very_verbose_logs'));
      final dialog = find.text('Enable very verbose logs?');
      expect(tester.widget<SwitchListTile>(setting).value, isFalse);

      await tester.ensureVisible(setting);
      await tester.tap(setting);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(state.config.veryVerboseLogs, isFalse);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('only while debugging'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(state.config.veryVerboseLogs, isFalse);

      await tester.tap(setting);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(setting).value, isTrue);
      expect(state.config.debugMode, isFalse);

      await tester.tap(setting);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(state.config.veryVerboseLogs, isFalse);
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
