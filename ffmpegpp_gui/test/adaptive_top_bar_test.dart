import 'dart:io';

import 'package:ffmpegpp_gui/pages/command_page.dart';
import 'package:ffmpegpp_gui/pages/config_library_page.dart';
import 'package:ffmpegpp_gui/pages/log_page.dart';
import 'package:ffmpegpp_gui/pages/project_page.dart';
import 'package:ffmpegpp_gui/pages/queue_page.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/services/quick_config_storage.dart';
import 'package:ffmpegpp_gui/services/system_monitor.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/mobile_top_bar.dart';
import 'package:ffmpegpp_gui/widgets/mobile_ui.dart';
import 'package:ffmpegpp_gui/widgets/sidebar.dart';
import 'package:ffmpegpp_gui/widgets/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

class _LibraryConfigService extends ConfigService {
  @override
  Future<List<Map<String, dynamic>>> loadLibrary() async => [];
}

class _TestState extends AppState {
  final _libraryConfig = _LibraryConfigService();

  @override
  ConfigService get configService => _libraryConfig;
}

class _IdleMonitor extends SystemMonitor {
  @override
  void start() {}

  @override
  void stop() {}
}

typedef _Geometry = ({double width, double textScale});

final _pages = <({String name, Widget Function() create})>[
  (name: 'Project', create: () => const ProjectPage()),
  (name: 'Queue', create: () => QueuePage(monitor: _IdleMonitor())),
  (name: 'ConfigLibrary', create: () => const ConfigLibraryPage()),
  (name: 'Settings', create: () => const SettingsPage()),
  (name: 'Command', create: () => const CommandPage()),
  (name: 'Log', create: () => const LogPage(embedded: true)),
];

Widget _harness(
  AppState state,
  ValueNotifier<_Geometry> geometry,
  Widget page,
) => ChangeNotifierProvider<AppState>.value(
  value: state,
  child: MaterialApp(
    theme: AppTheme.dark(),
    builder: (context, child) => ValueListenableBuilder<_Geometry>(
      valueListenable: geometry,
      child: child,
      builder: (context, value, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(value.textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ValueListenableBuilder<_Geometry>(
          valueListenable: geometry,
          child: page,
          builder: (context, value, child) =>
              SizedBox(width: value.width, child: child),
        ),
      ),
    ),
  ),
);

Future<void> _layout(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _show(
  WidgetTester tester,
  AppState state,
  ValueNotifier<_Geometry> geometry,
  Widget page,
) async {
  // The configuration page performs real directory I/O. Keep its empty fixture
  // in the real async zone, as in mobile_glass_readability_test.
  await tester.runAsync(() async {
    await tester.pumpWidget(_harness(state, geometry, page));
    await QuickConfigStorage.loadAll(null);
  });
  await _layout(tester);
}

Finder get _pillBar => find.byWidgetPredicate(
  (widget) => widget is MobilePillTopBar || widget is MobileSubPageTopBar,
  description: 'a shared pill top bar',
);

void _expectMode(
  WidgetTester tester, {
  required bool compact,
  required String reason,
}) {
  expect(
    find.byType(GlassTopBar),
    compact ? findsNothing : findsOneWidget,
    reason: reason,
  );
  expect(_pillBar, compact ? findsOneWidget : findsNothing, reason: reason);
  expect(tester.takeException(), isNull, reason: reason);
}

class _LogRoute extends StatelessWidget {
  const _LogRoute();

  @override
  Widget build(BuildContext context) => Navigator(
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: (context) => settings.name == '/logs'
          ? const LogPage()
          : Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).pushNamed('/logs'),
                child: const Text('Open logs'),
              ),
            ),
    ),
  );
}

void main() {
  late _TestState state;
  late Directory temporary;
  Directory? previousDirectory;
  bool? previousMobileOverride;
  TargetPlatform? previousTargetPlatform;

  setUp(() {
    previousMobileOverride = debugIsMobilePlatformOverride;
    previousTargetPlatform = debugDefaultTargetPlatformOverride;
    debugIsMobilePlatformOverride = false;
    state = _TestState();
    state.config
      ..autoCheckUpdate = false
      ..language = 'en'
      ..cardStyle = 'gray'
      ..menuStyle = 'gray'
      ..pillStyle = 'gray'
      ..navStyle = 'gray'
      ..glassEffect = 'gray'
      ..selectionIndicatorStyle = 'theme';
    temporary = Directory.systemTemp.createTempSync('adaptive-top-bar-');
    previousDirectory = QuickConfigStorage.directoryOverride;
    QuickConfigStorage.directoryOverride = temporary;
  });

  tearDown(() async {
    state.dispose();
    debugIsMobilePlatformOverride = previousMobileOverride;
    debugDefaultTargetPlatformOverride = previousTargetPlatform;
    QuickConfigStorage.directoryOverride = previousDirectory;
    await temporary.delete(recursive: true);
  });

  ValueNotifier<_Geometry> geometryFor(
    WidgetTester tester, {
    double width = 599,
  }) {
    // The page is narrower than this viewport, like an AppShell content pane.
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final geometry = ValueNotifier<_Geometry>((width: width, textScale: 1));
    addTearDown(geometry.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    return geometry;
  }

  for (final page in _pages) {
    testWidgets(
      '${page.name} shares the local width and text scale breakpoint',
      (tester) async {
        final geometry = geometryFor(tester);
        final widget = page.create();
        await _show(tester, state, geometry, widget);
        final pageState = tester.state(find.byType(widget.runtimeType));
        for (final scenario in [
          (width: 599.0, textScale: 1.0, compact: true),
          (width: 600.0, textScale: 1.0, compact: false),
          (width: 700.0, textScale: 1.0, compact: false),
          (width: 900.0, textScale: 1.0, compact: false),
          (width: 899.0, textScale: 1.5, compact: true),
          (width: 900.0, textScale: 1.5, compact: false),
          (width: 899.0, textScale: 2.0, compact: true),
          (width: 900.0, textScale: 2.0, compact: false),
        ]) {
          geometry.value = (
            width: scenario.width,
            textScale: scenario.textScale,
          );
          await _layout(tester);
          _expectMode(
            tester,
            compact: scenario.compact,
            reason:
                '${page.name}: ${scenario.width}dp at ${scenario.textScale}x',
          );
          expect(
            tester.state(find.byType(widget.runtimeType)),
            same(pageState),
          );
        }
      },
    );
  }

  testWidgets('Android pages keep pill bars in a wide content pane', (
    tester,
  ) async {
    debugIsMobilePlatformOverride = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final geometry = geometryFor(tester, width: 1200);
      for (final page in _pages) {
        await _show(tester, state, geometry, page.create());
        _expectMode(
          tester,
          compact: true,
          reason: '${page.name}: wide Android',
        );
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      // Flutter verifies its debug globals before the outer tearDown runs.
      debugDefaultTargetPlatformOverride = previousTargetPlatform;
      debugIsMobilePlatformOverride = previousMobileOverride;
    }
  });

  testWidgets('collapsing the sidebar switches the same project content pane', (
    tester,
  ) async {
    final geometry = geometryFor(tester, width: 780);
    await _show(
      tester,
      state,
      geometry,
      Row(
        children: [
          Sidebar(selectedIndex: 0, onSelected: (_) {}),
          const Expanded(child: ProjectPage()),
        ],
      ),
    );
    final projectState = tester.state(find.byType(ProjectPage));
    _expectMode(tester, compact: true, reason: '780 - 190 = 590dp');
    await tester.tap(find.byTooltip('Collapse sidebar'));
    await _layout(tester);
    _expectMode(tester, compact: false, reason: '780 - 72 = 708dp');
    await tester.tap(find.byTooltip('Expand sidebar'));
    await _layout(tester);
    _expectMode(tester, compact: true, reason: 'expanded sidebar again');
    expect(tester.state(find.byType(ProjectPage)), same(projectState));
  });

  testWidgets('project search keeps text and page State across width changes', (
    tester,
  ) async {
    final geometry = geometryFor(tester, width: 900);
    await _show(tester, state, geometry, const ProjectPage());
    final projectState = tester.state(find.byType(ProjectPage));
    await tester.tap(find.byTooltip('Search'));
    await _layout(tester);
    await tester.enterText(find.byType(TextField), 'retained video query');
    for (final width in [599.0, 900.0, 599.0]) {
      geometry.value = (width: width, textScale: 1);
      await _layout(tester);
      _expectMode(tester, compact: width < 600, reason: 'search at $width dp');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'retained video query',
      );
      expect(tester.state(find.byType(ProjectPage)), same(projectState));
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
    }
  });

  testWidgets('a resized log route keeps its window chrome and usable back', (
    tester,
  ) async {
    final geometry = geometryFor(tester);
    await _show(tester, state, geometry, const _LogRoute());
    await tester.tap(find.text('Open logs'));
    await _layout(tester);
    final logState = tester.state(find.byType(LogPage));
    for (final width in [599.0, 900.0, 599.0]) {
      geometry.value = (width: width, textScale: 1);
      await _layout(tester);
      _expectMode(tester, compact: width < 600, reason: 'log route at $width');
      expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
      expect(tester.state(find.byType(LogPage)), same(logState));
      expect(
        find.byType(WindowChromeBar),
        usesWindowChrome ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(DragToMoveArea),
        usesWindowChrome ? findsOneWidget : findsNothing,
      );
      if (usesWindowChrome) {
        final content = find.descendant(
          of: find.byType(LogPage),
          matching: find.byType(Scaffold),
        );
        expect(
          tester.getTopLeft(content).dy,
          tester.getTopLeft(find.byType(LogPage)).dy + kWindowChromeHeight,
        );
      }
    }
    await tester.tap(find.byTooltip('Back'));
    await _layout(tester);
    expect(find.byType(LogPage), findsNothing);
    expect(find.text('Open logs').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expanded glass bars keep their extent and long actions reachable',
    (tester) async {
      final geometry = geometryFor(tester, width: 600);
      var activated = 0;
      for (final style in ['gray', 'theme', 'blur']) {
        state.config.menuStyle = style;
        final before = activated;
        await _show(
          tester,
          state,
          geometry,
          Column(
            children: [
              GlassTopBar(
                title: const Text('Editor', maxLines: 1),
                actions: [
                  for (var index = 0; index < 3; index++)
                    SizedBox(
                      width: 240,
                      child: TextButton(
                        key: ValueKey('wide_action_$index'),
                        onPressed: () => activated++,
                        child: Text('Long workflow action $index'),
                      ),
                    ),
                ],
              ),
              const Expanded(
                child: SizedBox.expand(key: ValueKey('content_below_bar')),
              ),
            ],
          ),
        );
        final bar = find.byType(GlassTopBar);
        expect(tester.getSize(bar).height, GlassTopBar.defaultExtent);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('content_below_bar'))).dy,
          tester.getBottomLeft(bar).dy,
        );
        final actions = find.descendant(
          of: bar,
          matching: find.byType(SingleChildScrollView),
        );
        expect(actions, findsOneWidget);
        await tester.drag(actions, const Offset(-1200, 0));
        await _layout(tester);
        final last = find.byKey(const ValueKey('wide_action_2'));
        expect(last.hitTestable(), findsOneWidget);
        await tester.tap(last);
        expect(activated, before + 1);
        expect(tester.takeException(), isNull, reason: style);
      }
    },
  );
}
