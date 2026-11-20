import 'dart:convert';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/option_menu_bar.dart';
import 'package:ffmpegpp_gui/widgets/selection_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _styleKey = 'selection_indicator_style';
const _styles = ['theme', 'liquid', 'blur', 'outline'];

// Use the real update/notification path without writing user settings.
class _MemoryConfigService extends ConfigService {
  @override
  Future<void> save() async {}
}

class _SettingsState extends AppState {
  final _memoryConfig = _MemoryConfigService();

  @override
  ConfigService get configService => _memoryConfig;
}

Future<void> _pumpSettings(
  WidgetTester tester,
  AppState state, {
  Size size = const Size(1280, 800),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('AppConfig selection indicator style', () {
    test('should persist each style independently of navigation surfaces', () {
      for (final style in _styles) {
        final config = AppConfig(
          selectionIndicatorStyle: style,
          menuStyle: 'gray',
          navStyle: 'blur',
        );
        final json = jsonDecode(jsonEncode(config.toJson()))
            as Map<String, dynamic>;
        expect(json[_styleKey], style);
        final restored = AppConfig.fromJson(json);
        expect(restored.selectionIndicatorStyle, style);
        expect(restored.menuStyle, 'gray');
        expect(restored.navStyle, 'blur');
      }
    });

    test('should default missing or invalid styles to theme', () {
      expect(AppConfig().selectionIndicatorStyle, 'theme');
      expect(AppConfig.fromJson({}).selectionIndicatorStyle, 'theme');
      for (final invalid in [null, '', 'gray', 'glass', 9, true, <Object>[]]) {
        final config = AppConfig.fromJson({_styleKey: invalid});
        expect(config.selectionIndicatorStyle, 'theme');
        expect(config.toJson()[_styleKey], 'theme');
      }
      expect(
        AppConfig(selectionIndicatorStyle: 'bad').toJson()[_styleKey],
        'theme',
      );
    });
  });

  group('SettingsPage selection indicator style', () {
    late AppState state;
    setUp(() {
      state = _SettingsState();
      state.config
        ..language = 'en'
        ..cardStyle = 'gray'
        ..menuStyle = 'gray'
        ..navStyle = 'blur'
        ..pillStyle = 'gray';
    });
    tearDown(() => state.dispose());

    final control = find.byKey(
      const ValueKey('settings_selection_indicator_style'),
    );

    testWidgets('should change the mask while retaining the active pane', (
      tester,
    ) async {
      await _pumpSettings(tester, state);
      final row = find.byKey(const ValueKey('settings_section_appearance'));
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();

      final pane = find.byKey(const ValueKey('pane_appearance'));
      final paneElement = tester.element(pane);
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: pane, matching: find.byType(Scrollable)).first,
      ).position;
      final offset = scroll.pixels;
      final mask = find.byKey(const ValueKey('settings_section_selection'));
      expect(tester.widget(mask), isA<SelectionHighlight>());
      expect(tester.getRect(mask), tester.getRect(row));
      expect(
        find.ancestor(of: mask, matching: find.byType(GlassPanel)),
        findsNothing,
      );
      expect(mask.hitTestable(), findsNothing);
      expect(tester.widget<OptionMenuBar<String>>(control).value, 'theme');
      expect(
        tester.widget<OptionMenuBar<String>>(control).items.map((i) => i.value),
        _styles,
      );

      await tester.tap(control);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Outline').hitTestable());
      await tester.pumpAndSettle();

      expect(state.config.selectionIndicatorStyle, 'outline');
      expect(state.config.menuStyle, 'gray');
      expect(state.config.navStyle, 'blur');
      expect(tester.widget<OptionMenuBar<String>>(control).value, 'outline');
      expect(tester.element(pane), same(paneElement));
      expect(scroll.pixels, closeTo(offset, 0.01));
      expect(mask, findsOneWidget);
      expect(tester.getRect(mask), tester.getRect(row));
      final decoration = tester.widget<DecoratedBox>(
        find.descendant(of: mask, matching: find.byType(DecoratedBox)).first,
      ).decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
      expect(decoration.color, isNull);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('should expose a usable control on a 320dp large-text pane', (
      tester,
    ) async {
      await _pumpSettings(tester, state, size: const Size(320, 720), textScale: 2);
      final search = find.byType(TextField).first;
      await tester.enterText(search, '选中遮罩');
      await tester.pumpAndSettle();
      expect(control, findsOneWidget);
      await tester.enterText(search, 'selection mask');
      await tester.pumpAndSettle();
      expect(control, findsOneWidget);
      await tester.ensureVisible(control);
      expect(tester.getSize(control).height, greaterThanOrEqualTo(44));
      await tester.tap(control);
      await tester.pumpAndSettle();
      final frostedGlass = find.text('Frosted glass').hitTestable();
      expect(frostedGlass, findsOneWidget);
      await tester.tap(frostedGlass);
      await tester.pumpAndSettle();
      expect(tester.widget<OptionMenuBar<String>>(control).value, 'blur');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
