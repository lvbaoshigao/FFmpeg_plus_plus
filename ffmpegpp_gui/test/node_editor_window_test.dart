import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:ffmpegpp_gui/widgets/node_editor_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> _mount(
  WidgetTester tester,
  Size size, {
  bool mobile = false,
  EdgeInsets safeArea = EdgeInsets.zero,
  double zoomScale = 1,
}) async {
  debugIsMobilePlatformOverride = mobile;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState();
  addTearDown(state.dispose);
  state.config
    ..language = 'en'
    ..aiEnabled = false
    ..glassEffect = 'blur'
    ..editorZoomScale = zoomScale
    ..useNodeEditorLandscape = size.width > size.height && mobile;
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: safeArea, viewPadding: safeArea),
          child: child!,
        ),
        home: PipelineEditorPage(
          video: VideoFile(id: 'window-regression', filename: 'Template'),
          onSave: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  bool? previousMobile;
  const windowChannel = MethodChannel('window_manager');
  setUp(() {
    previousMobile = debugIsMobilePlatformOverride;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (_) async => false);
  });
  tearDown(() {
    debugIsMobilePlatformOverride = previousMobile;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  test(
    'collapsed sections release their space while keeping headers reachable',
    () {
      final layout = EditorPanelLayout.fromState(
        hidden: false,
        floating: false,
        combinedExternal: false,
        elementsExternal: false,
        propertiesExternal: false,
      );
      final heights = layout.sectionHeights(
        maxHeight: 600,
        elementsFraction: 0.4,
        dividerHeight: 12,
        elementsExpanded: false,
        headerHeight: 44,
      );
      expect(heights.elements, 44);
      expect(heights.properties, 556);
      expect(heights.divider, 0);
      final short = layout.sectionHeights(
        maxHeight: 40,
        elementsFraction: 0.99,
        dividerHeight: 12,
      );
      expect(short.elements + short.properties + short.divider, 40);
      expect(short.elements, greaterThanOrEqualTo(0));
      expect(short.properties, greaterThanOrEqualTo(0));
    },
  );

  testWidgets('collapse, float, resize and hide preserve the live editor', (
    tester,
  ) async {
    await _mount(tester, const Size(1400, 900));
    final frame = find.byType(NodeEditorPanelFrame);
    final frameElement = frame.evaluate().single;
    final query = find.byKey(const ValueKey('node-picker-query'));
    final queryElement = query.evaluate().single;
    await tester.enterText(query, 'crop');
    await tester.pump();
    final properties = find.byKey(const ValueKey('editor-properties-section'));
    final beforeProperties = tester.getSize(properties).height;
    final elementsHeader = find.descendant(
      of: find.byKey(const ValueKey('editor-elements-section')),
      matching: find.text('Elements'),
    );
    await tester.tap(elementsHeader);
    await tester.pump();
    expect(tester.getSize(properties).height, greaterThan(beforeProperties));
    expect(queryElement.mounted, isTrue);
    await tester.tap(elementsHeader);
    await tester.pump();
    await tester.tap(find.byTooltip('Float out'));
    await tester.pump();
    expect(frame.evaluate().single, same(frameElement));
    final beforeWidth = tester.getSize(frame).width;
    await tester.drag(
      find.byKey(const ValueKey('editor-floating-panel-resize')),
      const Offset(80, 0),
    );
    await tester.pump();
    expect(tester.getSize(frame).width, greaterThan(beforeWidth));
    expect(queryElement.mounted, isTrue);
    await tester.tap(find.byTooltip('Hide'));
    await tester.pump();
    expect(frameElement.mounted, isTrue);
    await tester.tap(find.byTooltip('Expand elements / properties').last);
    await tester.pump();
    expect(frame.evaluate().single, same(frameElement));
    expect(tester.widget<TextField>(query).controller!.text, 'crop');
    await tester.tap(find.byTooltip('Dock back'));
    await tester.pump();
    expect(frame.evaluate().single, same(frameElement));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'short narrow desktop windows keep forms and rail actions accessible',
    (tester) async {
      await _mount(tester, const Size(650, 420));
      final frame = find.byType(NodeEditorPanelFrame);
      expect(tester.getSize(frame).width, greaterThanOrEqualTo(320));
      final toolbar = find.byKey(const ValueKey('editor-desktop-toolbar'));
      expect(
        tester.getRect(toolbar).bottom,
        lessThanOrEqualTo(tester.getRect(frame).top),
      );
      final rail = find.byType(NodeEditorToolRail);
      expect(
        tester.getRect(rail).right,
        lessThanOrEqualTo(tester.getRect(frame).left),
      );
      final beforeWidth = tester.getSize(frame).width;
      await tester.drag(
        find.byKey(const ValueKey('editor-overlay-panel-resize')),
        const Offset(-24, 0),
      );
      await tester.pump();
      expect(tester.getSize(frame).width, greaterThan(beforeWidth));
      final hideLogic = find.byTooltip('Hide logic');
      await tester.ensureVisible(hideLogic);
      await tester.tap(hideLogic);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final scenario in [
    (
      name: 'portrait',
      size: const Size(390, 844),
      safeArea: const EdgeInsets.fromLTRB(24, 44, 20, 34),
    ),
    (
      name: 'narrow portrait',
      size: const Size(320, 700),
      safeArea: const EdgeInsets.fromLTRB(30, 30, 30, 24),
    ),
    (
      name: 'landscape',
      size: const Size(844, 390),
      safeArea: const EdgeInsets.fromLTRB(60, 12, 30, 24),
    ),
  ]) {
    testWidgets(
      'mobile ${scenario.name} keeps chrome inside safe area with a full canvas',
      (tester) async {
        await _mount(
          tester,
          scenario.size,
          mobile: true,
          safeArea: scenario.safeArea,
          zoomScale: 1.6,
        );
        final bodyBounds = tester.getRect(
          find.descendant(
            of: find.byType(PipelineEditorPage),
            matching: find.byType(Scaffold),
          ),
        );
        final safeBounds = Rect.fromLTRB(
          bodyBounds.left + scenario.safeArea.left,
          bodyBounds.top + scenario.safeArea.top,
          bodyBounds.right - scenario.safeArea.right,
          bodyBounds.bottom - scenario.safeArea.bottom,
        );
        final toolbar = find.byKey(const ValueKey('editor-mobile-toolbar'));
        expect(
          tester.getRect(toolbar).left,
          greaterThanOrEqualTo(safeBounds.left + 8),
        );
        expect(
          tester.getRect(toolbar).right,
          lessThanOrEqualTo(safeBounds.right - 8),
        );
        expect(tester.getRect(toolbar).top, closeTo(safeBounds.top + 8, 0.01));
        expect(
          tester
              .getSize(
                find.ancestor(
                  of: find.byType(InteractiveViewer),
                  matching: find.byType(GlassPanel),
                ),
              )
              .width,
          bodyBounds.width,
        );
        final zoom = find.ancestor(
          of: find.byTooltip('Zoom out'),
          matching: find.byType(MobileGlassPill),
        );
        expect(tester.getRect(zoom).left, closeTo(safeBounds.left + 8, 0.01));
        expect(
          tester.getRect(zoom).bottom,
          closeTo(safeBounds.bottom - 6, 0.01),
        );

        final info = find.byKey(const ValueKey('editor-mobile-file-info'));
        expect(
          tester.getRect(info).left,
          greaterThanOrEqualTo(tester.getRect(zoom).right + 8),
        );
        expect(tester.getRect(info).right, lessThanOrEqualTo(safeBounds.right));
        final more = find.byTooltip('More actions');
        await tester.ensureVisible(more);
        await tester.pump();
        expect(more.hitTestable(), findsOneWidget);

        final node = find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> && key.value.startsWith('node-');
        }).first;
        await tester.tap(node);
        await tester.pump();
        final frame = find.byType(NodeEditorPanelFrame);
        void expectSafePanel() {
          final bounds = tester.getRect(frame);
          expect(bounds.left, greaterThanOrEqualTo(safeBounds.left));
          expect(bounds.right, lessThanOrEqualTo(safeBounds.right));
          expect(
            bounds.top,
            greaterThanOrEqualTo(tester.getRect(toolbar).bottom + 8),
          );
          expect(bounds.bottom, lessThanOrEqualTo(safeBounds.bottom));
        }

        expectSafePanel();
        await tester.tap(find.byTooltip('Float out'));
        await tester.pump();
        await tester.dragFrom(
          tester.getTopLeft(frame) + const Offset(70, 24),
          const Offset(-1000, -1000),
        );
        await tester.pump();
        expectSafePanel();
        await tester.dragFrom(
          tester.getTopLeft(frame) + const Offset(70, 24),
          const Offset(1000, 1000),
        );
        await tester.pump();
        expectSafePanel();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets(
    'mobile properties resize, float and restore the selected editor',
    (tester) async {
      await _mount(tester, const Size(390, 844), mobile: true);
      final node = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('node-');
      }).first;
      await tester.tap(node);
      await tester.pump();
      final frame = find.byType(NodeEditorPanelFrame);
      final element = frame.evaluate().single;
      final width = tester.getSize(frame).width;
      await tester.drag(
        find.byKey(const ValueKey('editor-mobile-panel-resize')),
        const Offset(40, 0),
      );
      await tester.pump();
      expect(tester.getSize(frame).width, lessThan(width));
      await tester.tap(find.byTooltip('Float out'));
      await tester.pump();
      expect(frame.evaluate().single, same(element));
      await tester.tap(find.byTooltip('Minimize'));
      await tester.pump();
      expect(tester.getSize(frame).height, 48);
      await tester.tap(find.byTooltip('Expand'));
      await tester.pump();
      await tester.tap(find.byTooltip('Collapse (restore from the top bar)'));
      await tester.pump();
      expect(element.mounted, isTrue);
      await tester.tap(find.byTooltip('Show properties'));
      await tester.pump();
      expect(frame.evaluate().single, same(element));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
