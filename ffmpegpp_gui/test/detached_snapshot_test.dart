import 'dart:convert';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/pages/detached_window_page.dart';
import 'package:ffmpegpp_gui/pages/pipeline_editor_page.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/multi_window.dart';
import 'package:ffmpegpp_gui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  test('editor panel app-data snapshots omit AI-only shared collections', () {
    final aiData = <String, dynamic>{
      'videos': [
        for (var i = 0; i < 240; i++)
          {
            'id': 'video-$i',
            'filename': 'recording-$i.mp4',
            'sizeMb': 8192.5,
            'parsed': true,
          },
      ],
      'containers': [
        for (var i = 0; i < 64; i++)
          {'id': 'container-$i', 'name': 'Archive $i', 'fileCount': 320},
      ],
      'tasks': [
        for (var i = 0; i < 180; i++)
          {
            'id': 'task-$i',
            'filename': 'recording-$i.mp4',
            'inputPath': '/media/recording-$i.mp4',
            'outputPath': '/output/recording-$i.mp4',
            'status': 'completed',
            'progress': 100.0,
          },
      ],
    };
    var builds = 0;
    Map<String, dynamic> buildAiData() {
      builds++;
      return aiData;
    }

    for (final panel in const [
      DetachedPanel.props,
      DetachedPanel.elements,
      DetachedPanel.properties,
    ]) {
      final data = panelAppDataSnapshot(panel, buildAiData);
      expect(data, isEmpty, reason: panel.id);
      expect(
        builds,
        0,
        reason: '${panel.name} must not enumerate AI collections',
      );
      expect(
        jsonEncode({'appData': data}).length,
        lessThan(jsonEncode({'appData': aiData}).length),
      );
    }

    final data = panelAppDataSnapshot(DetachedPanel.ai, buildAiData);
    expect(builds, 1);
    expect(data, same(aiData));
    expect(data.keys, containsAll(['videos', 'containers', 'tasks']));
    expect((data['videos'] as List).length, 240);
    expect((data['containers'] as List).length, 64);
    expect((data['tasks'] as List).length, 180);
  });

  testWidgets('host snapshots preserve panel inputs without unrelated state', (
    tester,
  ) async {
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isMaximized') return false;
      throw PlatformException(code: 'unexpected_method', message: call.method);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = MirrorAppState(send: (method, [args]) async => null);
    addTearDown(state.dispose);
    final config = AppConfig()
      ..language = 'en'
      ..aiEnabled = false
      ..cardStyle = 'gray'
      ..menuStyle = 'gray'
      ..pillStyle = 'gray';
    state.hydrate({
      'config': config.toJson(),
      'appData': {
        'videos': [
          for (var i = 0; i < 240; i++)
            {'id': 'video-$i', 'filename': 'recording-$i.mp4', 'parsed': true},
        ],
        'containers': [
          for (var i = 0; i < 64; i++)
            FileContainer(id: 'container-$i', name: 'Archive $i').toJson(),
        ],
        'tasks': [
          for (var i = 0; i < 180; i++)
            TaskInfo(
              id: 'task-$i',
              videoId: 'video-$i',
              filename: 'recording-$i.mp4',
              inputPath: '/media/recording-$i.mp4',
              outputPath: '/output/recording-$i.mp4',
              config: TranscodeConfig(),
              status: TaskStatus.completed,
              progress: 100,
            ).toJson(),
        ],
      },
    });
    state.config.aiApiKey = 'test-only-key';
    final video = VideoFile(
      id: 'snapshot-source',
      filename: 'Template.mp4',
      width: 1920,
      height: 1080,
      fps: 25,
      subtitles: [
        SubtitleStream(
          index: 2,
          codec: 'subrip',
          language: 'eng',
          isDefault: true,
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: PipelineEditorPage(
            video: video,
            onSave: (_) {},
            containerInfo: (
              name: 'Source archive',
              fileCount: 12,
              typeCounts: {MediaType.video: 12},
              fileIds: const [],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final host =
        tester.state(find.byType(PipelineEditorPage)) as PanelHostDelegate;
    final initialAi = host.panelSnapshot(DetachedPanel.ai);
    final start = (initialAi['graph']['nodes'] as List).cast<Map>().firstWhere(
      (node) => node['type'] == PipelineStepType.start.name,
    );
    await tester.tap(find.byKey(ValueKey('node-${start['id']}')));
    await tester.pump();
    final snapshots = {
      for (final panel in DetachedPanel.values)
        panel: host.panelSnapshot(panel),
    };
    final ai = snapshots[DetachedPanel.ai]!;
    final elements = snapshots[DetachedPanel.elements]!;
    final properties = snapshots[DetachedPanel.properties]!;
    expect(properties['selection'], isA<Map>());
    final sizes = <String, dynamic>{};
    for (final panel in DetachedPanel.values) {
      final snapshot = snapshots[panel]!;
      // Exercise the same JSON boundary used by the process transport.
      final wire = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(snapshot)) as Map,
      );
      final store = PanelWindowStore(
        DetachedWindowArgs(panel: panel),
        send: (method, [args]) async => null,
      );
      addTearDown(store.dispose);
      store.hydrate(wire);
      expect(store.config.language, 'en');
      if (panel == DetachedPanel.ai) {
        expect(store.app.videos, hasLength(240));
        expect(store.app.containers, hasLength(64));
        expect(store.app.tasks, hasLength(180));
        expect(store.nodes, hasLength(2));
        expect(store.connections, hasLength(1));
        expect(store.app.config.aiApiKey, 'test-only-key');
        expect(wire['ai']['session'], isA<List>());
        expect(wire.containsKey('video'), isFalse);
        expect(wire.containsKey('toolbox'), isFalse);
        continue;
      }
      expect(store.app.videos, isEmpty);
      expect(store.app.containers, isEmpty);
      expect(store.app.tasks, isEmpty);
      expect(store.nodes, isEmpty);
      for (final field in ['graph', 'ai', 'aiCredentials']) {
        expect(wire.containsKey(field), isFalse, reason: '${panel.id}: $field');
      }
      expect(store.video['width'], 1920);
      expect(store.video['subtitles'], hasLength(1));
      expect(store.video['subtitles'][0]['default'], isTrue);
      expect(store.props['containerName'], 'Source archive');
      if (panel != DetachedPanel.properties) {
        expect(store.toolbox, isNotEmpty);
      } else {
        expect(store.toolbox, isEmpty);
      }
      if (panel != DetachedPanel.elements) {
        expect(store.selected?.id, start['id']);
        expect(store.props['containerFileCount'], 12);
        expect(store.props, contains('sourceImagePath'));
        expect(store.props, contains('outputName'));
      } else {
        expect(store.selected, isNull);
        expect(store.props.keys, ['containerName']);
      }
      final legacy = <String, dynamic>{
        ...snapshot,
        'appData': ai['appData'],
        'graph': ai['graph'],
        'ai': ai['ai'],
        'aiCredentials': ai['aiCredentials'],
        'toolbox': elements['toolbox'],
        'video': properties['video'],
        'props': properties['props'],
        'selection': properties['selection'],
      };
      final before = utf8.encode(jsonEncode(legacy)).length;
      final after = utf8.encode(jsonEncode(wire)).length;
      expect(after, lessThan(before ~/ 2));
      sizes[panel.id] = {'before': before, 'after': after};
    }
    debugPrint('Panel snapshot fixture bytes: ${jsonEncode(sizes)}');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });
}
