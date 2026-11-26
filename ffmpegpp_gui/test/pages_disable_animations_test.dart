import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/ai_settings_mobile.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/pages/project_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/step_editors/image_crop_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ProbingAppState extends AppState {
  final _testVideos = [VideoFile(id: 'probing', filename: 'Probing.mp4')];

  @override
  bool get probingVideos => true;

  @override
  List<VideoFile> get videos => _testVideos;

  @override
  List<VideoFile> get standaloneVideos => _testVideos;
}

Future<void> _host(
  WidgetTester tester, {
  required AppState state,
  required ValueNotifier<bool> disabled,
  required Widget page,
  bool mobile = false,
  Size size = const Size(1280, 900),
}) async {
  final previousMobile = debugIsMobilePlatformOverride;
  debugIsMobilePlatformOverride = mobile;
  addTearDown(() => debugIsMobilePlatformOverride = previousMobile);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  state.config
    ..language = 'en'
    ..cardStyle = 'gray'
    ..pillStyle = 'theme'
    ..glassEffect = 'gray';
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    disabled.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => ValueListenableBuilder<bool>(
          valueListenable: disabled,
          builder: (context, value, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: value),
            child: child!,
          ),
        ),
        home: page,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  const windowChannel = MethodChannel('window_manager');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
          if (call.method == 'isMaximized') return false;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  testWidgets('project probing stops and resumes its existing controller', (
    tester,
  ) async {
    final disabled = ValueNotifier(true);
    await _host(
      tester,
      state: _ProbingAppState(),
      disabled: disabled,
      page: const ProjectPage(),
    );
    final rotation = find.byWidgetPredicate(
      (widget) =>
          widget is RotationTransition && widget.turns is AnimationController,
    );
    expect(rotation, findsOneWidget);
    final controller =
        tester.widget<RotationTransition>(rotation).turns
            as AnimationController;
    expect(controller.isAnimating, isFalse);
    expect(controller.value, 0);

    disabled.value = false;
    await tester.pump();
    expect(controller.isAnimating, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.value, greaterThan(0));

    disabled.value = true;
    await tester.pump();
    expect(tester.widget<RotationTransition>(rotation).turns, same(controller));
    expect(controller.isAnimating, isFalse);
    expect(controller.value, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.value, 0);

    disabled.value = false;
    await tester.pump();
    expect(controller.isAnimating, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI search uses a static indeterminate indicator when disabled', (
    tester,
  ) async {
    final disabled = ValueNotifier(true);
    final state = AppState();
    await _host(
      tester,
      state: state,
      disabled: disabled,
      page: MobileAiProvidersPage(state: state),
    );
    await tester.enterText(find.byType(TextField).first, 'provider');
    await tester.pump();
    final loading = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_AiSearchLoading',
    );
    final spinner = find.descendant(
      of: loading,
      matching: find.byType(CircularProgressIndicator),
    );
    expect(loading, findsOneWidget);
    expect(tester.widget<CircularProgressIndicator>(spinner).value, 0.75);
    expect(
      tester.widget<CircularProgressIndicator>(spinner).semanticsValue,
      isNull,
    );
    final pulse = find.descendant(
      of: loading,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedBuilder &&
            widget.animation is AnimationController,
      ),
    );
    final controller =
        tester.widget<AnimatedBuilder>(pulse).animation as AnimationController;
    expect(controller.isAnimating, isFalse);

    disabled.value = false;
    await tester.pump();
    expect(controller.isAnimating, isTrue);
    expect(tester.widget<CircularProgressIndicator>(spinner).value, isNull);

    disabled.value = true;
    await tester.pump();
    expect(controller.isAnimating, isFalse);
    expect(controller.value, 0.5);
    expect(tester.widget<CircularProgressIndicator>(spinner).value, 0.75);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pipeline controls follow the current motion setting', (
    tester,
  ) async {
    final disabled = ValueNotifier(true);
    await _host(
      tester,
      state: AppState(),
      disabled: disabled,
      page: PipelineEditorPage(
        video: VideoFile(id: 'reduced-motion', filename: 'Template'),
        onSave: (_) {},
      ),
    );
    final rotations = find.descendant(
      of: find.byType(PipelineEditorPage),
      matching: find.byType(AnimatedRotation),
    );
    expect(rotations, findsWidgets);
    expect(
      tester
          .widgetList<AnimatedRotation>(rotations)
          .map((widget) => widget.duration),
      everyElement(Duration.zero),
    );
    final editorState = tester.state(find.byType(PipelineEditorPage));
    disabled.value = false;
    await tester.pump();
    expect(tester.state(find.byType(PipelineEditorPage)), same(editorState));
    expect(
      tester
          .widgetList<AnimatedRotation>(rotations)
          .map((widget) => widget.duration),
      everyElement(greaterThan(Duration.zero)),
    );
    disabled.value = true;
    await tester.pump();
    expect(
      tester
          .widgetList<AnimatedRotation>(rotations)
          .map((widget) => widget.duration),
      everyElement(Duration.zero),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile crop route skips motion and reacts during a transition', (
    tester,
  ) async {
    final disabled = ValueNotifier(true);
    await _host(
      tester,
      state: AppState(),
      disabled: disabled,
      mobile: true,
      size: const Size(320, 640),
      page: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showImageCropDialog(
              context,
              imagePath: File('rele/icon.png').absolute.path,
              imageSize: const Size(1920, 1080),
              initialRect: const Rect.fromLTWH(0, 0, 1920, 1080),
              isZh: false,
            ),
            child: const Text('Open crop'),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        ResizeImage(FileImage(File('rele/icon.png').absolute), width: 320),
        tester.element(find.byType(Scaffold)),
      );
    });
    Finder crop() => find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_ImageCropDialog',
    );
    await tester.tap(find.text('Open crop'));
    await tester.pump();
    expect(crop(), findsOneWidget);
    var route = ModalRoute.of(tester.element(crop()))!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.animation!.value, 1);
    expect(
      find.ancestor(of: crop(), matching: find.byType(FadeTransition)),
      findsNothing,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    disabled.value = false;
    await tester.pump();
    await tester.tap(find.text('Open crop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    route = ModalRoute.of(tester.element(crop()))!;
    expect(route.animation!.value, lessThan(1));
    expect(
      find.ancestor(of: crop(), matching: find.byType(FadeTransition)),
      findsOneWidget,
    );
    disabled.value = true;
    await tester.pump();
    expect(
      find.ancestor(of: crop(), matching: find.byType(FadeTransition)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
