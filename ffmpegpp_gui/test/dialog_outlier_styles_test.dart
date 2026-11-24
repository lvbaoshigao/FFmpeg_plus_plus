import 'dart:io';

import 'package:ffmpegpp_gui/models/quick_config.dart';
import 'package:ffmpegpp_gui/pages/quick_config_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/font_picker.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/image_crop_dialog.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/video_crop_step_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _surface = Color(0xFF25272A);
const _shape = ContinuousRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(24)),
  side: BorderSide(color: Color(0xFF62666C)),
);
const _dialogTheme = DialogThemeData(
  shape: _shape,
  backgroundColor: _surface,
  surfaceTintColor: Colors.transparent,
  constraints: BoxConstraints(maxWidth: 560),
);

Future<void> _pumpHost(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1000, 800),
  FakeViewPadding padding = const FakeViewPadding(),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        dialogTheme: _dialogTheme,
      ),
      home: Scaffold(body: child),
    ),
  );
}

Material _dialogMaterial(WidgetTester tester) => tester.widget<Material>(
  find
      .descendant(of: find.byType(Dialog), matching: find.byType(Material))
      .first,
);

void _expectThemedSurface(Material material) {
  expect(material.shape, _shape);
  expect(material.color, _surface);
}

Future<void> _cacheCropImage(WidgetTester tester, Iterable<int> widths) async {
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
  test('ordinary app-owned alerts use the shared component', () {
    final rawAlert = RegExp(r'\bAlertDialog(?:\.adaptive)?\s*\(');
    final outliers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              file.path.endsWith('.dart') &&
              !file.path.endsWith('app_alert_dialog.dart'),
        )
        .where((file) => rawAlert.hasMatch(file.readAsStringSync()))
        .map((file) => file.path)
        .toList();
    expect(
      outliers,
      isEmpty,
      reason: 'Route ordinary alerts through AppAlertDialog.',
    );
  });

  testWidgets('font picker inherits the Material 3 dialog surface', (
    tester,
  ) async {
    await _pumpHost(
      tester,
      FontPicker(currentFont: 'Arial', onSelected: (_) {}, language: 'en'),
    );
    await tester.tap(find.byType(FontPicker));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    _expectThemedSurface(_dialogMaterial(tester));
    expect(find.text('Select Font'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump(const Duration(milliseconds: 300));
  });

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('quick config keeps themed edges and safe insets at $size', (
      tester,
    ) async {
      final app = AppState();
      addTearDown(app.dispose);
      await _pumpHost(
        tester,
        ChangeNotifierProvider.value(
          value: app,
          child: QuickConfigPage(
            config: QuickConfig(
              id: 'test',
              fileType: QuickFileType.video,
              name: 'Test',
            ),
            onSave: (_) async {},
          ),
        ),
        size: size,
      );
      await tester.pumpAndSettle();

      _expectThemedSurface(_dialogMaterial(tester));
      final rect = tester.getRect(find.byWidget(_dialogMaterial(tester)));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(size.width - 16));
      if (size.width > 760) expect(rect.width, greaterThan(560));
      expect(tester.takeException(), isNull);
    });
  }

  for (final (mobile, size) in [
    (false, const Size(390, 844)),
    (true, const Size(390, 844)),
    (true, const Size(844, 390)),
  ]) {
    testWidgets(
      'image crop follows dialog theme while preserving fullscreen=$mobile at $size',
      (tester) async {
        debugIsMobilePlatformOverride = mobile;
        addTearDown(() => debugIsMobilePlatformOverride = null);
        await _pumpHost(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showImageCropDialog(
                context,
                imagePath: File('rele/icon.png').absolute.path,
                imageSize: const Size(1920, 1080),
                initialRect: const Rect.fromLTWH(0, 0, 1920, 1080),
                isZh: false,
              ),
              child: const Text('Open'),
            ),
          ),
          size: size,
          padding: mobile
              ? const FakeViewPadding(top: 24, bottom: 16)
              : const FakeViewPadding(),
        );
        final imageWidth = !mobile
            ? size.width * .86
            : size.width >= size.height * 1.15
            ? size.width - (size.width * .36).clamp(232.0, 300.0)
            : size.width;
        await _cacheCropImage(tester, [imageWidth.round()]);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        final crop = find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_ImageCropDialog',
        );
        final materialFinder = find
            .descendant(of: crop, matching: find.byType(Material))
            .first;
        final material = tester.widget<Material>(materialFinder);
        if (mobile) {
          expect(tester.getSize(materialFinder), size);
          expect(
            (material.shape as RoundedRectangleBorder).borderRadius,
            BorderRadius.zero,
          );
        } else {
          _expectThemedSurface(material);
          expect(
            tester.getSize(materialFinder).width,
            closeTo(size.width * .86, .01),
          );
        }
        final imageRect = tester.getRect(find.byType(Image));
        expect(imageRect.width / imageRect.height, closeTo(1920 / 1080, .001));
        if (mobile) {
          expect(imageRect.top, greaterThanOrEqualTo(24));
          expect(imageRect.bottom, lessThanOrEqualTo(size.height - 16));
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'video crop clips to its dialog shape without repainting the surface',
    (tester) async {
      final path = File('rele/icon.png').absolute.path;
      await _pumpHost(
        tester,
        VideoCropStepEditor(
          // The editor initializes missing parameter defaults in this map.
          // ignore: prefer_const_literals_to_create_immutables
          params: {},
          onChanged: () {},
          videoPath: 'test.mp4',
          videoWidth: 1920,
          videoHeight: 1080,
          fps: 30,
          isZh: false,
          generatePreview: (_, _, {width = 480}) async => path,
          generateFullFrame: (_, _) async => path,
        ),
      );
      await _cacheCropImage(tester, [960, 900]);
      await tester.tap(find.text('Extract'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Selection Tool'));
      await tester.pumpAndSettle();

      final material = _dialogMaterial(tester);
      _expectThemedSurface(material);
      expect(material.clipBehavior, Clip.antiAlias);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(ClipRRect),
        ),
        findsNothing,
      );
      expect(tester.getSize(find.byWidget(material)).width, greaterThan(560));
      final image = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Image),
      );
      final imageSize = tester.getSize(image);
      expect(imageSize.width / imageSize.height, closeTo(1920 / 1080, .001));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
    },
  );
}
