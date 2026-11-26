import 'dart:async';

import 'package:ffmpegpp_gui/app.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:ffmpegpp_gui/theme/app_motion.dart';
import 'package:ffmpegpp_gui/theme/app_page_transitions.dart';
import 'package:ffmpegpp_gui/widgets/polygon_morph_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _MemoryConfigService extends ConfigService {
  int saves = 0;

  @override
  Future<void> save() async => saves++;
}

class _SettingsState extends AppState {
  final memoryConfig = _MemoryConfigService();

  @override
  ConfigService get configService => memoryConfig;

  @override
  bool get configLoaded => true;
}

class _StartupConfigService extends ConfigService {
  _StartupConfigService(this.disabled);

  final bool disabled;
  final loadGate = Completer<void>();
  final historyGate = Completer<List<Map<String, dynamic>>>();
  AppConfig _restored = AppConfig();

  @override
  AppConfig get config => _restored;

  @override
  Future<void> load() async {
    await loadGate.future;
    _restored = AppConfig.fromJson({'disable_animations': disabled});
  }

  @override
  Future<List<Map<String, dynamic>>> loadTaskHistory() => historyGate.future;
}

class _UnavailableStartupProcess extends NativeProcessManager {
  @override
  Future<void> start(String serverPath) async {
    throw StateError('Test backend unavailable');
  }
}

class _StartupState extends AppState {
  _StartupState(bool disabled)
    : startupConfig = _StartupConfigService(disabled);

  final _StartupConfigService startupConfig;
  final startupProcess = _UnavailableStartupProcess();

  @override
  ConfigService get configService => startupConfig;

  @override
  NativeProcessManager get pythonProcess => startupProcess;
}

void main() {
  test(
    'animation preference defaults off and survives a config round trip',
    () {
      expect(AppConfig().disableAnimations, isFalse);
      expect(AppConfig.fromJson({}).disableAnimations, isFalse);
      final config = AppConfig(disableAnimations: true, sliderParticles: true);
      final restored = AppConfig.fromJson(config.toJson());
      expect(restored.disableAnimations, isTrue);
      expect(restored.sliderParticles, isTrue);
      restored.disableAnimations = false;
      expect(AppConfig.fromJson(restored.toJson()).disableAnimations, isFalse);
    },
  );

  for (final disabled in [false, true]) {
    testWidgets('cold startup waits for saved motion preference: $disabled', (
      tester,
    ) async {
      final state = _StartupState(disabled);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const FfmpegppApp(),
        ),
      );
      final loader = tester.element(find.byType(PolygonMorphLoader));
      expect(state.configLoaded, isFalse);
      expect(MediaQuery.disableAnimationsOf(loader), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, 0);

      final startup = state.init('unused-test-backend');
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.configLoaded, isFalse);
      expect(tester.binding.transientCallbackCount, 0);

      state.startupConfig.loadGate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.configLoaded, isTrue);
      expect(state.initialized, isFalse);
      expect(state.config.disableAnimations, disabled);
      expect(tester.element(find.byType(PolygonMorphLoader)), same(loader));
      expect(MediaQuery.disableAnimationsOf(loader), disabled);
      expect(
        tester.binding.transientCallbackCount,
        disabled ? 0 : greaterThan(0),
      );

      await tester.pumpWidget(const SizedBox());
      state.startupConfig.historyGate.complete([]);
      await tester.pump();
      await startup;
      expect(state.initialized, isTrue);
      expect(state.envOk, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed preference load still finishes initialization', (
    tester,
  ) async {
    final state = _StartupState(false);
    addTearDown(state.dispose);
    final startup = state.init('unused-test-backend');
    state.startupConfig.loadGate.completeError(
      StateError('Test config unavailable'),
    );
    await tester.pump();
    await startup;
    expect(state.configLoaded, isFalse);
    expect(state.initialized, isTrue);
    expect(state.envOk, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'app preference immediately stops and restores the splash loader',
    (tester) async {
      final state = _SettingsState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const FfmpegppApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final context = tester.element(find.byType(PolygonMorphLoader));
      expect(MediaQuery.disableAnimationsOf(context), isFalse);
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await state.updateConfig((c) => c..disableAnimations = true);
      await tester.pumpAndSettle();
      expect(MediaQuery.disableAnimationsOf(context), isTrue);
      expect(tester.binding.transientCallbackCount, 0);
      expect(state.config.sliderParticles, isTrue);

      await state.updateConfig((c) => c..disableAnimations = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(MediaQuery.disableAnimationsOf(context), isFalse);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('system reduced motion still wins when app animations are on', (
    tester,
  ) async {
    late BuildContext childContext;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: AppMotion(
            disabled: false,
            child: Builder(
              builder: (context) {
                childContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    expect(MediaQuery.disableAnimationsOf(childContext), isTrue);
    expect(MediaQuery.accessibleNavigationOf(childContext), isTrue);
  });

  for (final platform in TargetPlatform.values) {
    testWidgets('page routes have no transition on $platform', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(platform: platform),
          builder: (context, child) => AppMotion(disabled: true, child: child!),
          home: const Scaffold(body: Text('Home')),
        ),
      );
      final route = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Next')),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump();
      expect(route.transitionDuration, Duration.zero);
      expect(find.text('Next'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);

      final appRoute = AppPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('App route')),
      );
      navigator.currentState!.push(appRoute);
      await tester.pump();
      await tester.pump();
      expect(appRoute.transitionDuration, Duration.zero);
      expect(appRoute.reverseTransitionDuration, Duration.zero);
      expect(find.text('App route'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('settings toggle saves and preserves the comet preference', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.reset);
    final state = _SettingsState();
    state.config
      ..language = 'en'
      ..cardStyle = 'gray'
      ..menuStyle = 'gray';
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: Consumer<AppState>(
          builder: (context, state, _) => MaterialApp(
            builder: (context, child) => AppMotion(
              disabled: state.config.disableAnimations,
              child: child!,
            ),
            home: const SettingsPage(),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('settings_section_appearance')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('settings_disable_animations'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(state.config.disableAnimations, isTrue);
    expect(state.memoryConfig.saves, 1);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    final comet = find.widgetWithText(SwitchListTile, 'Comet trail');
    expect(tester.widget<SwitchListTile>(comet).onChanged, isNotNull);
    await tester.tap(comet);
    await tester.pumpAndSettle();
    expect(state.config.sliderParticles, isFalse);
    expect(state.memoryConfig.saves, 2);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(state.config.disableAnimations, isFalse);
    expect(state.memoryConfig.saves, 3);
    expect(tester.widget<SwitchListTile>(comet).onChanged, isNotNull);
    expect(state.config.sliderParticles, isFalse);
    for (final query in ['Disable all animations', '关闭所有动画效果']) {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
