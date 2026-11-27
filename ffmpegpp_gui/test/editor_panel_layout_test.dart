import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/multi_window.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

EditorPanelLayout _layout({
  bool hidden = false,
  bool floating = false,
  bool combinedExternal = false,
  bool elementsExternal = false,
  bool propertiesExternal = false,
}) => EditorPanelLayout.fromState(
  hidden: hidden,
  floating: floating,
  combinedExternal: combinedExternal,
  elementsExternal: elementsExternal,
  propertiesExternal: propertiesExternal,
);

void main() {
  group('EditorPanelLayout', () {
    test('either detached section leaves the other full sidebar height', () {
      for (final detached in [
        DetachedPanel.elements,
        DetachedPanel.properties,
      ]) {
        final layout = _layout(
          elementsExternal: detached == DetachedPanel.elements,
          propertiesExternal: detached == DetachedPanel.properties,
        );
        final heights = layout.sectionHeights(
          maxHeight: 640,
          elementsFraction: 0.4,
          dividerHeight: 10,
        );

        expect(layout.sidebarVisible, isTrue);
        expect(layout.showDivider, isFalse);
        expect(heights.divider, 0);
        if (detached == DetachedPanel.elements) {
          expect(layout.elementsVisible, isFalse);
          expect(heights.elements, 0);
          expect(layout.propertiesVisible, isTrue);
          expect(heights.properties, 640);
        } else {
          expect(layout.elementsVisible, isTrue);
          expect(heights.elements, 640);
          expect(layout.propertiesVisible, isFalse);
          expect(heights.properties, 0);
        }
      }
    });

    test('both separately detached removes sidebar and divider', () {
      final layout = _layout(elementsExternal: true, propertiesExternal: true);
      final heights = layout.sectionHeights(
        maxHeight: 640,
        elementsFraction: 0.4,
        dividerHeight: 10,
      );

      expect(layout.sidebarVisible, isFalse);
      expect(layout.showDivider, isFalse);
      expect(heights.elements, 0);
      expect(heights.properties, 0);
      expect(heights.divider, 0);
      expect(
        layout.canvasWidth(
          maxWidth: 1200,
          canvasFraction: 0.6,
          dividerWidth: 6,
        ),
        1200,
      );
    });

    test('hidden sidebar gives canvas the entire width', () {
      final layout = _layout(hidden: true);

      expect(layout.sidebarVisible, isFalse);
      expect(
        layout.canvasWidth(
          maxWidth: 1200,
          canvasFraction: 0.6,
          dividerWidth: 6,
        ),
        1200,
      );
    });
  });

  group('PipelineEditorPage independent panel controls', () {
    const windowChannel = MethodChannel('window_manager');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, (call) async {
            if (call.method == 'isMaximized') return false;
            throw PlatformException(
              code: 'unexpected_method',
              message: call.method,
            );
          });
      MultiWindowService.debugOpenPanelOverride = null;
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
      MultiWindowService.debugOpenPanelOverride = null;
    });

    testWidgets('opens elements and properties in separate windows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      final openedPanels = <DetachedPanel>[];
      MultiWindowService.debugOpenPanelOverride =
          (panel, lang, width, height) async {
            openedPanels.add(panel);
            return 'test-window-id';
          };

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: PipelineEditorPage(
              video: VideoFile(id: 'panel-layout', filename: 'Template'),
              onSave: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('元素独立窗口'), findsOneWidget);
      expect(find.byTooltip('属性独立窗口'), findsOneWidget);
      // The combined Elements / Properties titlebar must not offer a merged system window.
      expect(find.byTooltip('拖出为独立系统窗口'), findsNothing);

      await tester.tap(find.byTooltip('元素独立窗口'));
      await tester.pump();
      expect(openedPanels, [DetachedPanel.elements]);
      expect(find.byTooltip('元素独立窗口'), findsNothing);
      expect(find.byTooltip('属性独立窗口'), findsOneWidget);

      await tester.tap(find.byTooltip('属性独立窗口'));
      await tester.pump();
      expect(openedPanels, [DetachedPanel.elements, DetachedPanel.properties]);
      expect(find.byTooltip('元素独立窗口'), findsNothing);
      expect(find.byTooltip('属性独立窗口'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
