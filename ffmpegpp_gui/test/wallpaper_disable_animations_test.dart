import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/app.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/image_memory_budget.dart';
import 'package:ffmpegpp_gui/services/static_file_image.dart';
import 'package:ffmpegpp_gui/widgets/desktop_resize_scope.dart';
import 'package:ffmpegpp_gui/widgets/wallpaper_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Three 1x1 RGB frames, looping with a 100 ms delay between frames.
final _animatedGif = base64Decode(
  'R0lGODlhAQABAKEDAAAA//8AAAD/AP///yH/C05FVFNDQVBFMi4wAwEAAAAh'
  '+QQACgD/ACwAAAAAAQABAAACAkwBACH5BAAKAP8ALAAAAAABAAEAAAICVAEA'
  'IfkEAAoA/wAsAAAAAAEAAQAAAgJEAQA7',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Keep these tests focused on source decoding, independently of preblur.
    debugIsMobilePlatformOverride = true;
    WallpaperBlurCache.release();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() {
    WallpaperBlurCache.release();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    debugIsMobilePlatformOverride = null;
  });

  test(
    'wallpaper providers keep fit, budgets, and separate static cache keys',
    () async {
      final animated =
          wallpaperImageProvider('/wallpaper.gif', 3840, 2160, 4)
              as ResizeImage;
      final still =
          wallpaperImageProvider(
                '/wallpaper.gif',
                3840,
                2160,
                4,
                disableAnimations: true,
              )
              as ResizeImage;
      final target = ImageMemoryBudget.wallpaperSize(3840, 2160, 4);
      for (final provider in [animated, still]) {
        expect(provider.policy, ResizeImagePolicy.fit);
        expect(provider.width, target.width);
        expect(provider.height, target.height);
        expect(provider.allowUpscaling, isFalse);
      }
      expect(animated.imageProvider, isA<FileImage>());
      expect(animated.imageProvider, isNot(isA<StaticFileImage>()));
      expect(still.imageProvider, isA<StaticFileImage>());
      expect(
        await still.obtainKey(ImageConfiguration.empty),
        isNot(await animated.obtainKey(ImageConfiguration.empty)),
      );
      expect(
        await still.obtainKey(ImageConfiguration.empty),
        await wallpaperImageProvider(
          '/wallpaper.gif',
          3840,
          2160,
          4,
          disableAnimations: true,
        ).obtainKey(ImageConfiguration.empty),
      );
    },
  );

  for (final legacy in [false, true]) {
    testWidgets(
      'static ${legacy ? 'loadBuffer' : 'loadImage'} decodes once for all listeners and disposes codec',
      (tester) async {
        final source = (await tester.runAsync(_createImage))!;
        final codec = _CountingCodec(source);
        final provider = ResizeImage(
          StaticFileImage(_BytesFile(), scale: 2),
          width: 100,
          height: 100,
          policy: ResizeImagePolicy.fit,
        );
        final key = await provider.obtainKey(ImageConfiguration.empty);
        late Completer<void> first;
        final received = <ImageInfo>[];
        final listeners = [
          ImageStreamListener((info, _) {
            received.add(info);
            first.complete();
          }, onError: (error, stack) => first.completeError(error, stack)),
          ImageStreamListener((info, _) => received.add(info)),
        ];
        late ImageStreamCompleter completer;
        await tester.runAsync(() async {
          first = Completer<void>();
          completer = legacy
              // ignore: deprecated_member_use
              ? provider.loadBuffer(key, (
                  buffer, {
                  cacheWidth,
                  cacheHeight,
                  allowUpscaling = false,
                }) async {
                  expect(cacheWidth, 100);
                  expect(cacheHeight, 100);
                  expect(allowUpscaling, isFalse);
                  buffer.dispose();
                  return codec;
                })
              : provider.loadImage(key, (buffer, {getTargetSize}) async {
                  final target = getTargetSize!(400, 200);
                  expect(target.width, 100);
                  expect(target.height, 50);
                  buffer.dispose();
                  return codec;
                });
          for (final listener in listeners) {
            completer.addListener(listener);
          }
          await first.future.timeout(const Duration(seconds: 5));
        });
        expect(completer, isA<OneFrameImageStreamCompleter>());
        expect(received, hasLength(2));
        expect(received.every((info) => info.image.isCloneOf(source)), isTrue);
        expect(received.every((info) => info.scale == 2), isTrue);
        expect(codec.framesAsked, 1);
        expect(codec.disposed, isTrue);
        await tester.pump(const Duration(seconds: 5));
        expect(codec.framesAsked, 1);
        expect(received, hasLength(2));
        for (final info in received) {
          info.dispose();
        }
        for (final listener in listeners) {
          completer.removeListener(listener);
        }
        expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
        source.dispose();
      },
    );
  }

  testWidgets(
    'evicting a pending static decode safely releases its late first frame',
    (tester) async {
      final source = (await tester.runAsync(_createImage))!;
      addTearDown(source.dispose);
      final codec = _CountingCodec(source);
      final provider = ResizeImage(
        StaticFileImage(_BytesFile()),
        width: 100,
        height: 100,
        policy: ResizeImagePolicy.fit,
      );
      final key = await provider.obtainKey(ImageConfiguration.empty);
      late Completer<void> decodingStarted;
      late Completer<void> finishDecoding;
      final cache = PaintingBinding.instance.imageCache;
      var framesReceived = 0;
      final listener = ImageStreamListener((info, _) {
        framesReceived++;
        info.dispose();
      });
      late ImageStreamCompleter completer;
      await tester.runAsync(() async {
        decodingStarted = Completer<void>();
        finishDecoding = Completer<void>();
        completer = cache.putIfAbsent(
          key,
          () => provider.loadImage(key, (buffer, {getTargetSize}) async {
            buffer.dispose();
            decodingStarted.complete();
            await finishDecoding.future;
            return codec;
          }),
        )!;
        completer.addListener(listener);
        await decodingStarted.future.timeout(const Duration(seconds: 5));
      });
      expect(cache.statusForKey(key).pending, isTrue);
      completer.removeListener(listener);
      expect(cache.evict(key, includeLive: false), isTrue);
      // Cache eviction only queues a post-frame release; with no widget tree,
      // pump alone does not schedule a frame. Release the cache handle before
      // the asynchronous decoder is allowed to hand back the first frame.
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(codec.disposed, isFalse);
      await tester.runAsync(() async {
        finishDecoding.complete();
        await Future<void>.delayed(Duration.zero);
      });
      expect(framesReceived, 0);
      expect(codec.framesAsked, 1);
      expect(codec.disposed, isTrue);
      expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
      expect(
        completer.keepAlive,
        throwsStateError,
        reason: 'The late frame must not keep an evicted stream alive.',
      );
      expect(cache.statusForKey(key).pending, isFalse);
      expect(cache.statusForKey(key).keepAlive, isFalse);
      expect(cache.statusForKey(key).live, isFalse);
    },
  );

  testWidgets(
    'static decoder disposes its codec when first-frame decoding fails',
    (tester) async {
      final source = (await tester.runAsync(_createImage))!;
      final codec = _CountingCodec(source, fail: true);
      final provider = StaticFileImage(_BytesFile());
      late Completer<Object> failure;
      final listener = ImageStreamListener(
        (info, _) => info.dispose(),
        onError: (Object error, _) => failure.complete(error),
      );
      late ImageStreamCompleter completer;
      await tester.runAsync(() async {
        failure = Completer<Object>();
        completer = provider.loadImage(provider, (
          buffer, {
          getTargetSize,
        }) async {
          buffer.dispose();
          return codec;
        });
        completer.addListener(listener);
        expect(
          await failure.future.timeout(const Duration(seconds: 5)),
          isA<StateError>(),
        );
      });
      expect(codec.framesAsked, 1);
      expect(codec.disposed, isTrue);
      completer.removeListener(listener);
      expect(
        completer.keepAlive,
        throwsStateError,
        reason: 'The pending decode handle must also be released on errors.',
      );
      source.dispose();
    },
  );

  testWidgets(
    'viewport and window listener freeze on first frame and resume animation',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'wallpaper-motion-',
      );
      final file = File('${directory.path}/animated.gif')
        ..writeAsBytesSync(_animatedGif);
      final state = AppState();
      final previousPath = state.config.backgroundImage;
      state.config.backgroundImage = file.path;
      addTearDown(() {
        state.config.backgroundImage = previousPath;
        state.dispose();
        directory.deleteSync(recursive: true);
      });
      ValueNotifier<WallpaperWindow?>? window;
      bool ready() {
        final source = window?.value?.image;
        final displayed = tester.widget<RawImage>(find.byType(RawImage)).image;
        return source != null &&
            displayed != null &&
            displayed.isCloneOf(source);
      }

      Widget build(bool disableAnimations) => _harness(
        state,
        disableAnimations: disableAnimations,
        child: Builder(
          builder: (context) {
            window = WallpaperWindowScope.maybeOf(context);
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(build(false));
      await _waitForImage(tester, ready: ready);
      final animatedProvider = tester.widget<Image>(find.byType(Image)).image;
      expect(
        (animatedProvider as ResizeImage).imageProvider,
        isNot(isA<StaticFileImage>()),
      );
      final frames = <ui.Image>[];
      window!.addListener(() {
        final image = window!.value?.image;
        if (image != null) frames.add(image);
      });
      await _advanceAnimation(tester);
      expect(
        frames,
        isNotEmpty,
        reason: 'The scope listener receives animated frames.',
      );

      await tester.pumpWidget(build(true));
      await _waitForImage(tester, ready: ready);
      final stillProvider = tester.widget<Image>(find.byType(Image)).image;
      expect(
        (stillProvider as ResizeImage).imageProvider,
        isA<StaticFileImage>(),
      );
      final still = window!.value!.image;
      final displayed = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(displayed.isCloneOf(still), isTrue);
      expect(await tester.runAsync(() => _pixel(still)), 0xff0000ff);
      frames.clear();
      await _advanceAnimation(tester);
      expect(
        frames,
        isEmpty,
        reason: 'The extra window listener must not continue decoding.',
      );
      expect(window!.value!.image, same(still));
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image!.isCloneOf(still),
        isTrue,
      );

      await tester.pumpWidget(build(false));
      await _waitForImage(tester, ready: ready);
      expect(tester.widget<Image>(find.byType(Image)).image, animatedProvider);
      frames.clear();
      await _advanceAnimation(tester);
      expect(
        frames,
        isNotEmpty,
        reason: 'Re-enabling animation restores the animated stream.',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'motion toggles during desktop resize retain the frozen decode size',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'wallpaper-resize-motion-',
      );
      final file = File('${directory.path}/animated.gif')
        ..writeAsBytesSync(_animatedGif);
      final state = AppState();
      final previousPath = state.config.backgroundImage;
      state.config.backgroundImage = file.path;
      addTearDown(() {
        state.config.backgroundImage = previousPath;
        state.dispose();
        directory.deleteSync(recursive: true);
      });
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      Widget build(bool disabled, Size size) => _harness(
        state,
        disableAnimations: disabled,
        size: size,
        child: const SizedBox(),
      );
      await tester.pumpWidget(build(false, const Size(800, 600)));
      await _waitForImage(tester);
      final initial =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      tester.view.physicalSize = const Size(1000, 600);
      await tester.pumpWidget(build(true, const Size(1000, 600)));
      final still =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect(still.imageProvider, isA<StaticFileImage>());
      expect(still.width, initial.width);
      expect(still.height, initial.height);
      await tester.pumpWidget(build(false, const Size(1000, 600)));
      expect(tester.widget<Image>(find.byType(Image)).image, initial);
      await tester.pump(const Duration(milliseconds: 160));
      final settled =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      final target = ImageMemoryBudget.wallpaperSize(1000, 600, 1);
      expect(settled.width, target.width);
      expect(settled.height, target.height);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}

Widget _harness(
  AppState state, {
  required bool disableAnimations,
  required Widget child,
  Size size = const Size(800, 600),
}) => ChangeNotifierProvider.value(
  value: state,
  child: MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        devicePixelRatio: 1,
        disableAnimations: disableAnimations,
      ),
      child: DesktopResizeScope(child: WallpaperBackground(child: child)),
    ),
  ),
);

Future<void> _waitForImage(
  WidgetTester tester, {
  bool Function()? ready,
}) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    final image = tester.widget<RawImage>(find.byType(RawImage)).image;
    if (image != null && (ready?.call() ?? true)) return;
  }
  fail('Wallpaper image did not decode.');
}

Future<void> _advanceAnimation(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<int> _pixel(ui.Image image) async =>
    (await image.toByteData())!.getUint32(0);

Future<ui.Image> _createImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.red, BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(2, 2);
  } finally {
    picture.dispose();
  }
}

class _BytesFile extends Fake implements File {
  @override
  String get path => '/wallpaper.gif';
  @override
  Future<int> length() async => _animatedGif.length;
  @override
  Future<Uint8List> readAsBytes() async => _animatedGif;
}

class _CountingCodec implements ui.Codec {
  _CountingCodec(this.source, {this.fail = false});
  final ui.Image source;
  final bool fail;
  int framesAsked = 0;
  bool disposed = false;
  @override
  int get frameCount => 3;
  @override
  int get repetitionCount => -1;
  @override
  Future<ui.FrameInfo> getNextFrame() async {
    framesAsked++;
    if (fail) throw StateError('first frame failed');
    return _Frame(source.clone());
  }

  @override
  void dispose() => disposed = true;
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => const Duration(milliseconds: 100);
}
