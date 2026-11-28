import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ads_page.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/pages/container_detail_page.dart';
import 'package:ffmpegpp_gui/pages/credits_page.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/pages/settings_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/adaptive_top_bar.dart';
import 'package:ffmpegpp_gui/widgets/app_card.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/mobile_top_bar.dart';
import 'package:ffmpegpp_gui/widgets/mobile_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Route and layout tests do not need a keychain, settings files or save timers.
class _MemoryConfigService extends ConfigService {
  AppConfig _value = AppConfig();

  @override
  AppConfig get config => _value;

  @override
  Future<void> update(AppConfig Function(AppConfig) transform) async {
    _value = transform(_value);
  }

  @override
  Future<List<Map<String, dynamic>>> loadLibrary() async => [];

  @override
  Future<void> flush() async {}

  @override
  void dispose() {}
}

class _TestState extends AppState {
  final _memoryConfig = _MemoryConfigService();

  @override
  ConfigService get configService => _memoryConfig;
}

typedef _Geometry = ({double width, double textScale});

const _openRouteKey = ValueKey('open-subpage-route');

class _RouteLauncher extends StatelessWidget {
  const _RouteLauncher(this.page);

  final Widget page;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: _openRouteKey,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            allowSnapshotting: false,
            builder: (_) => page,
          ),
        ),
        child: const Text('Open subpage'),
      ),
    ),
  );
}

Widget _harness(
  AppState state,
  ValueNotifier<_Geometry> geometry,
  Widget initialPage,
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
          // Constrain the Navigator as well as its initial page: pushed routes
          // must keep the local pane width while the outer viewport stays wide.
          child: Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              allowSnapshotting: false,
              builder: (_) => initialPage,
            ),
          ),
          builder: (context, value, child) =>
              SizedBox(width: value.width, child: child),
        ),
      ),
    ),
  ),
);

Future<void> _layout(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Finder _header(bool compact) =>
    find.byType(compact ? MobileSubPageTopBar : GlassTopBar);

Finder _returnAction(bool compact, {bool expandedClose = false}) => find
    .descendant(
      of: _header(compact),
      matching: find.byTooltip(!compact && expandedClose ? 'Close' : 'Back'),
    )
    .hitTestable();

void _expectSubpage(
  WidgetTester tester, {
  required bool compact,
  required Finder content,
  bool expandedClose = false,
  String? reason,
}) {
  expect(
    find.byType(MobileSubPageTopBar),
    compact ? findsOneWidget : findsNothing,
    reason: reason,
  );
  expect(
    find.byType(GlassTopBar),
    compact ? findsNothing : findsOneWidget,
    reason: reason,
  );
  expect(
    _returnAction(compact, expandedClose: expandedClose),
    findsOneWidget,
    reason: reason,
  );
  expect(content, findsOneWidget, reason: reason);
  expect(
    tester.getTopLeft(content).dy,
    greaterThanOrEqualTo(tester.getBottomLeft(_header(compact)).dy - 0.5),
    reason: reason ?? 'The first visible content must clear its header',
  );
  expect(tester.takeException(), isNull, reason: reason);
}

class _PageCase {
  const _PageCase(
    this.name,
    this.create,
    this.content, {
    this.stateful = false,
    this.expandedClose = false,
    this.testTextScale = true,
  });

  final String name;
  final Widget Function(_TestState state) create;
  final Finder Function() content;
  final bool stateful;
  final bool expandedClose;
  final bool testTextScale;
}

final _subpages = <_PageCase>[
  _PageCase(
    'AI providers',
    (state) => MobileAiProvidersPage(state: state),
    () => find.byType(AppCard).first,
    testTextScale: false,
  ),
  _PageCase(
    'AI provider detail',
    (state) =>
        const MobileAiProviderDetailPage(profileId: 'responsive-provider'),
    () => find.byType(AppCard).first,
    stateful: true,
  ),
  _PageCase(
    'API keys',
    (state) =>
        MobileMultiKeyPage(keys: const ['fixture-key'], onChanged: (_) {}),
    () => find.text('Keys are rotated in order. Clear a field to remove it.'),
    stateful: true,
  ),
  _PageCase(
    'AI advanced',
    (state) => const MobileAiAdvancedPage(),
    () => find.text('Generation'),
  ),
  _PageCase(
    'container detail',
    (state) => ContainerDetailPage(containerId: state.containers.single.id),
    () => find.text('Empty container, tap + to add files'),
    stateful: true,
  ),
  _PageCase(
    'missing container',
    (state) => const ContainerDetailPage(containerId: 'missing-container'),
    () => find.text('Container not found').last,
    stateful: true,
  ),
  _PageCase(
    'credits',
    (state) => const CreditsPage(),
    () => find.text('This app uses the following open-source projects:'),
    expandedClose: true,
  ),
  _PageCase(
    'ads',
    (state) => const AdsPage(),
    () => find.text('Nothing here yet'),
    expandedClose: true,
  ),
];

void main() {
  const windowChannel = MethodChannel('window_manager');
  late _TestState state;
  bool? previousMobileOverride;
  TargetPlatform? previousTargetPlatform;

  setUp(() {
    previousMobileOverride = debugIsMobilePlatformOverride;
    previousTargetPlatform = debugDefaultTargetPlatformOverride;
    debugIsMobilePlatformOverride = false;
    state = _TestState();
    state.config
      ..language = 'en'
      ..autoCheckUpdate = false
      ..autosaveEnabled = false
      ..aiEnabled = false
      ..nodeMiniMap = false
      ..cardStyle = 'gray'
      ..menuStyle = 'gray'
      ..navStyle = 'gray'
      ..pillStyle = 'gray'
      ..glassEffect = 'gray'
      ..aiProfiles = [
        AiProfile(id: 'responsive-provider', name: 'Responsive provider'),
      ];
    state.addEmptyContainer('Responsive container');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
          if (call.method == 'isMaximized') return false;
          throw PlatformException(
            code: 'unexpected_method',
            message: call.method,
          );
        });
  });

  tearDown(() {
    state.dispose();
    debugIsMobilePlatformOverride = previousMobileOverride;
    debugDefaultTargetPlatformOverride = previousTargetPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  ValueNotifier<_Geometry> geometryFor(
    WidgetTester tester, {
    double width = 599,
  }) {
    tester.view.physicalSize = const Size(2000, 1400);
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

  for (final pageCase in _subpages) {
    testWidgets(pageCase.name + ' route adapts without losing its page state', (
      tester,
    ) async {
      final geometry = geometryFor(tester);
      final page = pageCase.create(state);
      await tester.pumpWidget(_harness(state, geometry, _RouteLauncher(page)));
      await tester.tap(find.byKey(_openRouteKey));
      await _layout(tester);
      final pageState = pageCase.stateful
          ? tester.state(find.byType(page.runtimeType))
          : null;
      if (page is MobileMultiKeyPage) {
        await tester.tap(find.text('Add Key'));
        await _layout(tester);
        expect(find.byType(TextField), findsNWidgets(2));
      }
      final scenarios = <({double width, double scale, bool compact})>[
        (width: 599, scale: 1, compact: true),
        (width: 600, scale: 1, compact: false),
        if (pageCase.testTextScale) ...[
          (width: 899, scale: 1.5, compact: true),
          (width: 900, scale: 1.5, compact: false),
        ],
        if (page is MobileAiProviderDetailPage) ...[
          (width: 899, scale: 2, compact: true),
          (width: 900, scale: 2, compact: false),
        ],
        (width: 599, scale: 1, compact: true),
        (width: 600, scale: 1, compact: false),
      ];
      for (final scenario in scenarios) {
        geometry.value = (width: scenario.width, textScale: scenario.scale);
        await _layout(tester);
        _expectSubpage(
          tester,
          compact: scenario.compact,
          content: pageCase.content(),
          expandedClose: pageCase.expandedClose,
          reason: pageCase.name + ' at ' + scenario.width.toString() + 'dp',
        );
        if (pageState != null) {
          expect(tester.state(find.byType(page.runtimeType)), same(pageState));
        }
        if (page is MobileMultiKeyPage) {
          expect(find.byType(TextField), findsNWidgets(2));
        }
      }
      await tester.tap(
        _returnAction(false, expandedClose: pageCase.expandedClose),
      );
      await _layout(tester);
      expect(find.byKey(_openRouteKey).hitTestable(), findsOneWidget);
      expect(find.byType(page.runtimeType), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      pageCase.name + ' keeps a reachable pill return on wide Android',
      (tester) async {
        debugIsMobilePlatformOverride = true;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final geometry = geometryFor(tester, width: 1200);
          final page = pageCase.create(state);
          await tester.pumpWidget(
            _harness(state, geometry, _RouteLauncher(page)),
          );
          await tester.tap(find.byKey(_openRouteKey));
          await _layout(tester);
          _expectSubpage(tester, compact: true, content: pageCase.content());
          await tester.tap(_returnAction(true));
          await _layout(tester);
          expect(find.byKey(_openRouteKey).hitTestable(), findsOneWidget);
          expect(find.byType(page.runtimeType), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          debugDefaultTargetPlatformOverride = previousTargetPlatform;
          debugIsMobilePlatformOverride = previousMobileOverride;
        }
      },
    );
  }

  testWidgets('a Settings entry pushes the shared adaptive subpage shell', (
    tester,
  ) async {
    // This shell is private. Enter through its real mobile Settings ListTile,
    // then resize the same pushed route on desktop to cover both bar shapes.
    debugIsMobilePlatformOverride = true;
    state.config.fontFamily = 'Fixture font';
    final geometry = geometryFor(tester);
    await tester.pumpWidget(_harness(state, geometry, const SettingsPage()));
    await _layout(tester);
    final settingsState = tester.state(find.byType(SettingsPage));
    final fontEntry = find.widgetWithText(ListTile, 'Font');
    await tester.scrollUntilVisible(
      fontEntry,
      250,
      scrollable: find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(fontEntry);
    await _layout(tester);
    _expectSubpage(tester, compact: true, content: find.byType(AppCard).first);
    final systemFont = find.widgetWithText(ListTile, 'System font (default)');
    expect(systemFont.hitTestable(), findsOneWidget);
    await tester.tap(systemFont);
    await _layout(tester);
    expect(state.config.fontFamily, isEmpty);
    debugIsMobilePlatformOverride = false;
    for (final scenario in [
      (width: 600.0, scale: 1.0, compact: false),
      (width: 599.0, scale: 1.0, compact: true),
      (width: 899.0, scale: 1.5, compact: true),
      (width: 900.0, scale: 1.5, compact: false),
    ]) {
      geometry.value = (width: scenario.width, textScale: scenario.scale);
      await _layout(tester);
      _expectSubpage(
        tester,
        compact: scenario.compact,
        content: find.byType(AppCard).first,
      );
      final header = _header(scenario.compact);
      final expectedExtent = scenario.compact
          ? ImmersiveTopBar.insetOf(tester.element(header))
          : GlassTopBar.defaultExtent;
      expect(tester.getSize(header).height, closeTo(expectedExtent, 0.01));
      final slider = find.byType(AppSlider).first;
      expect(slider.hitTestable(), findsOneWidget);
      final sliderRect = tester.getRect(slider);
      expect(
        sliderRect.top,
        greaterThanOrEqualTo(tester.getBottomLeft(header).dy),
      );
      expect(sliderRect.bottom, lessThanOrEqualTo(1400));
    }
    await tester.tap(_returnAction(false));
    await _layout(tester);
    expect(tester.state(find.byType(SettingsPage)), same(settingsState));
    expect(find.byType(MobileSubPageTopBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editor toolbar uses its local canvas width and retains the canvas',
    (tester) async {
      final geometry = geometryFor(tester, width: 1800);
      final page = PipelineEditorPage(
        video: VideoFile(id: 'responsive-canvas', filename: 'Template'),
        onSave: (_) {},
      );
      await tester.pumpWidget(_harness(state, geometry, _RouteLauncher(page)));
      await tester.tap(find.byKey(_openRouteKey));
      await _layout(tester);
      final editorState = tester.state(find.byType(PipelineEditorPage));
      final canvasState = tester.state(find.byType(InteractiveViewer));
      Finder canvasBar() => find
          .ancestor(
            of: find.text('Node Editor'),
            matching: find.byType(AppTopBarLayout),
          )
          .first;
      for (final scenario in [
        (width: 599.0, scale: 1.0, compact: true),
        (width: 600.0, scale: 1.0, compact: false),
        (width: 899.0, scale: 1.5, compact: true),
        (width: 900.0, scale: 1.5, compact: false),
        (width: 599.0, scale: 1.0, compact: true),
      ]) {
        // Sidebar minimums and maximums make the canvas fraction depend on the
        // local pane width. Re-measure after resizing instead of assuming 60%.
        final targetWidth = scenario.width + (scenario.compact ? 0 : 0.001);
        for (var attempt = 0; attempt < 8; attempt++) {
          final currentWidth = tester.getSize(canvasBar()).width;
          final fraction = currentWidth / geometry.value.width;
          geometry.value = (
            width:
                geometry.value.width + (targetWidth - currentWidth) / fraction,
            textScale: scenario.scale,
          );
          await _layout(tester);
          if ((tester.getSize(canvasBar()).width - targetWidth).abs() <
              0.0001) {
            break;
          }
        }
        expect(
          tester.getSize(canvasBar()).width,
          closeTo(scenario.width, 0.01),
        );
        final pill = find.descendant(
          of: canvasBar(),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is MobileSubPageTopBar || widget is MobilePillTopBar,
          ),
        );
        expect(pill, scenario.compact ? findsOneWidget : findsNothing);
        // The expanded editor keeps its existing toolbar Row, not GlassTopBar.
        expect(
          find.descendant(of: canvasBar(), matching: find.byType(GlassTopBar)),
          findsNothing,
        );
        expect(
          tester.state(find.byType(PipelineEditorPage)),
          same(editorState),
        );
        expect(tester.state(find.byType(InteractiveViewer)), same(canvasState));
        if (scenario.compact) {
          expect(
            tester.getTopLeft(find.byType(InteractiveViewer)).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(pill).dy),
          );
        } else {
          expect(find.byTooltip('Undo'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }
      if (!Platform.isWindows) {
        await tester.tap(
          find
              .descendant(of: canvasBar(), matching: find.byTooltip('Back'))
              .hitTestable(),
        );
        await _layout(tester);
        expect(find.text('Discard changes?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
        await _layout(tester);
        expect(find.byKey(_openRouteKey).hitTestable(), findsOneWidget);
        expect(find.byType(PipelineEditorPage), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
