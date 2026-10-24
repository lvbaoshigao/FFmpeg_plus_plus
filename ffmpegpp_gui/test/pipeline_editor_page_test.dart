import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/window_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PipelineEditorPage', () {
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
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
    });

    testWidgets(
      'should open without provider errors and rebuild glass when preferences change',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState();
        addTearDown(state.dispose);
        state.config
          ..cardOpacity = 0.7
          ..glassBlur = 16
          ..glassClarity = 0.45;

        // Open the real template editor: its nested ValueListenableBuilder used
        // to call _glassWrap with State.context and trip provider's assertion.
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: state,
            child: MaterialApp(
              theme: AppTheme.dark(),
              home: PipelineEditorPage(
                video: VideoFile(id: 'glass-regression', filename: 'Template'),
                onSave: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(PipelineEditorPage), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsOneWidget);

        // Identify the editor's glass wrapper by its public rendered structure,
        // rather than depending on the private State or mocking its widgets.
        final glass = find.byWidgetPredicate((widget) {
          if (widget is! BackdropFilter || widget.child is! Container) {
            return false;
          }
          final decoration = (widget.child! as Container).decoration;
          return decoration is BoxDecoration &&
              decoration.borderRadius == BorderRadius.circular(12) &&
              decoration.border is Border;
        });
        expect(glass, findsWidgets);
        final glassElement = glass.evaluate().first;
        final before = glassElement.widget as BackdropFilter;
        final beforeColor =
            ((before.child! as Container).decoration! as BoxDecoration).color!;
        expect(beforeColor.a, closeTo(179 / 255, 0.0001));

        // Notify through the real provider without rebuilding the test host.
        state.config.cardOpacity = 0.25;
        state.notifyListeners();
        await tester.pump();
        expect(tester.takeException(), isNull);
        final afterOpacity = glassElement.widget as BackdropFilter;
        final afterColor =
            ((afterOpacity.child! as Container).decoration! as BoxDecoration)
                .color!;
        expect(afterColor.a, closeTo(64 / 255, 0.0001));
        expect(afterColor, isNot(beforeColor));

        state.config.glassBlur = 24;
        state.notifyListeners();
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          (glassElement.widget as BackdropFilter).filter,
          isNot(before.filter),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('uses the shared WindowChrome CSD instead of its own title bar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: PipelineEditorPage(
              video: VideoFile(id: 'csd-regression', filename: 'Template'),
              onSave: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      // Linux 测试宿主：编辑器不再自绘 36px 标题栏，而是复用全应用统一的
      // WindowChrome（内容整体下移 36px + 共享窗口按钮）。旧实现这里是
      // Stack(_buildEditorCsdTitleBar + 手工 topPad)，会出现双标题栏。
      expect(find.byType(WindowChrome), findsOneWidget);
      expect(find.byType(WindowChromeBar), findsOneWidget);
      // 内容区顶部留白由 WindowChrome 提供；编辑器 body 自己的 topPad 已归零，
      // 因此不再有额外一层 36px 的 Padding（这里用像素断言防止回归为双 36px）。
      final chromeRect = tester.getRect(find.byType(WindowChromeBar));
      expect(chromeRect.height, kWindowChromeHeight);
      // 内容整体从标题栏下方开始，且**只**偏移 36px：若旧的手工
      // topPad=36 又回来了，Scaffold 顶部会变成 72（双 36px）。
      final scaffoldRect = tester.getRect(find.byType(Scaffold));
      expect(scaffoldRect.top, kWindowChromeHeight);
      expect(scaffoldRect.height, 1000 - kWindowChromeHeight);
      expect(find.byType(InteractiveViewer), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
