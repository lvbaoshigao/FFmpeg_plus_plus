import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/plugins/plugin_execution.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manager.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manifest.dart';
import 'package:ffmpegpp_gui/plugins/plugin_node_catalog.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/backend_client.dart';
import 'package:ffmpegpp_gui/services/config_service.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plugin_node_test.dart' as fixture;

const _ffmpeg = {
  'api_version': 1,
  'max_arguments': 128,
  'max_argument_bytes': 8192,
  'max_total_argument_bytes': 32768,
  'options': ['-af', '-vf', '-c:a', '-vn'],
  'filters': ['volume', 'scale'],
};

PluginExecutionCapabilities _capabilities([Map<String, dynamic>? ffmpeg]) =>
    PluginExecutionCapabilities.fromBackendResponse({
      'success': true,
      'data': {'available': true, 'ffmpeg': ffmpeg ?? _ffmpeg},
    });

class _MemoryConfig extends ConfigService {
  @override
  Future<void> saveTaskHistory(List<Map<String, dynamic>> entries) async {}
}

class _Process extends NativeProcessManager {
  final calls = <Map<String, dynamic>>[];
  Future<void> Function()? beforeReply;
  final entered = Completer<void>();
  Completer<void>? release;
  final cancellations = <List<String>?>[];
  bool replySuccess = true;
  bool writeOutput = true;

  @override
  void cancel([List<String>? taskIds]) => cancellations.add(taskIds);

  @override
  Future<Map<String, dynamic>> requestWithId(
    String id,
    String action, [
    Map<String, dynamic>? params,
  ]) async {
    calls.add({'id': id, 'action': action, 'params': params});
    if (!entered.isCompleted) entered.complete();
    if (release != null) await release!.future;
    await beforeReply?.call();
    if (writeOutput) {
      await File(params!['input'] as String).copy(params['output'] as String);
    }
    return {
      'success': replySuccess,
      'data': {'output_path': params!['output']},
    };
  }
}

class _State extends AppState {
  _State(this.manager, this.process, this.capabilities);
  final PluginManager manager;
  final _Process process;
  final PluginExecutionCapabilities capabilities;
  late final client = BackendClient(process);
  final memory = _MemoryConfig();

  @override
  PluginManager get plugins => manager;
  @override
  BackendClient get backend => client;
  @override
  ConfigService get configService => memory;
  @override
  PluginExecutionCapabilities get pluginExecutionCapabilities => capabilities;
}

class _Harness {
  _Harness(this.root, this.manifest, this.manager, this.process, this.state);
  final Directory root;
  final PluginManifest manifest;
  final PluginManager manager;
  final _Process process;
  final _State state;
  final requests = <Map<String, dynamic>>[];
  Map<String, dynamic> result = {
    'operation': 'ffmpeg.execute',
    'arguments': ['-af', 'volume=-3dB'],
  };
  Future<void> Function()? beforeGuestReply;

  static Future<_Harness> create({
    String outputType = 'audio',
    bool supported = true,
  }) async {
    final root = await Directory.systemTemp.createTemp('fpp-ffmpeg-execution-');
    final raw = fixture.fixture().toJson();
    (raw['Node_info'] as List).single['output_type'] = outputType;
    final manifest = PluginManifest.fromJson(raw);
    late _Harness harness;
    final manager = PluginManager(
      root: Directory('${root.path}/plugins'),
      appVersion: '6.0.0-beta2',
      runtime: CallbackPluginRuntime((path, entry, request, limits) async {
        if (entry == 'Basic_info') return manifest.basicInfo.toJson();
        if (entry == 'Node_info') {
          return {
            'nodes': manifest.nodes.map((node) => node.toJson()).toList(),
          };
        }
        if (entry == 'Node_execute') {
          harness.requests.add(PipelineNode.deepCopyMap(request));
          await harness.beforeGuestReply?.call();
          return harness.result;
        }
        throw StateError('Unexpected entry: $entry');
      }),
    );
    final process = _Process();
    final state = _State(
      manager,
      process,
      supported ? _capabilities() : const PluginExecutionCapabilities(),
    );
    harness = _Harness(root, manifest, manager, process, state);
    addTearDown(() async {
      state.dispose();
      process.dispose();
      manager.dispose();
      PluginNodeCatalog.instance.clear();
      await root.delete(recursive: true);
    });
    await manager.initialize();
    final bytes = utf8.encode(jsonEncode(manifest.toJson()));
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', bytes.length, bytes))
      ..addFile(ArchiveFile('plugin.wasm', 8, [0, 97, 115, 109, 1, 0, 0, 0]));
    await manager.installPackage(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    await manager.setFeatureEnabled(true);
    await manager.setEnabled(manifest.id, true);
    state.config
      ..pluginsEnabled = true
      ..language = 'en';
    return harness;
  }

  Future<TaskInfo> run({
    void Function(List<BackendCall>)? mutateCalls,
    String outputSubdirectory = '',
    List<int>? existingOutput,
    Future<void> Function(File input, File output)? prepareOutput,
  }) async {
    final input = File('${root.path}/input.wav');
    await input.writeAsBytes([82, 73, 70, 70, 0, 1, 2, 3]);
    final outputRoot = outputSubdirectory.isEmpty
        ? root.path
        : '${root.path}/$outputSubdirectory';
    final output =
        '$outputRoot/output.${manifest.nodes.single.outputType == 'video' ? 'mkv' : 'wav'}';
    if (existingOutput != null) {
      await File(output).parent.create(recursive: true);
      await File(output).writeAsBytes(existingOutput);
    }
    await prepareOutput?.call(input, File(output));
    final graph = fixture.graphFor(fixture.pluginNode(manifest));
    final compiled = GraphExecutor.buildBackendCalls(
      GraphExecutor.resolvePlans(graph).single,
      input.path,
      output,
    )!;
    final restored = [
      for (final call in compiled)
        BackendCall.fromJson(
          jsonDecode(jsonEncode(call.toJson())) as Map<String, dynamic>,
        ),
    ];
    mutateCalls?.call(restored);
    state.addTaskForTest(
      TaskInfo(
        id: 'plugin-task',
        videoId: '',
        filename: 'input.wav',
        inputPath: input.path,
        outputPath: output,
        config: TranscodeConfig(),
        pipelineCalls: restored,
      ),
    );
    final finished = Completer<void>();
    void listener() {
      if (!state.processing &&
          state.tasks.single.status != TaskStatus.pending &&
          !finished.isCompleted) {
        finished.complete();
      }
    }

    state.addListener(listener);
    try {
      await state.processNextTask();
      await finished.future.timeout(const Duration(seconds: 5));
      return state.tasks.single;
    } finally {
      state.removeListener(listener);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => PluginNodeCatalog.instance.clear());

  test(
    'discovery does not advertise new operations for old or malformed backends',
    () {
      for (final response in <Map<String, dynamic>>[
        {},
        {
          'success': true,
          'data': {'available': true},
        },
        {
          'success': false,
          'data': {'available': true, 'ffmpeg': _ffmpeg},
        },
        {
          'success': true,
          'data': {'available': false, 'ffmpeg': _ffmpeg},
        },
        {
          'success': true,
          'data': {
            'available': true,
            'ffmpeg': {..._ffmpeg, 'api_version': 2},
          },
        },
      ]) {
        final caps = PluginExecutionCapabilities.fromBackendResponse(response);
        expect(caps.supportsFfmpeg, isFalse);
        expect(
          caps.toRequestHost()['operations'],
          isNot(contains('ffmpeg.execute')),
        );
        expect(caps.toRequestHost().containsKey('ffmpeg'), isFalse);
      }
      final caps = _capabilities();
      final exposed = caps.toRequestHost();
      ((exposed['ffmpeg'] as Map)['filters'] as List).clear();
      expect((caps.toRequestHost()['ffmpeg'] as Map)['filters'], [
        'volume',
        'scale',
      ]);
    },
  );

  test('FFmpeg result enforces exact envelope and UTF-8 byte limits', () {
    final caps = _capabilities({
      ..._ffmpeg,
      'max_argument_bytes': 8,
      'max_total_argument_bytes': 12,
    });
    expect(
      caps.validateFfmpegResult({
        'operation': 'ffmpeg.execute',
        'arguments': ['-af', '音量'],
      }),
      ['-af', '音量'],
    );
    for (final result in [
      {
        'operation': 'ffmpeg.execute',
        'arguments': ['-af'],
        'output': '/tmp/other',
      },
      {
        'operation': 'ffmpeg.execute',
        'arguments': [3],
      },
      {
        'operation': 'ffmpeg.execute',
        'arguments': ['a\u0000b'],
      },
      {
        'operation': 'ffmpeg.execute',
        'arguments': ['音量音量'],
      },
      {
        'operation': 'ffmpeg.execute',
        'arguments': ['12345678', '12345'],
      },
      {'operation': 'ffmpeg.execute', 'arguments': List.filled(129, 'a')},
    ]) {
      expect(() => caps.validateFfmpegResult(result), throwsFormatException);
    }
  });

  test(
    'persisted deferred call uses tracked task action and discovered host metadata',
    () async {
      final h = await _Harness.create(outputType: 'video');
      final finished = await h.run();
      expect(finished.status, TaskStatus.completed, reason: finished.error);
      final stagedOutput =
          (h.process.calls.single['params'] as Map)['output'] as String;
      expect(stagedOutput, startsWith('${h.root.path}/.ffmpegpp-plugin-'));
      expect(stagedOutput, endsWith('/output.mkv'));
      expect(File(stagedOutput).existsSync(), isFalse);
      expect(Directory(stagedOutput).parent.existsSync(), isFalse);
      expect(h.process.calls.single, {
        'id': 'plugin-task',
        'action': 'plugin_ffmpeg',
        'params': {
          'input': '${h.root.path}/input.wav',
          'output': stagedOutput,
          'arguments': ['-af', 'volume=-3dB'],
          'input_type': 'audio',
          'output_type': 'video',
        },
      });
      final request = h.requests.single;
      expect(request['media_type'], 'audio');
      expect(request['input_media_type'], 'audio');
      expect(request['output_media_type'], 'video');
      expect(request['host'], h.state.capabilities.toRequestHost());
      expect(request.containsKey('input'), isFalse);
      expect(request.containsKey('output'), isFalse);
      expect(h.state.client.isTaskRunning('plugin-task'), isFalse);
      expect(finished.pipelineCalls!.single.action, '_plugin');
    },
  );

  test(
    'old persisted calls infer new media fields from the live declaration',
    () async {
      final h = await _Harness.create();
      final task = await h.run(
        mutateCalls: (calls) {
          calls.single.params.remove('input_media_type');
          calls.single.params.remove('output_media_type');
        },
      );
      expect(task.status, TaskStatus.completed, reason: task.error);
      expect(h.requests.single['input_media_type'], 'audio');
      expect(h.requests.single['output_media_type'], 'audio');
    },
  );

  test(
    'guest cannot override host input or output in the FFmpeg result',
    () async {
      final h = await _Harness.create();
      h.result = {...h.result, 'output': '/tmp/untrusted-output.wav'};
      expect((await h.run()).status, TaskStatus.failed);
      expect(h.process.calls, isEmpty);
    },
  );

  test(
    'cancelling a native plugin step keeps the task cancelled after its reply',
    () async {
      final h = await _Harness.create();
      h.process.release = Completer<void>();
      final finished = h.run(existingOutput: [9, 8, 7]);
      await h.process.entered.future.timeout(const Duration(seconds: 5));
      h.state.cancelTask('plugin-task');
      expect(h.process.cancellations, [
        ['plugin-task'],
      ]);
      h.process.release!.complete();
      expect((await finished).status, TaskStatus.cancelled);
      expect(h.state.client.isTaskRunning('plugin-task'), isFalse);
      expect(await File('${h.root.path}/output.wav').readAsBytes(), [9, 8, 7]);
      final output =
          (h.process.calls.single['params'] as Map)['output'] as String;
      expect(Directory(output).parent.existsSync(), isFalse);
    },
  );

  test(
    'exact bounded guest error preserves the plugin author explanation',
    () async {
      final h = await _Harness.create();
      h.result = {
        'error': 'This FFmpeg build does not provide the required filter.',
      };
      final task = await h.run();
      expect(task.status, TaskStatus.failed);
      expect(task.error, contains(h.result['error']));
      expect(task.error, isNot(contains('unsupported operation')));
      expect(h.process.calls, isEmpty);
    },
  );

  test(
    'malformed guest error responses cannot dispatch an operation',
    () async {
      for (final response in <Map<String, dynamic>>[
        {'error': ''},
        {'error': '   '},
        {'error': 42},
        {'error': 'bad\u0000message'},
        {'error': List.filled(2049, 'x').join()},
        {'error': 'no', 'operation': 'media.copy'},
      ]) {
        final h = await _Harness.create();
        h.result = response;
        final task = await h.run();
        expect(task.status, TaskStatus.failed);
        expect(task.error, contains('Invalid plugin error response.'));
        expect(h.process.calls, isEmpty);
      }
    },
  );

  test('new operation fails closed on an older backend', () async {
    final h = await _Harness.create(supported: false);
    expect((await h.run()).status, TaskStatus.failed);
    expect(h.process.calls, isEmpty);
  });

  test('cross-media media.copy and old audio operation are rejected', () async {
    final h = await _Harness.create(outputType: 'video');
    h.result = {'operation': 'media.copy'};
    expect((await h.run()).status, TaskStatus.failed);
    expect(h.process.calls, isEmpty);
  });

  test(
    'old audio operation keeps its declared output media constraint',
    () async {
      final h = await _Harness.create(outputType: 'video');
      h.result = {'operation': 'audio.volume', 'decibels': -3};
      expect((await h.run()).status, TaskStatus.failed);
      expect(h.process.calls, isEmpty);
    },
  );

  test(
    'persisted output type cannot override the live node declaration',
    () async {
      final h = await _Harness.create();
      final task = await h.run(
        mutateCalls: (calls) =>
            calls.single.params['output_media_type'] = 'video',
      );
      expect(task.status, TaskStatus.failed);
      expect(h.requests, isEmpty);
      expect(h.process.calls, isEmpty);
    },
  );

  test(
    'node disabled before guest result cannot start a media operation',
    () async {
      final h = await _Harness.create();
      late Future<void> mutation;
      h.beforeGuestReply = () =>
          mutation = h.manager.setNodeEnabled(h.manifest.id, 'volume', false);
      final finished = await h.run();
      await mutation;
      expect(finished.status, TaskStatus.failed);
      expect(h.process.calls, isEmpty);
    },
  );

  test(
    'node disabled during native operation cannot publish a successful task',
    () async {
      final h = await _Harness.create();
      h.process.beforeReply = () =>
          h.manager.setNodeEnabled(h.manifest.id, 'volume', false);
      expect(
        (await h.run(existingOutput: [9, 8, 7])).status,
        TaskStatus.failed,
      );
      expect(h.process.calls, hasLength(1));
      expect(await File('${h.root.path}/output.wav').readAsBytes(), [9, 8, 7]);
      final output =
          (h.process.calls.single['params'] as Map)['output'] as String;
      expect(Directory(output).parent.existsSync(), isFalse);
    },
  );

  test(
    'new final output directory is created before native execution',
    () async {
      final h = await _Harness.create();
      expect(Directory('${h.root.path}/new/final').existsSync(), isFalse);
      final task = await h.run(outputSubdirectory: 'new/final');
      expect(task.status, TaskStatus.completed, reason: task.error);
      expect(task.outputPath, '${h.root.path}/new/final/output.wav');
      expect(
        await File(task.outputPath).readAsBytes(),
        await File('${h.root.path}/input.wav').readAsBytes(),
      );
      final output =
          (h.process.calls.single['params'] as Map)['output'] as String;
      expect(output, startsWith('${h.root.path}/new/final/.ffmpegpp-plugin-'));
      expect(Directory(output).parent.existsSync(), isFalse);
    },
  );

  test(
    'successful native stage atomically replaces an existing final output',
    () async {
      final h = await _Harness.create();
      final task = await h.run(existingOutput: [9, 8, 7]);
      expect(task.status, TaskStatus.completed, reason: task.error);
      expect(
        await File(task.outputPath).readAsBytes(),
        await File('${h.root.path}/input.wav').readAsBytes(),
      );
      final output =
          (h.process.calls.single['params'] as Map)['output'] as String;
      expect(Directory(output).parent.existsSync(), isFalse);
    },
  );

  test(
    'failed native stage preserves an existing final output and cleans its workspace',
    () async {
      final h = await _Harness.create();
      h.process.replySuccess = false;
      final task = await h.run(existingOutput: [9, 8, 7]);
      expect(task.status, TaskStatus.failed);
      expect(await File('${h.root.path}/output.wav').readAsBytes(), [9, 8, 7]);
      final output =
          (h.process.calls.single['params'] as Map)['output'] as String;
      expect(Directory(output).parent.existsSync(), isFalse);
    },
  );

  test(
    'native success without a staged regular file preserves existing output',
    () async {
      final h = await _Harness.create();
      h.process.writeOutput = false;
      final task = await h.run(existingOutput: [9, 8, 7]);
      expect(task.status, TaskStatus.failed);
      expect(await File('${h.root.path}/output.wav').readAsBytes(), [9, 8, 7]);
      final output =
          (h.process.calls.single['params'] as Map)['output'] as String;
      expect(Directory(output).parent.existsSync(), isFalse);
    },
  );

  test('staging does not bypass the input equals final output guard', () async {
    final h = await _Harness.create();
    final task = await h.run(
      mutateCalls: (calls) {
        calls.single.params['output'] = '${h.root.path}/input.wav';
      },
    );
    expect(task.status, TaskStatus.failed);
    expect(h.process.calls, isEmpty);
    expect(await File('${h.root.path}/input.wav').readAsBytes(), [
      82,
      73,
      70,
      70,
      0,
      1,
      2,
      3,
    ]);
  });

  test('staging rejects a final hardlink to the input', () async {
    final h = await _Harness.create();
    final task = await h.run(
      prepareOutput: (input, output) async {
        final result = await Process.run('ln', [input.path, output.path]);
        expect(result.exitCode, 0, reason: result.stderr as String);
      },
    );
    expect(task.status, TaskStatus.failed);
    expect(h.process.calls, isEmpty);
    expect(await File('${h.root.path}/input.wav').readAsBytes(), [
      82,
      73,
      70,
      70,
      0,
      1,
      2,
      3,
    ]);
  }, skip: !Platform.isLinux && !Platform.isMacOS);

  test(
    'staging rejects a final symlink without modifying its target',
    () async {
      final h = await _Harness.create();
      final task = await h.run(
        prepareOutput: (input, output) async {
          await Link(output.path).create(input.path);
        },
      );
      expect(task.status, TaskStatus.failed);
      expect(h.process.calls, isEmpty);
      expect(await File('${h.root.path}/input.wav').readAsBytes(), [
        82,
        73,
        70,
        70,
        0,
        1,
        2,
        3,
      ]);
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );

  test(
    'changed output directory alias cannot redirect publication or cleanup',
    () async {
      final h = await _Harness.create();
      final original = await Directory('${h.root.path}/original').create();
      final other = await Directory('${h.root.path}/other').create();
      final alias = Link('${h.root.path}/alias');
      await alias.create(original.path);
      await File('${other.path}/output.wav').writeAsBytes([4, 5, 6]);
      h.process.beforeReply = () async {
        await alias.delete();
        await alias.create(other.path);
      };
      final task = await h.run(
        outputSubdirectory: 'alias',
        existingOutput: [9, 8, 7],
      );
      expect(task.status, TaskStatus.failed);
      expect(await File('${original.path}/output.wav').readAsBytes(), [
        9,
        8,
        7,
      ]);
      expect(await File('${other.path}/output.wav').readAsBytes(), [4, 5, 6]);
      final output =
          (h.process.calls.single['params'] as Map)['output'] as String;
      expect(Directory(output).parent.existsSync(), isFalse);
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );

  test('backend tracks active FFmpeg tasks until native completion', () async {
    final h = await _Harness.create();
    h.process.release = Completer<void>();
    final finished = h.run();
    await h.process.entered.future.timeout(const Duration(seconds: 5));
    expect(h.state.client.isTaskRunning('plugin-task'), isTrue);
    h.process.release!.complete();
    expect((await finished).status, TaskStatus.completed);
    expect(h.state.client.isTaskRunning('plugin-task'), isFalse);
  });
}
