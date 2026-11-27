import 'package:ffmpegpp_gui/app.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_mobile_nav.dart';
import 'package:ffmpegpp_gui/widgets/mobile_bottom_nav.dart';
import 'package:ffmpegpp_gui/widgets/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// UI tests keep configuration updates in memory; lifecycle and permission
/// behavior is exercised separately by the real PluginManager tests.
class _NavigationState extends AppState {
  @override
  Future<void> updateConfig(AppConfig Function(AppConfig) update) async {
    update(config);
    notifyListeners();
  }

  void setPluginsEnabled(bool enabled) {
    config.pluginsEnabled = enabled;
    notifyListeners();
  }

  void setLogsVisible(bool visible) {
    config.debugMode = visible;
    notifyListeners();
  }
}

Future<_NavigationState> _mount(
  WidgetTester tester, {
  required Widget Function(_NavigationState) builder,
  bool mobile = false,
  bool pluginsEnabled = false,
}) async {
  debugIsMobilePlatformOverride = mobile;
  tester.view.physicalSize = mobile
      ? const Size(420, 820)
      : const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = _NavigationState();
  state.config
    ..language = 'en'
    ..pluginsEnabled = pluginsEnabled
    ..debugMode = false
    ..veryVerboseLogs = false
    ..autoCheckUpdate = false
    ..mobileNavPlacement = 'bottom'
    ..navStyle = 'gray'
    ..cardStyle = 'gray'
    ..menuStyle = 'gray'
    ..pillStyle = 'gray';
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: builder(state),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Widget _probeShell(bool mobile, List<int> requested) => AppShell(
  mobile: mobile,
  pageBuilder: (_, destination) {
    requested.add(destination);
    return Center(
      key: ValueKey('destination-$destination'),
      child: Text('Destination $destination'),
    );
  },
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => debugIsMobilePlatformOverride = null);

  testWidgets('sidebar preserves plugin ID when logs are hidden or shown', (
    tester,
  ) async {
    final state = await _mount(
      tester,
      builder: (state) => Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: Consumer<AppState>(
            builder: (_, state, _) => Sidebar(
              selectedIndex: state.selectedNav,
              onSelected: state.selectNav,
            ),
          ),
        ),
      ),
    );
    final plugin = find.byKey(const ValueKey('sidebar_nav_6'));
    final logs = find.byKey(const ValueKey('sidebar_nav_5'));
    expect(state.config.pluginsEnabled, isFalse);
    expect(plugin, findsNothing);
    expect(logs, findsNothing);
    expect(find.byKey(const ValueKey('sidebar_nav_2')), findsOneWidget);

    state.setPluginsEnabled(true);
    await _settle(tester);
    await tester.tap(plugin);
    await _settle(tester);
    expect(state.selectedNav, 6);
    expect(tester.widget<Semantics>(plugin).properties.selected, isTrue);
    final selection = find.byKey(const ValueKey('sidebar_selection'));
    final hiddenLogsTop = tester.getRect(selection).top;

    state.setLogsVisible(true);
    await _settle(tester);
    expect(logs, findsOneWidget);
    expect(state.selectedNav, 6);
    expect(tester.getRect(selection).top, hiddenLogsTop + 40);
    await tester.tap(logs);
    await _settle(tester);
    expect(state.selectedNav, 5);
    state.setLogsVisible(false);
    await _settle(tester);
    expect(state.selectedNav, 4);
    expect(plugin, findsOneWidget);
  });

  testWidgets('sidebar drag uses plugin destination instead of visual index', (
    tester,
  ) async {
    final requested = <int>[];
    final state = await _mount(
      tester,
      pluginsEnabled: true,
      builder: (_) => _probeShell(false, requested),
    );
    final first = find.byKey(const ValueKey('sidebar_nav_0'));
    final plugin = find.byKey(const ValueKey('sidebar_nav_6'));
    final gesture = await tester.startGesture(tester.getCenter(first));
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(plugin),
      timeStamp: const Duration(milliseconds: 150),
    );
    await gesture.up();
    await _settle(tester);
    expect(state.selectedNav, 6);
    expect(requested, contains(6));
    expect(requested, isNot(contains(5)));
  });

  for (final rail in [false, true]) {
    testWidgets(
      '${rail ? 'rail' : 'bottom bar'} gates the plugin and selects ID 6',
      (tester) async {
        final selections = <int>[];
        final state = await _mount(
          tester,
          mobile: true,
          builder: (_) => Scaffold(
            body: Align(
              alignment: rail ? Alignment.centerLeft : Alignment.bottomCenter,
              child: rail
                  ? MobileNavRail(
                      selectedIndex: 0,
                      onSelected: selections.add,
                      placement: MobileNavPlacement.left,
                    )
                  : LiquidGlassMobileNav(
                      selectedIndex: 0,
                      onSelected: selections.add,
                    ),
            ),
          ),
        );
        expect(find.text('Plugins'), findsNothing);
        state.setPluginsEnabled(true);
        await _settle(tester);
        await tester.tap(find.text('Plugins'));
        await _settle(tester);
        expect(selections, [6]);
        await tester.tap(find.text('Settings'));
        await _settle(tester);
        expect(selections, [6, 4]);
        state.setPluginsEnabled(false);
        await _settle(tester);
        expect(find.text('Plugins'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'mobile' : 'desktop'} shell returns disabled plugin to Settings',
      (tester) async {
        final requested = <int>[];
        final state = await _mount(
          tester,
          mobile: mobile,
          builder: (_) => _probeShell(mobile, requested),
        );
        expect(requested, isNot(contains(6)));
        state.selectNav(6);
        await _settle(tester);
        expect(state.selectedNav, 4);
        expect(requested, isNot(contains(6)));

        state.setPluginsEnabled(true);
        await _settle(tester);
        state.selectNav(6);
        await _settle(tester);
        expect(state.selectedNav, 6);
        expect(find.byKey(const ValueKey('destination-6')), findsOneWidget);
        state.setPluginsEnabled(false);
        await _settle(tester);
        expect(state.selectedNav, 4);
        expect(find.byKey(const ValueKey('destination-6')), findsNothing);
        expect(find.byKey(const ValueKey('destination-4')), findsOneWidget);
        if (mobile) {
          final controller = tester
              .widget<PageView>(find.byType(PageView))
              .controller!;
          expect(controller.page, 3);
          expect(
            controller.position.pixels,
            lessThanOrEqualTo(controller.position.maxScrollExtent),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mobile swipes reach plugin and disabling during swipe clamps pages',
    (tester) async {
      final requested = <int>[];
      final state = await _mount(
        tester,
        mobile: true,
        pluginsEnabled: true,
        builder: (_) => _probeShell(true, requested),
      );
      state.selectNav(4);
      await _settle(tester);
      final pages = find.byType(PageView);
      await tester.drag(pages, const Offset(-320, 0));
      await _settle(tester);
      expect(state.selectedNav, 6);
      expect(find.byKey(const ValueKey('destination-6')), findsOneWidget);
      await tester.drag(pages, const Offset(320, 0));
      await _settle(tester);
      expect(state.selectedNav, 4);

      final gesture = await tester.startGesture(tester.getCenter(pages));
      await gesture.moveBy(const Offset(-300, 0));
      await tester.pump();
      state.setPluginsEnabled(false);
      await tester.pump();
      await gesture.up();
      await _settle(tester);
      expect(state.selectedNav, 4);
      final controller = tester.widget<PageView>(pages).controller!;
      expect(controller.page, 3);
      expect(
        controller.position.pixels,
        lessThanOrEqualTo(controller.position.maxScrollExtent),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('experimental settings search exposes a live plugin toggle', (
    tester,
  ) async {
    final state = await _mount(tester, builder: (_) => const SettingsPage());
    await tester.tap(
      find.byKey(const ValueKey('settings_section_experimental')),
    );
    await _settle(tester);
    final toggle = find.byKey(const ValueKey('settings_plugins_enabled'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await _settle(tester);
    expect(state.config.pluginsEnabled, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    state.setPluginsEnabled(false);
    await _settle(tester);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.enterText(find.byType(TextField).first, 'webassembly');
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('settings-search-result-plugins')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
