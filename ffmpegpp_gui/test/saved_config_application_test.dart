import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/container_detail_page.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/saved_config_application.dart';
import 'package:ffmpegpp_gui/widgets/container_card.dart';
import 'package:ffmpegpp_gui/widgets/video_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

PipelineGraph preset({
  String? media,
  PipelineStepType step = PipelineStepType.imageConvert,
}) {
  final nodes = [
    PipelineNode(
      id: 'start',
      type: PipelineStepType.start,
      params: {
        'file_media_type': ?media,
        'filepath': '/author/source.png',
      },
    ),
    PipelineNode(
      id: 'step',
      type: step,
      params: {
        'nested': {
          'values': [1, 2],
        },
      },
    ),
    PipelineNode(id: 'out', type: PipelineStepType.output),
  ];
  return PipelineGraph(
    nodes: nodes,
    connections: [
      PipelineConnection(id: 'a', fromNodeId: 'start', toNodeId: 'step'),
      PipelineConnection(id: 'b', fromNodeId: 'step', toNodeId: 'out'),
    ],
  );
}

class MemoryState extends AppState {
  final List<VideoFile> files;
  int applications = 0;
  final List<FileContainer> folders = [];
  @override
  List<FileContainer> get containers => folders;
  MemoryState(this.files);
  @override
  VideoFile? videoById(String id) => files.where((f) => f.id == id).firstOrNull;
  @override
  void updateVideoPipeline(String id, PipelineGraph graph) {
    final index = files.indexWhere((f) => f.id == id);
    if (index >= 0) {
      files[index] = files[index].copyWith(pipelineGraph: graph);
      applications++;
    }
  }
}

void main() {
  final photo = VideoFile.fromFilepath('/current/photo.png');
  final audio = VideoFile.fromFilepath('/current/music.mp3');

  testWidgets('editing a card after application opens the current graph', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final initial = photo.copyWith(parsed: true);
    final state = MemoryState([initial]);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: VideoCard(video: initial)),
        ),
      ),
    );
    final currentGraph = SavedConfigChoice.graph(
      'preset',
      preset(),
    ).prepare(photo, isZh: true);
    state.updateVideoPipeline(photo.id, currentGraph);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final editor = tester.widget<PipelineEditorPage>(
      find.byType(PipelineEditorPage),
    );
    expect(editor.video.pipelineGraph, same(currentGraph));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('should keep a container title and actions visible at 2x text', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = MemoryState([photo.copyWith(parsed: true)]);
    addTearDown(state.dispose);
    final container = FileContainer(id: 'container', name: 'Media collection',
        items: [ContainerItem(fileId: photo.id, index: 1)]);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(body: ContainerCard(container: container)),
        ),
      ),
    );
    final title = tester.getRect(find.text('Media collection'));
    expect(title.width, greaterThan(170));
    expect(tester.getRect(find.byIcon(Icons.login)).top, greaterThan(title.bottom));
    expect(find.byType(IconButton), findsNWidgets(4));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('container file retains preset menu with reorder actions', (
    tester,
  ) async {
    final state = MemoryState([photo]);
    state.config.cardStyle = 'gray';
    state.folders.add(
      FileContainer(
        id: 'folder',
        name: 'Files',
        items: [ContainerItem(fileId: photo.id, index: 1)],
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: ContainerDetailPage(containerId: 'folder'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('应用到文件（不覆盖容器流程）'), findsOneWidget);
    expect(find.text('上移'), findsOneWidget);
    expect(find.text('下移'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  test('node preset respects declared source media before rebinding', () {
    final graph = PipelineGraph(
      nodes: [
        PipelineNode(
          id: 's',
          type: PipelineStepType.start,
          params: {'file_media_type': 'video'},
        ),
        PipelineNode(id: 'o', type: PipelineStepType.output),
      ],
      connections: [
        PipelineConnection(id: 'c', fromNodeId: 's', toNodeId: 'o'),
      ],
    );
    // Even a generic start/output path must not erase an explicit declaration.
    expect(
      SavedConfigChoice.graph('video', graph).supports(photo, isZh: true),
      isFalse,
    );
  });

  test(
    'graph compatibility rejects processing nodes of another media type',
    () {
      final choice = SavedConfigChoice.graph('image', preset());
      expect(choice.supports(photo, isZh: true), isTrue);
      expect(choice.supports(audio, isZh: true), isFalse);
    },
  );

  test('each application deep clones graph and drops author source path', () {
    final original = preset(media: 'image');
    final choice = SavedConfigChoice.graph('image', original);
    final first = choice.prepare(photo, isZh: true);
    final second = choice.prepare(photo, isZh: true);
    expect(first.nodes.first.params['filepath'], isNull);
    expect(first.nodes.first.params['file_media_type'], 'image');
    expect(first.nodes.first.id, isNot(second.nodes.first.id));
    final values = (first.nodes[1].params['nested'] as Map)['values'] as List;
    values.add(3);
    expect((original.nodes[1].params['nested'] as Map)['values'], [1, 2]);
    expect((second.nodes[1].params['nested'] as Map)['values'], [1, 2]);
    expect(original.nodes.first.params['filepath'], '/author/source.png');
  });

  test('QuickConfig is mapped only for its own media and enabled steps', () {
    final choice = SavedConfigChoice.quick(
      QuickConfig(
        id: 'q',
        name: 'sound',
        fileType: QuickFileType.audio,
        items: [
          QuickConfigItem(key: 'bitrate', params: {'bitrate': 192}),
        ],
      ),
    );
    expect(choice.supports(photo, isZh: true), isFalse);
    final graph = choice.prepare(audio, isZh: true);
    expect(
      graph.nodes.any((n) => n.type == PipelineStepType.audioQuality),
      isTrue,
    );
    expect(graph.nodes.first.params['file_media_type'], 'audio');
  });

  for (final cancel in [false, true]) {
    testWidgets(
      'picker ${cancel ? 'cancel preserves both files' : 'applies only target without queueing'}',
      (tester) async {
        final other = VideoFile.fromFilepath('/current/other.png');
        final state = MemoryState([photo, other]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showApplySavedConfig(
                    context,
                    state,
                    photo,
                    loadChoices: () async => [
                      SavedConfigChoice.graph(
                        'Picture preset',
                        preset(media: 'image'),
                      ),
                      SavedConfigChoice.graph(
                        'Wrong audio',
                        preset(
                          media: 'audio',
                          step: PipelineStepType.audioVolume,
                        ),
                      ),
                    ],
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Picture preset'), findsOneWidget);
        expect(find.text('Wrong audio'), findsNothing);
        await tester.tap(find.text(cancel ? '取消' : 'Picture preset'));
        await tester.pumpAndSettle();
        expect(state.applications, cancel ? 0 : 1);
        expect(
          identical(state.files[0].pipelineGraph, photo.pipelineGraph),
          cancel,
        );
        expect(state.files[1].pipelineGraph, same(other.pipelineGraph));
        expect(state.tasks, isEmpty);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  }

  testWidgets(
    'empty library and read failures are reported without application',
    (tester) async {
      final state = MemoryState([photo]);
      var fail = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showApplySavedConfig(
                  context,
                  state,
                  photo,
                  loadChoices: () async {
                    if (fail) throw const FormatException('bad library');
                    return [];
                  },
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('配置库中没有适用于此文件'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      fail = true;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('无法应用配置，请检查配置库中的配置。'), findsOneWidget);
      expect(state.applications, 0);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
