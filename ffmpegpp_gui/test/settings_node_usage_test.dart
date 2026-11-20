import 'dart:convert';

import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Exercise real config transforms and notifications without writing user files.
class _MemoryConfigService extends ConfigService {
  @override
  Future<void> save() async {}
}

class _SettingsState extends AppState {
  final ConfigService _memoryConfig = _MemoryConfigService();

  @override
  ConfigService get configService => _memoryConfig;
}

const _reset = ValueKey('reset-node-usage');
const _confirm = ValueKey('confirm-reset-node-usage');
const _cancel = ValueKey('cancel-reset-node-usage');

Map<String, dynamic> _configSnapshot(AppState state) =>
    jsonDecode(jsonEncode(state.config.toJson())) as Map<String, dynamic>;

Future<void> _pumpSettings(
  WidgetTester tester,
  AppState state, {
  bool wholePage = false,
  double scale = 1,
  Size size = const Size(1000, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: wholePage
            ? const SettingsPage()
            : const Scaffold(
                body: SingleChildScrollView(child: NodeUsageSettingsCard()),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('NodeUsageSettingsCard', () {
    late _SettingsState state;
    setUp(() {
      state = _SettingsState();
      state.config
        ..language = 'en'
        ..cardStyle = 'gray'
        ..pillStyle = 'gray'
        ..menuStyle = 'gray'
        ..nodeUsageCount = {'trim': 7, 'concat': 2}
        ..favoriteNodeTypes = ['trim', 'scale']
        ..recentNodeTypes = ['concat', 'trim']
        ..autosaveIntervalSec = 47;
    });
    tearDown(() => state.dispose());

    testWidgets('should cancel or dismiss reset without changing settings', (
      tester,
    ) async {
      await _pumpSettings(tester, state);
      final before = _configSnapshot(state);
      expect(find.text('2 node types · 9 uses'), findsOneWidget);
      expect(find.byKey(const ValueKey('node-usage-scope')), findsOneWidget);
      await tester.tap(find.byKey(_reset));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(_configSnapshot(state), before);
      await tester.tap(find.byKey(_cancel));
      await tester.pumpAndSettle();
      expect(_configSnapshot(state), before);

      await tester.tap(find.byKey(_reset));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(_configSnapshot(state), before);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('should clear only counts after confirmation and update live', (
      tester,
    ) async {
      await _pumpSettings(tester, state);
      final otherSettings = _configSnapshot(state)..remove('node_usage_count');
      await tester.tap(find.byKey(_reset));
      await tester.pumpAndSettle();
      expect(state.config.nodeUsageCount, {'trim': 7, 'concat': 2});
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      expect(state.config.nodeUsageCount, isEmpty);
      expect(_configSnapshot(state)..remove('node_usage_count'), otherSettings);
      expect(find.text('0 node types · 0 uses'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_reset)).onPressed,
        isNull,
      );

      await state.updateConfig((config) {
        config.nodeUsageCount['concat'] = 4;
        return config;
      });
      await tester.pump();
      expect(find.text('1 node type · 4 uses'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_reset)).onPressed,
        isNotNull,
      );
      // Let the real config-update debounce finish after the external usage.
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    for (final language in ['en', 'zh']) {
      testWidgets('should fit shared mobile content at 320px in $language', (
        tester,
      ) async {
        state.config.language = language;
        await _pumpSettings(
          tester,
          state,
          scale: 2,
          size: const Size(320, 640),
        );
        await tester.ensureVisible(find.byKey(_reset));
        await tester.tap(find.byKey(_reset));
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'zh' ? '重置节点使用频次？' : 'Reset node usage frequency?',
          ),
          findsOneWidget,
        );
        expect(find.byKey(_confirm).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(_confirm));
        await tester.pumpAndSettle();
        expect(state.config.nodeUsageCount, isEmpty);
        expect(state.config.favoriteNodeTypes, ['trim', 'scale']);
        expect(
          find.text(
            language == 'zh' ? '已记录 0 种节点，共 0 次使用' : '0 node types · 0 uses',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('should discover the reset in Chinese and English and Locate', (
      tester,
    ) async {
      await _pumpSettings(tester, state, wholePage: true);
      final search = find.byType(TextField).first;
      for (final query in ['clear node usage', '清除节点使用频次', '频次重置']) {
        await tester.enterText(search, query);
        await tester.pumpAndSettle();
        expect(find.byType(NodeUsageSettingsCard), findsOneWidget);
      }
      await tester.tap(
        find.widgetWithIcon(TextButton, Icons.my_location).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane_advanced')), findsOneWidget);
      expect(find.byType(NodeUsageSettingsCard), findsOneWidget);
      expect(state.config.nodeUsageCount, {'trim': 7, 'concat': 2});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('should disable reset when no counts are stored', (
      tester,
    ) async {
      state.config.nodeUsageCount.clear();
      await _pumpSettings(tester, state);
      expect(find.text('0 node types · 0 uses'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_reset)).onPressed,
        isNull,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
