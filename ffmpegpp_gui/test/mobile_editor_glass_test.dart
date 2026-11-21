import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/liquid_glass_mobile_nav.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _host(AppState state, Widget child, {bool reduced = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduced, highContrast: reduced),
          child: child!,
        ),
        home: child,
      ),
    );

void main() {
  late AppState state;
  bool? previousMobile;

  setUp(() {
    previousMobile = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = true;
    state = AppState();
    state.config
      ..language = 'en'
      ..pillStyle = 'liquid'
      ..glassEffect = 'liquid'
      ..glassBlur = 30
      // Windows also builds its desktop app bar when the mobile gate is forced.
      ..aiEnabled = false
      ..useNodeEditorLandscape = false;
  });

  tearDown(() {
    debugIsMobilePlatformOverride = previousMobile;
    state.dispose();
  });

  Future<void> openEditor(
    WidgetTester tester, {
    bool reduced = false,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        state,
        PipelineEditorPage(
          video: VideoFile(id: 'mobile-glass', filename: 'Template'),
          onSave: (_) {},
        ),
        reduced: reduced,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('editor actions keep 44dp touch targets on shared glass', (
    tester,
  ) async {
    await openEditor(tester);
    for (final label in ['Back', 'Zoom out', 'Zoom in', 'Fit to canvas']) {
      final action = find.byWidgetPredicate(
        (widget) => widget is MobileGlassPillAction && widget.tooltip == label,
      );
      expect(action, findsWidgets);
      for (final element in action.evaluate()) {
        final target = find.byWidget(element.widget);
        final size = tester.getSize(target);
        expect(size.width, greaterThanOrEqualTo(44), reason: label);
        expect(size.height, greaterThanOrEqualTo(44), reason: label);
        expect(
          find.ancestor(of: target, matching: find.byType(MobileGlassPill)),
          findsOneWidget,
        );
      }
    }
    final zoom = find.byTooltip('Zoom in');
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final before = viewer.transformationController!.value.getMaxScaleOnAxis();
    await tester.tapAt(tester.getRect(zoom).centerLeft + const Offset(2, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(before),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('mobile toolbox inherits the shared static accessible material', (
    tester,
  ) async {
    await openEditor(tester, reduced: true);
    final toolbox = find.byTooltip('Toolbox');
    await tester.ensureVisible(toolbox);
    await tester.tap(toolbox);
    await tester.pump();
    expect(find.text('Add Node'), findsOneWidget);
    final surface = find.ancestor(
      of: find.text('Add Node'),
      matching: find.byType(GlassPanel),
    );
    expect(surface, findsOneWidget);
    expect(
      find.descendant(of: surface, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('landscape properties stay below the scaled glass toolbar', (
    tester,
  ) async {
    state.config
      ..useNodeEditorLandscape = true
      ..editorToolbarScale = 1.1;
    await openEditor(tester, reduced: true, size: const Size(844, 390));
    final node = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('node-');
    }).first;
    await tester.tap(node);
    await tester.pump();
    final panel = find.ancestor(
      of: find.byTooltip('Collapse (restore from the top bar)'),
      matching: find.byType(GlassPanel),
    );
    expect(panel, findsOneWidget);
    final toolbar = find.ancestor(
      of: find.byTooltip('Back'),
      matching: find.byType(MobileGlassPill),
    );
    expect(
      tester.getTopLeft(panel).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(toolbar).dy + 7.99),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('provider model actions never fade their live glass', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final profile = AiProfile(name: 'OpenAI', provider: 'openai');
    state.config.aiProfiles.add(profile);
    state.config.activeAiProfileId = profile.id;
    await tester.pumpWidget(
      _host(
        state,
        MobileAiProviderDetailPage(profileId: profile.id),
        reduced: true,
      ),
    );
    await tester.pumpAndSettle();
    final models = find
        .descendant(
          of: find.byType(AppLiquidTabBar),
          matching: find.text('Models'),
        )
        .first;
    await tester.tap(models);
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('provider_models_add_round'));
    expect(action, findsOneWidget);
    expect(
      find.ancestor(of: action, matching: find.byType(AnimatedOpacity)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
