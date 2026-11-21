import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/app.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/app_alert_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const double _pixelRatio = 2;

Future<String?> _loadPreviewFont() async {
  final fonts = [
    if (Platform.isWindows)
      '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/msyh.ttc',
    if (Platform.isWindows)
      '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/segoeui.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    '/System/Library/Fonts/Supplemental/Arial.ttf',
  ];
  for (final path in fonts) {
    final font = File(path);
    if (!await font.exists()) continue;
    final bytes = await font.readAsBytes();
    await (FontLoader(
      'PreviewUI',
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    return 'PreviewUI';
  }
  return null;
}

Future<Uint8List> _makeBackdrop() async {
  const sourceSize = Size(786, 1704);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final bounds = Offset.zero & sourceSize;
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(786, 1704),
        [Color(0xFF11172A), Color(0xFF203B4D), Color(0xFF221B32)],
        [0, 0.5, 1],
      ),
  );
  canvas.drawCircle(
    const Offset(130, 265),
    330,
    Paint()
      ..shader = ui.Gradient.radial(const Offset(130, 265), 330, [
        const Color(0xFFDF68A0).withValues(alpha: 0.76),
        const Color(0xFFDF68A0).withValues(alpha: 0),
      ]),
  );
  canvas.drawCircle(
    const Offset(700, 800),
    470,
    Paint()
      ..shader = ui.Gradient.radial(const Offset(700, 800), 470, [
        const Color(0xFF43C5BD).withValues(alpha: 0.62),
        const Color(0xFF43C5BD).withValues(alpha: 0),
      ]),
  );
  canvas.drawCircle(
    const Offset(310, 1450),
    390,
    Paint()
      ..shader = ui.Gradient.radial(const Offset(310, 1450), 390, [
        const Color(0xFFE6A85F).withValues(alpha: 0.5),
        const Color(0xFFE6A85F).withValues(alpha: 0),
      ]),
  );
  final artPaint = Paint();
  final art = RRect.fromRectAndRadius(
    const Rect.fromLTWH(54, 320, 315, 205),
    const Radius.circular(34),
  );
  artPaint.shader = ui.Gradient.linear(
    Offset(54, 320),
    Offset(369, 525),
    [Color(0xFFF1A167), Color(0xFFC45F8D), Color(0xFF684B99)],
    [0, 0.56, 1],
  );
  canvas.drawRRect(art, artPaint);
  canvas.drawCircle(
    const Offset(290, 378),
    30,
    Paint()..color = const Color(0xFFFFE4A9).withValues(alpha: 0.9),
  );
  final hill = Path()
    ..moveTo(54, 470)
    ..cubicTo(150, 385, 218, 525, 369, 423)
    ..lineTo(369, 525)
    ..lineTo(54, 525)
    ..close();
  canvas.drawPath(
    hill,
    Paint()..color = const Color(0xFF347E71).withValues(alpha: 0.86),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(786, 1704);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<Uint8List> _makeFlatBackdrop() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xFF24252A), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(786, 1704);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

class _PreviewState extends AppState {
  void refresh() => notifyListeners();
}

void main() {
  testWidgets('renders distinct live mobile glass previews', (tester) async {
    tester.view.physicalSize = const Size(786, 1704);
    tester.view.devicePixelRatio = _pixelRatio;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);

    final oldPlatformOverride = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = true;
    final temp = Directory.systemTemp.createTempSync(
      'ffmpegpp-mobile-preview-',
    );
    final state = _PreviewState();
    final captureKey = GlobalKey();
    addTearDown(() async {
      debugIsMobilePlatformOverride = oldPlatformOverride;
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    final wallpaper = File('${temp.path}/generated_mobile_wallpaper.png');
    final flatBackground = File('${temp.path}/generated_mobile_solid.png');
    String? previewFont;
    final inputsSaved = await tester.runAsync(() async {
      previewFont = await _loadPreviewFont();
      await wallpaper.writeAsBytes(await _makeBackdrop());
      await flatBackground.writeAsBytes(await _makeFlatBackdrop());
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      return true;
    });
    expect(inputsSaved, isTrue);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final preloadContext = tester.element(find.byType(SizedBox).last);
    await tester.runAsync(() async {
      for (final source in [wallpaper, flatBackground]) {
        await precacheImage(
          wallpaperImageProvider(source.path, 393, 852, _pixelRatio),
          preloadContext,
        );
      }
    });
    state.config
      ..darkMode = true
      ..language = 'en'
      ..backgroundImage = wallpaper.absolute.path
      ..backgroundOpacity = 1
      ..pillStyle = 'liquid'
      ..navStyle = 'liquid'
      ..cardStyle = 'liquid'
      ..menuStyle = 'liquid'
      ..cardOpacity = 0.76
      ..glassClarity = 0.66
      ..glassBlur = 9
      ..glassHighlight = 1.1
      ..glassEdge = 1.15;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(fontFamily: previewFont ?? ''),
            home: const AppShell(mobile: true),
          ),
        ),
      ),
    );
    final wallpaperDecoded = await tester.runAsync(() async {
      await precacheImage(
        wallpaperImageProvider(wallpaper.path, 393, 852, _pixelRatio),
        tester.element(find.byType(AppShell)),
      );
      return true;
    });
    expect(wallpaperDecoded, isTrue);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.text('Projects'), findsWidgets);
    expect(find.text('Queue'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final renderBoundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;

    Future<Uint8List> capture({Rect? region}) async {
      final image = await tester.runAsync(
        () => renderBoundary.toImage(pixelRatio: _pixelRatio),
      );
      ui.Image output = image!;
      if (region != null) {
        output = (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          final width = (region.width * _pixelRatio).ceil();
          final height = (region.height * _pixelRatio).ceil();
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(
              region.left * _pixelRatio,
              region.top * _pixelRatio,
              width.toDouble(),
              height.toDouble(),
            ),
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
            Paint(),
          );
          final picture = recorder.endRecording();
          try {
            return await picture.toImage(width, height);
          } finally {
            picture.dispose();
          }
        }))!;
      }
      final data = await tester.runAsync(
        () => output.toByteData(format: ui.ImageByteFormat.png),
      );
      final bytes = data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (!identical(output, image)) output.dispose();
      image.dispose();
      return bytes;
    }

    Future<void> savePreview(String filename, Uint8List bytes) async {
      final saved = await tester.runAsync(() async {
        final output = Directory('preview')..createSync(recursive: true);
        await File.fromUri(output.uri.resolve(filename)).writeAsBytes(bytes);
        return true;
      });
      expect(saved, isTrue);
    }

    final wallpaperPreview = await capture();
    await savePreview('mobile-glass-wallpaper.png', wallpaperPreview);

    final dialogContext = tester.element(find.byType(AppShell));
    final result = showDialog<bool>(
      context: dialogContext,
      builder: (context) => AppAlertDialog(
        title: const Text('提示'),
        content: const Text('您确定要强制重启核心吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final dialogMaterial = find
        .descendant(
          of: find.byType(Dialog),
          matching: find.byWidgetPredicate(
            (widget) => widget is Material && widget.shape != null,
          ),
        )
        .first;
    final dialogBounds = tester.getRect(dialogMaterial).inflate(8);
    await savePreview(
      'dialog-mobile-dark.png',
      await capture(region: dialogBounds),
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(tester.takeException(), isNull);

    state.config.backgroundImage = flatBackground.absolute.path;
    state.refresh();
    await tester.pump();
    final flatDecoded = await tester.runAsync(() async {
      await precacheImage(
        wallpaperImageProvider(flatBackground.path, 393, 852, _pixelRatio),
        tester.element(find.byType(AppShell)),
      );
      return true;
    });
    expect(flatDecoded, isTrue);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    final flatPreview = await capture();
    expect(
      flatPreview,
      isNot(wallpaperPreview),
      reason: 'The generated wallpaper and flat backdrop must be distinct.',
    );
    await savePreview('mobile-glass-solid.png', flatPreview);
  });

  testWidgets('renders desktop dialog previews in dark and light themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final font = await tester.runAsync(_loadPreviewFont);
    for (final dark in [true, false]) {
      final captureKey = GlobalKey();
      Future<bool?>? result;
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme:
                (dark
                        ? AppTheme.dark(fontFamily: font ?? '')
                        : AppTheme.light(fontFamily: font ?? ''))
                    .copyWith(platform: TargetPlatform.windows),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () {
                      result = showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AppAlertDialog(
                          title: const Text('提示'),
                          content: const Text('您确定要强制重启核心吗？'),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('确定'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: const Text('Open dialog'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final data = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.png),
      );
      image!.dispose();
      await tester.runAsync(() async {
        final output = Directory('preview');
        await output.create(recursive: true);
        await File.fromUri(
          output.uri.resolve('dialog-desktop-${dark ? 'dark' : 'light'}.png'),
        ).writeAsBytes(
          data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      });
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(find.byType(AppAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
