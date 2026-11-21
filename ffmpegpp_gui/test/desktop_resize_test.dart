import 'dart:async';
import 'dart:io';

import 'package:ffmpegpp_gui/app.dart' show wallpaperImageProvider;

import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:ffmpegpp_gui/widgets/desktop_resize_scope.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/wallpaper_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  group('DesktopResizeScope', () {
    testWidgets(
      'should resume blur on the same controls after resizing',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: const MaterialApp(
              home: DesktopResizeScope(
                child: Scaffold(
                  body: Center(
                    child: GlassPanel(
                      style: 'blur',
                      child: SizedBox(
                        width: 200,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [TextField(), AppTrackGlass(height: 8)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final field = find.byType(TextField);
        final element = tester.element(field);
        final backdrop = find.byType(BackdropFilter);
        expect(backdrop, findsNWidgets(2));
        void expectBlurEnabled(bool enabled) => expect(
          tester.widgetList<BackdropFilter>(backdrop).map((w) => w.enabled),
          everyElement(enabled),
        );
        expectBlurEnabled(true);
        await tester.enterText(field, 'keep me');

        tester.view.physicalSize = const Size(900, 650);
        await tester.pump(const Duration(milliseconds: 100));
        expectBlurEnabled(false);
        tester.view.physicalSize = const Size(960, 720);
        await tester.pump(const Duration(milliseconds: 100));
        expectBlurEnabled(false);
        expect(tester.element(field), same(element));

        await tester.pump(const Duration(milliseconds: 60));
        expectBlurEnabled(true);
        expect(tester.element(field), same(element));
        expect(find.text('keep me'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      skip: !isDesktopPlatform,
    );

    testWidgets(
      'should keep the decoded wallpaper through a resize burst',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final path = File('rele/icon.png').absolute.path;
        final state = AppState()..config.backgroundImage = path;
        addTearDown(state.dispose);
        // FileImage must start and complete its I/O in the same test zone.
        await tester.runAsync(() async {
          final provider = wallpaperImageProvider(path, 800, 600, 1);
          final stream = provider.resolve(ImageConfiguration.empty);
          final decoded = Completer<void>();
          final listener = ImageStreamListener((info, _) {
            info.dispose();
            if (!decoded.isCompleted) {
              decoded.complete();
            }
          }, onError: decoded.completeError);
          stream.addListener(listener);
          try {
            await decoded.future;
          } finally {
            stream.removeListener(listener);
          }
        });
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: const MaterialApp(
              home: DesktopResizeScope(
                child: WallpaperBackground(child: SizedBox.expand()),
              ),
            ),
          ),
        );
        final image = find.byType(Image);
        final firstProvider = tester.widget<Image>(image).image;
        await tester.pump();
        final raw = find.descendant(of: image, matching: find.byType(RawImage));
        final decoded = tester.widget<RawImage>(raw).image;
        expect(decoded, isNotNull);
        final scope = find.byType(WallpaperWindowScope);

        for (final width in [820.0, 910.0, 1020.0]) {
          tester.view.physicalSize = Size(width, 640);
          await tester.pump(const Duration(milliseconds: 80));
          expect(tester.getSize(image), Size(width, 640));
          expect(tester.widget<Image>(image).image, same(firstProvider));
          expect(tester.widget<RawImage>(raw).image, same(decoded));
          expect(
            tester.widget<WallpaperWindowScope>(scope).provider,
            same(firstProvider),
          );
        }

        await tester.pump(const Duration(milliseconds: 80));
        final newProvider = tester.widget<Image>(image).image;
        expect(newProvider, isNot(same(firstProvider)));
        expect(
          tester.widget<WallpaperWindowScope>(scope).screenSize,
          const Size(1020, 640),
        );
        expect(tester.widget<RawImage>(raw).image, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
      skip: !isDesktopPlatform,
    );
  });
}
