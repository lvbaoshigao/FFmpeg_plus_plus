import 'dart:ui' as ui;

import 'package:ffmpegpp_gui/pages/project_page.dart';
import 'package:ffmpegpp_gui/platform/app_platform.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/mobile_glass_pill.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _addKey = ValueKey('project_add_files');

class _CancelingPicker extends FilePickerPlatform {
  int calls = 0;
  FileType? requestedType;
  List<String>? requestedExtensions;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    requestedType = type;
    requestedExtensions = allowedExtensions;
    return [];
  }
}

Future<AppState> _pumpProject(
  WidgetTester tester, {
  required bool mobile,
  required Size size,
  double textScale = 1,
}) async {
  final previousMobile = debugIsMobilePlatformOverride;
  debugIsMobilePlatformOverride = mobile;
  addTearDown(() => debugIsMobilePlatformOverride = previousMobile);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final state = AppState();
  state.config
    ..language = 'en'
    ..editMode = 0
    ..cardStyle = 'gray'
    ..glassEffect = 'gray'
    ..menuStyle = 'gray'
    ..pillStyle = 'theme';
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const ProjectPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Future<int> _pixelAt(
  WidgetTester tester,
  Finder boundary,
  Offset globalPoint,
) async {
  final render = tester.renderObject<RenderRepaintBoundary>(boundary);
  final point = render.globalToLocal(globalPoint);
  return (await tester.runAsync(() async {
    final image = await render.toImage();
    try {
      final rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return rgba.getUint32(
        (point.dy.floor() * image.width + point.dx.floor()) * 4,
      );
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('Add File is tappable without scrolling on a narrow phone', (
    tester,
  ) async {
    final previousPicker = FilePickerPlatform.instance;
    final picker = _CancelingPicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previousPicker);
    final state = await _pumpProject(
      tester,
      mobile: true,
      size: const Size(320, 720),
      textScale: 2,
    );

    final add = find.byKey(_addKey);
    expect(tester.widget(add), isA<MobileGlassPillAction>());
    expect(add.hitTestable(), findsOneWidget);
    expect(tester.getSize(add).shortestSide, greaterThanOrEqualTo(44));
    await tester.tap(add);
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(picker.requestedType, FileType.custom);
    expect(picker.requestedExtensions, containsAll(['mp4', 'mp3', 'png']));
    expect(state.videos, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final (width, expectedStyle) in [(1200.0, 'gray'), (320.0, 'theme')]) {
    testWidgets('Add File has matching 16dp corners at desktop width $width', (
      tester,
    ) async {
      await _pumpProject(
        tester,
        mobile: false,
        size: Size(width, 800),
        textScale: width < 600 ? 2 : 1,
      );

      final add = find.byKey(_addKey);
      expect(add.hitTestable(), findsOneWidget);
      expect(
        find.descendant(of: add, matching: find.text('Add File')),
        findsOneWidget,
      );
      final surface = find
          .ancestor(of: add, matching: find.byType(GlassPanel))
          .first;
      final panel = tester.widget<GlassPanel>(surface);
      expect(panel.style, expectedStyle);
      expect(panel.radius, 16);
      final material = tester.widget<Material>(
        find.descendant(of: add, matching: find.byType(Material)).first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(16));
    });
  }

  testWidgets('a colored mobile action disk shows pressed feedback', (
    tester,
  ) async {
    final previousMobile = debugIsMobilePlatformOverride;
    debugIsMobilePlatformOverride = true;
    addTearDown(() => debugIsMobilePlatformOverride = previousMobile);
    const boundaryKey = ValueKey('pressed_action_boundary');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: MobileGlassPillAction(
                key: _addKey,
                icon: Icons.add,
                tooltip: 'Add File',
                color: Colors.black,
                bg: Colors.white,
                size: 44,
                padding: EdgeInsets.zero,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    final boundary = find.byKey(boundaryKey);
    final center = tester.getCenter(find.byKey(_addKey));
    final sample = center + const Offset(12, 0);
    final idlePixel = await _pixelAt(tester, boundary, sample);
    final gesture = await tester.startGesture(center);
    // The recognizer's tap-down deadline starts the InkHighlight animation.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    final pressedPixel = await _pixelAt(tester, boundary, sample);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(pressedPixel, isNot(idlePixel));
  });
}
