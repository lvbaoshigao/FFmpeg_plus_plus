import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manager.dart';
import 'package:ffmpegpp_gui/plugins/plugin_node_catalog.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plugin_node_test.dart' as fixture;

class _MemoryConfig extends ConfigService {
  @override
  Future<void> saveTaskHistory(List<Map<String, dynamic>> entries) async {}
}

class _State extends AppState {
  _State(this.manager);

  final PluginManager manager;
  final _memory = _MemoryConfig();

  @override
  PluginManager get plugins => manager;

  @override
  ConfigService get configService => _memory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'compiled plugin calls execute through AppState after persistence',
    () async {
      final root = await Directory.systemTemp.createTemp('fpp-plugin-task-');
      final manifest = fixture.fixture();
      final invocations = <Map<String, dynamic>>[];
      final manager = PluginManager(
        root: Directory('${root.path}/plugins'),
        appVersion: '6.0.0-beta2',
        runtime: CallbackPluginRuntime((path, entry, request, limits) async {
          switch (entry) {
            case 'Basic_info':
              return manifest.basicInfo.toJson();
            case 'Node_info':
              return {
                'nodes': manifest.nodes.map((node) => node.toJson()).toList(),
              };
            case 'Node_execute':
              invocations.add(PipelineNode.deepCopyMap(request));
              return {'operation': 'media.copy'};
            default:
              throw StateError('Unexpected plugin entry: $entry');
          }
        }),
      );
      final state = _State(manager);
      addTearDown(() async {
        state.dispose();
        manager.dispose();
        PluginNodeCatalog.instance.clear();
        await root.delete(recursive: true);
      });
      PluginNodeCatalog.instance.clear();
      await manager.initialize();
      final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
      final archive = Archive()
        ..addFile(
          ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
        )
        ..addFile(ArchiveFile('plugin.wasm', 8, [0, 97, 115, 109, 1, 0, 0, 0]));
      await manager.installPackage(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
      await manager.setFeatureEnabled(true);
      await manager.setEnabled(manifest.id, true);
      expect(manager.isActive(manifest.id), isTrue);
      state.config
        ..pluginsEnabled = true
        ..language = 'en';

      final input = File('${root.path}/input.wav');
      final output = File('${root.path}/output.wav');
      final inputBytes = [82, 73, 70, 70, 0, 1, 2, 3];
      await input.writeAsBytes(inputBytes);
      final graph = fixture.graphFor(fixture.pluginNode(manifest));
      expect(GraphExecutor.validateGraph(graph), isEmpty);
      final calls = GraphExecutor.buildBackendCalls(
        GraphExecutor.resolvePlans(graph).single,
        input.path,
        output.path,
      );
      expect(calls, isNotNull);
      // Exercise the same JSON boundary as persisted task history, using the
      // compiler's actual payload rather than a hand-built execution call.
      final restoredCalls = [
        for (final call in calls!)
          BackendCall.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(jsonEncode(call.toJson())) as Map,
            ),
          ),
      ];
      state.addTaskForTest(
        TaskInfo(
          id: 'compiled-plugin',
          videoId: '',
          filename: 'input.wav',
          inputPath: input.path,
          outputPath: output.path,
          config: TranscodeConfig(),
          pipelineCalls: restoredCalls,
          command: const ['retained execution log'],
        ),
      );
      final finished = Completer<void>();
      void onChange() {
        if (!state.processing &&
            state.tasks.single.status != TaskStatus.pending &&
            !finished.isCompleted) {
          finished.complete();
        }
      }

      state.addListener(onChange);
      try {
        await state.processNextTask();
        await finished.future.timeout(const Duration(seconds: 5));
      } finally {
        state.removeListener(onChange);
      }

      expect(
        state.tasks.single.status,
        TaskStatus.completed,
        reason: state.tasks.single.error,
      );
      expect(invocations, [
        {
          'api_version': 1,
          'plugin_id': manifest.id,
          'node_id': manifest.nodes.single.id,
          'schema_version': manifest.nodes.single.schemaVersion,
          'params': {'gain': -3},
          'media_type': 'audio',
          'input_media_type': 'audio',
          'output_media_type': 'audio',
          'host': {
            'api_version': 1,
            'operations': [
              'media.copy',
              'audio.volume',
              'video.flip',
              'video.scale',
            ],
          },
        },
      ]);
      expect(await output.readAsBytes(), inputBytes);
    },
  );
}
