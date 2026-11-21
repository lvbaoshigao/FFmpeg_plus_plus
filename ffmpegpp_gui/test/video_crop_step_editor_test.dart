import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpegpp_gui/widgets/step_editors/video_crop_step_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VideoCropStepEditor', () {
    late Map<String, dynamic> params;
    late List<Completer<String?>> previews;
    late List<Completer<String?>> fullFrames;
    late List<String> requests;
    late String thumbnailPath;
    late String fullPath;

    setUp(() {
      params = <String, dynamic>{};
      previews = [];
      fullFrames = [];
      requests = [];
      thumbnailPath = File('rele/icon.png').absolute.path;
      fullPath = File('rele/wx.png').absolute.path;
    });

    Future<void> pumpEditor(
      WidgetTester tester, {
      String videoPath = 'first.mp4',
      Map<String, dynamic>? updatedParams,
    }) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoCropStepEditor(
              params: updatedParams ?? params,
              onChanged: () {},
              videoPath: videoPath,
              videoWidth: 1920,
              videoHeight: 1080,
              fps: 30,
              isZh: false,
              generatePreview: (path, time, {width = 480}) {
                requests.add('preview:$path:$time:$width');
                final result = Completer<String?>();
                previews.add(result);
                return result.future;
              },
              generateFullFrame: (path, time) {
                requests.add('full:$path:$time');
                final result = Completer<String?>();
                fullFrames.add(result);
                return result.future;
              },
            ),
          ),
        ),
      );
    }

    Future<void> cacheImages(WidgetTester tester) async {
      // Resolve FileImage I/O in the real test zone before fake-clock pumps.
      final context = tester.element(find.byType(Scaffold));
      await tester.runAsync(() async {
        for (final path in [thumbnailPath, fullPath]) {
          for (final width in [900, 960]) {
            await precacheImage(
              ResizeImage(FileImage(File(path)), width: width),
              context,
            );
          }
        }
      });
    }

    Future<void> extract(WidgetTester tester) async {
      await tester.tap(find.text('Extract'));
      await tester.pump();
      previews.last.complete(thumbnailPath);
      await tester.pumpAndSettle();
    }

    Future<void> openSelection(WidgetTester tester) async {
      await tester.tap(find.text('Open Selection Tool'));
      await tester.pumpAndSettle();
    }

    String dialogImagePath(WidgetTester tester) {
      final image = tester.widget<Image>(
        find.descendant(of: find.byType(Dialog), matching: find.byType(Image)),
      );
      return ((image.image as ResizeImage).imageProvider as FileImage)
          .file
          .path;
    }

    tearDown(() {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    testWidgets(
      'should show the thumbnail first and request full resolution only on open',
      (tester) async {
        addTearDown(tester.view.reset);
        params['frame_number'] = 60;
        await pumpEditor(tester);
        await cacheImages(tester);
        await extract(tester);

        expect(requests, ['preview:first.mp4:2.0:480']);
        expect(find.byType(Image), findsOneWidget);
        await openSelection(tester);
        expect(requests.last, 'full:first.mp4:2.0');
        expect(dialogImagePath(tester), thumbnailPath);

        fullFrames.single.complete(fullPath);
        await tester.pumpAndSettle();
        expect(dialogImagePath(tester), fullPath);
        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
        await openSelection(tester);
        expect(fullFrames, hasLength(1));
        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'should preserve original video crop coordinates across the image upgrade',
      (tester) async {
        addTearDown(tester.view.reset);
        await pumpEditor(tester);
        await cacheImages(tester);
        await extract(tester);
        await openSelection(tester);

        final canvasFinder = find.byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.onPanStart != null,
        );
        final canvas = tester.widget<GestureDetector>(canvasFinder);
        final size = tester.getSize(canvasFinder);
        final scale = math.min(size.width / 1920, size.height / 1080);
        final offset = Offset(
          (size.width - 1920 * scale) / 2,
          (size.height - 1080 * scale) / 2,
        );
        canvas.onPanStart!(
          DragStartDetails(
            localPosition: offset + const Offset(192, 108) * scale,
          ),
        );
        canvas.onPanUpdate!(
          DragUpdateDetails(
            globalPosition: offset + const Offset(1152, 648) * scale,
            localPosition: offset + const Offset(1152, 648) * scale,
          ),
        );
        canvas.onPanEnd!(DragEndDetails());
        await tester.pump();

        fullFrames.single.complete(fullPath);
        await tester.pumpAndSettle();
        expect(dialogImagePath(tester), fullPath);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(params['regions'], [
          {'x': 192, 'y': 108, 'w': 960, 'h': 540},
        ]);
        expect(params['crop_x'], 192);
        expect(params['crop_y'], 108);
        expect(params['crop_w'], 960);
        expect(params['crop_h'], 540);
      },
    );

    testWidgets('should retain the thumbnail when full resolution fails', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await pumpEditor(tester);
      await cacheImages(tester);
      await extract(tester);
      await openSelection(tester);
      fullFrames.single.completeError(StateError('extraction failed'));
      await tester.pumpAndSettle();
      expect(dialogImagePath(tester), thumbnailPath);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    });

    testWidgets(
      'should ignore stale thumbnails after changing frame or source',
      (tester) async {
        addTearDown(tester.view.reset);
        await pumpEditor(tester);
        await cacheImages(tester);
        await tester.tap(find.text('Extract'));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '30');
        await tester.pump();
        await tester.tap(find.text('Extract'));
        await tester.pump();
        previews.first.complete(fullPath);
        await tester.pump();
        expect(find.byType(Image), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        previews.last.complete(thumbnailPath);
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsOneWidget);

        await pumpEditor(tester, videoPath: 'second.mp4');
        expect(find.byType(Image), findsNothing);
        await extract(tester);
        await openSelection(tester);
        expect(requests.last, 'full:second.mp4:1.0');
        fullFrames.single.complete(fullPath);
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('should discard a dialog save after its params are replaced', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      params['regions'] = [
        {'x': 192, 'y': 108, 'w': 960, 'h': 540},
      ];
      await pumpEditor(tester);
      await cacheImages(tester);
      await extract(tester);
      await openSelection(tester);
      final replacement = <String, dynamic>{'frame_number': 0};
      await pumpEditor(tester, updatedParams: replacement);
      fullFrames.single.complete(fullPath);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(replacement, {'frame_number': 0});
      expect(tester.takeException(), isNull);
    });

    testWidgets('should ignore thumbnail completion after disposal', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await pumpEditor(tester);
      await tester.tap(find.text('Extract'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      previews.single.complete(thumbnailPath);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(fullFrames, isEmpty);
    });

    testWidgets('should ignore full frame completion after the dialog closes', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await pumpEditor(tester);
      await cacheImages(tester);
      await extract(tester);
      await openSelection(tester);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      fullFrames.single.complete(fullPath);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
