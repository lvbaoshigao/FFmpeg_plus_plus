import 'package:desktop_drop/desktop_drop.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/project_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:ffmpegpp_gui/widgets/container_card.dart';
import 'package:ffmpegpp_gui/widgets/glass_panel.dart';
import 'package:ffmpegpp_gui/widgets/mobile_ui.dart';
import 'package:ffmpegpp_gui/widgets/video_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ProjectLibraryState extends AppState {
  _ProjectLibraryState(this.files);

  final List<VideoFile> files;

  @override
  List<VideoFile> get videos => files;

  @override
  List<VideoFile> get standaloneVideos => files;

  @override
  VideoFile? videoById(String id) =>
      files.where((file) => file.id == id).firstOrNull;
}

AppState _projectState([AppState? fixture]) {
  final state = fixture ?? AppState();
  state.updateConfig(
    (config) => config
      ..language = 'en'
      ..cardStyle = 'gray'
      ..pillStyle = 'gray'
      ..menuStyle = 'gray'
      ..glassEffect = 'gray'
      ..editMode = 0,
  );
  return state;
}

Widget _projectHarness(AppState state, {double textScale = 1}) =>
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
    );

Future<void> _unmountProject(WidgetTester tester, AppState state) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
}

void main() {
  group('ProjectPage', () {
    testWidgets(
      'should use a labeled active-style Add Files button on desktop',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _projectState();
        await tester.pumpWidget(_projectHarness(state));
        await tester.pumpAndSettle();
        final add = find.byKey(const ValueKey('project_add_files'));
        final button = tester.widget<OutlinedButton>(add);
        expect(button.onPressed, isNotNull);
        expect(button.style!.backgroundColor!.resolve({}), Colors.transparent);
        expect(tester.getSize(add).height, greaterThanOrEqualTo(48));
        expect(
          find.descendant(of: add, matching: find.text('Add File')),
          findsOneWidget,
        );
        expect(find.byType(FilledButton), findsNothing);
        final surface = find
            .ancestor(of: add, matching: find.byType(GlassPanel))
            .first;
        expect(tester.widget<GlassPanel>(surface).style, 'gray');
        state.updateConfig((config) => config..menuStyle = 'theme');
        await tester.pumpAndSettle();
        expect(tester.widget<GlassPanel>(surface).style, 'theme');
        final drop = tester.widget<DropTarget>(find.byType(DropTarget));
        expect(drop.onDragDone, isNotNull);
        expect(drop.onDragEntered, isNotNull);
        expect(tester.takeException(), isNull);
        await _unmountProject(tester, state);
      },
    );

    testWidgets(
      'should trim compact search queries and restore files on close',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _projectState(
          _ProjectLibraryState([
            VideoFile.fromFilepath('/tmp/alpha.png'),
            VideoFile.fromFilepath('/tmp/beta.png'),
          ]),
        );
        await tester.pumpWidget(_projectHarness(state));
        await tester.pumpAndSettle();
        expect(find.byType(DropTarget), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('project_search')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '  alpha  ');
        await tester.pumpAndSettle();
        expect(find.text('alpha.png'), findsOneWidget);
        expect(find.text('beta.png'), findsNothing);
        tester.view.physicalSize = const Size(1200, 800);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '  alpha  ',
        );
        expect(find.text('beta.png'), findsNothing);
        tester.view.physicalSize = const Size(320, 720);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '  alpha  ',
        );
        await tester.tap(
          find.descendant(
            of: find.byType(MobileSearchPill),
            matching: find.byIcon(Icons.close),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('alpha.png'), findsOneWidget);
        expect(find.text('beta.png'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _unmountProject(tester, state);
      },
    );

    testWidgets(
      'should keep compact multi-select and container deletion working',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _projectState()..addEmptyContainer('My container');
        await tester.pumpWidget(_projectHarness(state));
        await tester.pumpAndSettle();
        await tester.longPress(find.byType(ContainerCard));
        await tester.pumpAndSettle();
        for (final key in [
          'project_exit_selection',
          'project_select_all',
          'project_invert_selection',
          'project_delete_selected',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(8));
          expect(rect.right, lessThanOrEqualTo(312));
        }
        await tester.tap(
          find.byKey(const ValueKey('project_invert_selection')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('project_add_files')), findsOneWidget);
        await tester.longPress(find.byType(ContainerCard));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project_select_all')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('project_delete_selected')));
        await tester.pumpAndSettle();
        expect(state.containers, isEmpty);
        expect(find.byType(ContainerCard), findsNothing);
        expect(tester.takeException(), isNull);
        await _unmountProject(tester, state);
      },
    );

    testWidgets('should scroll the compact container menu with large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _projectState();
      await tester.pumpWidget(_projectHarness(state, textScale: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project_container')));
      await tester.pumpAndSettle();
      expect(find.text('New Container'), findsOneWidget);
      final inkSurface = find.byKey(
        const ValueKey('project_container_menu_material'),
      );
      expect(
        tester.widget<Material>(inkSurface).type,
        MaterialType.transparency,
      );
      expect(
        find.descendant(of: inkSurface, matching: find.byType(ListTile)),
        findsNWidgets(3),
      );
      await tester.ensureVisible(
        find.text('Manually select files for a new container'),
      );
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(160, 20));
      await tester.pumpAndSettle();
      await _unmountProject(tester, state);
    });
  });
  testWidgets('320px file card keeps filename readable and actions reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    final video = VideoFile.fromFilepath(
      '/tmp/a_long_unparsed_photo_filename.png',
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: VideoCard(video: video)),
        ),
      ),
    );
    expect(tester.getSize(find.text(video.filename)).width, greaterThan(150));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('应用配置库'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets(
    'unparsed home file retains more options for saved configurations',
    (tester) async {
      final state = AppState();
      final video = VideoFile.fromFilepath('/tmp/photo.png');
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Scaffold(body: VideoCard(video: video)),
          ),
        ),
      );
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('应用配置库'), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
