import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/project_page.dart';
import 'package:ffmpegpp_gui/pages/quick_config_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/widgets/video_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _MemoryConfigService extends ConfigService {
  @override
  Future<void> saveTaskHistory(List<Map<String, dynamic>> tasks) async {}
}

class _QuickProjectState extends AppState {
  _QuickProjectState(this.files) {
    config
      ..language = 'en'
      ..editMode = 1
      ..cardStyle = 'gray'
      ..pillStyle = 'gray'
      ..menuStyle = 'gray'
      ..glassEffect = 'gray';
  }

  final ConfigService _memoryConfig = _MemoryConfigService();
  @override
  ConfigService get configService => _memoryConfig;
  final List<VideoFile> files;

  @override
  List<VideoFile> get videos => files;
  @override
  List<VideoFile> get standaloneVideos => files;
  @override
  VideoFile? videoById(String id) =>
      files.where((file) => file.id == id).firstOrNull;

  @override
  void updateVideoPipeline(String id, PipelineGraph graph) {
    final index = files.indexWhere((file) => file.id == id);
    if (index < 0) return;
    files[index] = files[index].copyWith(pipelineGraph: graph);
    notifyListeners();
  }

  @override
  void addTask(String videoId) => addGraphTasksForTest(videoById(videoId)!);
}

VideoFile _image(String id) => VideoFile(
  id: id,
  filename: '$id.png',
  filepath: '/tmp/ffpp-quick-$id.png',
  parsed: true,
  fileMediaType: MediaType.image,
  width: 100,
  height: 100,
);

Future<void> _pumpProject(WidgetTester tester, _QuickProjectState state) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const ProjectPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _edit(WidgetTester tester, String id) async {
  final card = find.byWidgetPredicate(
    (widget) => widget is VideoCard && widget.video.id == id,
  );
  await tester.tap(find.descendant(of: card, matching: find.byTooltip('Edit')));
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, AppState state) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('file edit starts the wizard and restores only that file', (
    tester,
  ) async {
    final state = _QuickProjectState([_image('alpha'), _image('beta')]);
    await _pumpProject(tester, state);
    await _edit(tester, 'alpha');
    expect(find.byType(QuickConfigPage), findsOneWidget);
    expect(
      tester.widget<QuickConfigPage>(find.byType(QuickConfigPage)).config.nodes,
      isEmpty,
    );
    expect(find.text('Select Quick Config'), findsNothing);
    expect(find.byKey(const ValueKey('quick_pick_avProcess')), findsNothing);
    await _tapKey(tester, 'quick_pick_mediaConvert');
    await _tapKey(tester, 'quick_next');
    await _tapKey(tester, 'quick_save');
    expect(find.byType(QuickConfigPage), findsNothing);
    final saved = state.videoById('alpha')!.pipelineGraph;
    expect(saved.nodes.map((node) => node.type), [
      PipelineStepType.start,
      PipelineStepType.mediaConvert,
      PipelineStepType.output,
    ]);
    expect(state.videoById('beta')!.pipelineGraph.nodes, isEmpty);
    expect(state.tasks, isEmpty);
    await _edit(tester, 'alpha');
    final restored = tester.widget<QuickConfigPage>(
      find.byType(QuickConfigPage),
    );
    expect(restored.config.nodes!.single.type, PipelineStepType.mediaConvert);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _edit(tester, 'beta');
    expect(
      tester.widget<QuickConfigPage>(find.byType(QuickConfigPage)).config.nodes,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    await _dispose(tester, state);
  });

  testWidgets('save and queue builds the selected serial operation', (
    tester,
  ) async {
    final state = _QuickProjectState([_image('queued')]);
    await _pumpProject(tester, state);
    await _edit(tester, 'queued');
    await _tapKey(tester, 'quick_pick_mediaConvert');
    await _tapKey(tester, 'quick_next');
    await _tapKey(tester, 'quick_execute');
    expect(find.byType(QuickConfigPage), findsNothing);
    expect(state.tasks, hasLength(1));
    expect(state.tasks.single.videoId, 'queued');
    expect(state.tasks.single.pipelineCalls, isNotEmpty);
    expect(
      state.tasks.single.pipelineCalls!.any(
        (call) => call.action == 'image_convert',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await _dispose(tester, state);
  });

  testWidgets('an unsupported graph is preserved when the user cancels', (
    tester,
  ) async {
    final file = _image('complex');
    final graph = file.pipelineGraph;
    graph.nodes.addAll([
      PipelineNode(id: 'start', type: PipelineStepType.start),
      PipelineNode(id: 'unlinked', type: PipelineStepType.mediaConvert),
      PipelineNode(id: 'output', type: PipelineStepType.output),
    ]);
    final before = graph.toJson();
    final state = _QuickProjectState([file]);
    await _pumpProject(tester, state);
    await _edit(tester, 'complex');
    expect(find.byType(QuickConfigPage), findsNothing);
    expect(find.text('Open this workflow in the node editor'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.videoById('complex')!.pipelineGraph.toJson(), before);
    expect(state.tasks, isEmpty);
    expect(tester.takeException(), isNull);
    await _dispose(tester, state);
  });
}
