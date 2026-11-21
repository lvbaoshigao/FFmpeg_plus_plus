import 'dart:io';

import 'package:ffmpegpp_gui/models/quick_config.dart';
import 'package:ffmpegpp_gui/pages/quick_config_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_alert_dialog.dart';
import 'package:ffmpegpp_gui/widgets/app_dropdown.dart';
import 'package:ffmpegpp_gui/widgets/font_picker.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/image_crop_dialog.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/video_crop_step_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> _host(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(320, 640),
  double scale = 1.8,
  double keyboard = 0,
  AppState? state,
  ValueNotifier<double>? scaleController,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  Widget app = MaterialApp(
    theme: AppTheme.dark(),
    builder: (context, child) {
      Widget scaled(double value) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(value)),
        child: child!,
      );
      return scaleController == null
          ? scaled(scale)
          : ValueListenableBuilder<double>(
              valueListenable: scaleController,
              builder: (_, value, _) => scaled(value),
            );
    },
    home: Scaffold(body: child),
  );
  if (state != null) {
    app = ChangeNotifierProvider<AppState>.value(value: state, child: app);
  }
  await tester.pumpWidget(app);
}

void _expectPill(WidgetTester tester, String label) {
  final action = find.ancestor(
    of: find.text(label),
    matching: find.byType(AppDialogAction),
  );
  expect(action, findsOneWidget);
  expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
}

Future<void> _cacheImage(WidgetTester tester, Iterable<int> widths) async {
  final context = tester.element(find.byType(Scaffold));
  await tester.runAsync(() async {
    for (final width in widths) {
      await precacheImage(
        ResizeImage(FileImage(File('rele/icon.png').absolute), width: width),
        context,
      );
    }
  });
}

void main() {
  testWidgets(
    'font picker remains dismissible with a keyboard and large text',
    (tester) async {
      await _host(
        tester,
        FontPicker(currentFont: 'Arial', onSelected: (_) {}, language: 'en'),
        size: const Size(320, 560),
        keyboard: 220,
      );
      await tester.tap(find.byType(FontPicker));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      _expectPill(tester, 'Cancel');
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets(
    'quick editor keeps accessible modal actions in a narrow viewport',
    (tester) async {
      final state = AppState()..config.language = 'en';
      addTearDown(state.dispose);
      await _host(
        tester,
        QuickConfigPage(
          config: QuickConfig(
            id: 'test',
            fileType: QuickFileType.video,
            name: 'A long configuration title',
          ),
          onSave: (_) async {},
        ),
        state: state,
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      _expectPill(tester, 'Cancel');
      _expectPill(tester, 'Save');
    },
  );

  testWidgets(
    'quick editor keeps title, actions, selector and editing reachable with large text and IME',
    (tester) async {
      final state = AppState()..config.language = 'en';
      addTearDown(state.dispose);
      QuickConfig? saved;
      await _host(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<QuickConfig>(
              context: context,
              barrierDismissible: false,
              builder: (_) => QuickConfigPage(
                config: QuickConfig(
                  id: 'compact',
                  fileType: QuickFileType.video,
                  name: 'Quick configuration',
                  items: [
                    QuickConfigItem(
                      key: 'first',
                      title: 'First item',
                      params: {'label': 'First value'},
                    ),
                    QuickConfigItem(
                      key: 'second',
                      title: 'Second item',
                      params: {'label': 'Second value'},
                    ),
                  ],
                ),
                onSave: (config) async => saved = config,
              ),
            ),
            child: const Text('Open editor'),
          ),
        ),
        state: state,
        size: const Size(320, 560),
        scale: 2.6,
        keyboard: 300,
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();

      expect(find.text('Quick configuration'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Quick configuration'));
      expect(
        tester.getRect(find.text('Quick configuration')).bottom,
        lessThanOrEqualTo(260),
      );
      _expectPill(tester, 'Cancel');
      _expectPill(tester, 'Save');
      for (final label in ['Cancel', 'Save']) {
        final action = find.ancestor(
          of: find.text(label),
          matching: find.byType(AppDialogAction),
        );
        await tester.ensureVisible(action);
        expect(tester.getRect(action).top, greaterThanOrEqualTo(0));
        expect(tester.getRect(action).bottom, lessThanOrEqualTo(260));
      }

      final selector = find.byType(AppDropdown<String>);
      expect(selector, findsOneWidget);
      await tester.ensureVisible(selector);
      expect(tester.getRect(selector).bottom, lessThanOrEqualTo(260));
      final selectorTrigger = find.descendant(
        of: selector,
        matching: find.text('First item'),
      );
      await tester.tap(selectorTrigger);
      await tester.pumpAndSettle();
      final secondItem = find.text('Second item').last;
      final menuPanel = find.ancestor(
        of: secondItem,
        matching: find.byType(ClipRRect),
      );
      expect(tester.getRect(menuPanel).top, greaterThanOrEqualTo(0));
      expect(tester.getRect(menuPanel).bottom, lessThanOrEqualTo(260));
      await tester.drag(find.byType(ListView).last, const Offset(0, -96));
      await tester.pumpAndSettle();
      expect(tester.getRect(secondItem).top, greaterThanOrEqualTo(0));
      expect(tester.getCenter(secondItem).dy, lessThanOrEqualTo(260));
      await tester.tap(secondItem);
      await tester.pumpAndSettle();

      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).controller!.text, 'Second value');
      await tester.ensureVisible(field);
      expect(tester.getRect(field).bottom, lessThanOrEqualTo(260));
      await tester.enterText(field, 'Edited value');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.takeException(), isNull);

      final save = find.widgetWithText(FilledButton, 'Save');
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      expect(tester.getRect(save).top, greaterThanOrEqualTo(0));
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(260));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved?.items[1].params['label'], 'Edited value');
      expect(find.byType(QuickConfigPage), findsNothing);

      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      final cancel = find.widgetWithText(TextButton, 'Cancel');
      await tester.ensureVisible(cancel);
      expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(260));
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(find.byType(QuickConfigPage), findsNothing);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'quick editor stays editable with a short keyboard viewport at $scale',
      (tester) async {
        final state = AppState()..config.language = 'en';
        addTearDown(state.dispose);
        await _host(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<QuickConfig>(
                context: context,
                barrierDismissible: false,
                builder: (_) => QuickConfigPage(
                  config: QuickConfig(
                    id: 'keyboard',
                    fileType: QuickFileType.video,
                    name: 'Keyboard configuration',
                    items: [
                      QuickConfigItem(
                        key: 'custom',
                        title: 'Custom item',
                        params: {'label': 'Original'},
                      ),
                      QuickConfigItem(
                        key: 'second',
                        title: 'Second item',
                        params: {'label': 'Second'},
                      ),
                    ],
                  ),
                  onSave: (_) async {},
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
          state: state,
          size: const Size(390, 640),
          keyboard: 300,
          scale: scale,
        );
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _expectPill(tester, 'Cancel');
        _expectPill(tester, 'Save');
        final selector = find.byType(AppDropdown<String>);
        expect(selector, findsOneWidget);
        await tester.ensureVisible(selector);
        final selectorTrigger = find.descendant(
          of: selector,
          matching: find.text('Custom item'),
        );
        await tester.tap(selectorTrigger.last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Second item').last);
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        expect(tester.widget<TextField>(field).controller!.text, 'Second');
        await tester.ensureVisible(field);
        await tester.enterText(field, 'Edited');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
              .onPressed,
          isNotNull,
        );
      },
    );
  }

  testWidgets(
    'image crop keeps source coordinates and touch-sized paired actions',
    (tester) async {
      debugIsMobilePlatformOverride = true;
      addTearDown(() => debugIsMobilePlatformOverride = null);
      Rect? result;
      await _host(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showImageCropDialog(
              context,
              imagePath: File('rele/icon.png').absolute.path,
              imageSize: const Size(1920, 1080),
              initialRect: const Rect.fromLTWH(0, 0, 1920, 1080),
              isZh: false,
            ),
            child: const Text('Open crop'),
          ),
        ),
      );
      await _cacheImage(tester, [320]);
      await tester.tap(find.text('Open crop'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      _expectPill(tester, 'Cancel');
      _expectPill(tester, 'Apply');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(result, const Rect.fromLTWH(0, 0, 1920, 1080));
    },
  );

  testWidgets('video crop adapts its header and action rows to large text', (
    tester,
  ) async {
    final path = File('rele/icon.png').absolute.path;
    final scale = ValueNotifier<double>(1);
    final params = <String, dynamic>{};
    addTearDown(scale.dispose);
    await _host(
      tester,
      VideoCropStepEditor(
        params: params,
        onChanged: () {},
        videoPath: 'test.mp4',
        videoWidth: 1920,
        videoHeight: 1080,
        fps: 30,
        isZh: false,
        generatePreview: (_, _, {width = 480}) async => path,
        generateFullFrame: (_, _) async => path,
      ),
      size: const Size(390, 844),
      scale: 1,
      scaleController: scale,
    );
    await _cacheImage(tester, [960, 351]);
    await tester.tap(find.text('Extract'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Selection Tool'));
    await tester.pumpAndSettle();
    scale.value = 1.8;
    await tester.pump();

    expect(tester.takeException(), isNull);
    _expectPill(tester, 'Cancel');
    _expectPill(tester, 'Save');
  });
}
