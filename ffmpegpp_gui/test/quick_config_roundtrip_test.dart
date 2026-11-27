import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/services/backend_client.dart';
import 'package:ffmpegpp_gui/services/fppx2_service.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:ffmpegpp_gui/services/quick_config_pipeline.dart';
import 'package:ffmpegpp_gui/services/saved_config_application.dart';
import 'package:flutter_test/flutter_test.dart';

QuickConfig _legacy(QuickFileType type, List<QuickConfigItem> items) =>
    QuickConfig(
      id: 'roundtrip',
      name: 'Preset',
      fileType: type,
      items: items,
      inputParams: {
        'filepath': '/author/private-source',
        'node_name': 'Saved input',
        'quick_editor_metadata': {
          'labels': ['input'],
        },
      },
      outputParams: {
        'output_dir': '/saved/${type.name}',
        'format': switch (type) {
          QuickFileType.audio => 'flac',
          QuickFileType.image => 'png',
          QuickFileType.video => 'mp4',
        },
        'naming_mode': 'suffix',
        'naming_value': '_preserved',
        'quick_editor_metadata': {
          'labels': ['output'],
        },
      },
    );

List<QuickConfig> _presets() => [
  _legacy(QuickFileType.audio, [
    QuickConfigItem(key: 'bitrate', params: {'bitrate': 192}),
  ]),
  _legacy(QuickFileType.audio, [
    QuickConfigItem(key: 'convert_format', params: {'format': 'mp3'}),
  ]),
  _legacy(QuickFileType.image, [
    QuickConfigItem(key: 'resize', params: {'w': 640, 'h': 480}),
    QuickConfigItem(key: 'convert_format', params: {'format': 'png'}),
  ]),
  _legacy(QuickFileType.video, [
    QuickConfigItem(key: 'compress', params: {'codec': 'h264'}),
    QuickConfigItem(key: 'rotate', params: {'angle': 90}),
  ]),
  QuickConfig(
    id: 'ordered',
    fileType: QuickFileType.audio,
    nodes: [
      createQuickConfigNode(PipelineStepType.audioVolume, MediaType.audio)
        ..params['volume_db'] = -6.0,
      createQuickConfigNode(PipelineStepType.audioVolume, MediaType.audio)
        ..params['volume_db'] = 3.0,
      createQuickConfigNode(PipelineStepType.audioSpectrum, MediaType.audio),
      createQuickConfigNode(PipelineStepType.imageRotate, MediaType.image),
    ],
    inputParams: {'filepath': '/author/private.wav'},
    outputParams: {
      'format': 'png',
      'naming_mode': 'suffix',
      'naming_value': '_done',
    },
  ),
];

VideoFile _file(QuickFileType type) => VideoFile.fromFilepath(switch (type) {
  QuickFileType.audio => '/target/music.wav',
  QuickFileType.image => '/target/photo.png',
  QuickFileType.video => '/target/video.mp4',
});

void _expectEditableRoundtrip(QuickConfig preset, PipelineGraph imported) {
  final applied = SavedConfigChoice.graph(
    'Imported preset',
    imported,
  ).prepare(_file(preset.fileType), isZh: false);
  expect(applied.nodes.last.params, preset.outputParams);
  if (preset.nodes == null) {
    expect(applied.nodes.first.params['node_name'], 'Saved input');
    expect(
      applied.nodes.last.params['output_dir'],
      '/saved/${preset.fileType.name}',
    );
    expect(applied.nodes.last.params['naming_mode'], 'suffix');
    expect(applied.nodes.last.params['naming_value'], '_preserved');
  }
  final restored = quickConfigFromGraph(
    graph: applied,
    fileType: preset.fileType,
  );
  expect(validateQuickConfigNodes(restored), isEmpty);
  final rebuilt = buildApplicableQuickConfigGraph(restored, isZh: false);
  expect(GraphExecutor.validateGraph(rebuilt), isEmpty);
  expect(rebuilt.logicBlocks, isEmpty);
  expect(rebuilt.connections.length, rebuilt.nodes.length - 1);
  expect(rebuilt.nodes.first.params['file_media_type'], preset.fileType.name);
  expect(rebuilt.nodes.first.params['filepath'], isNull);
  final expected = buildApplicableQuickConfigGraph(preset, isZh: false);
  final expectedProcessors = expected.nodes
      .skip(1)
      .take(expected.nodes.length - 2);
  expect(
    restored.nodes!.map((node) => node.type),
    expectedProcessors.map((node) => node.type),
  );
  expect(
    restored.nodes!.map((node) => node.params),
    expectedProcessors.map((node) => node.params),
  );
  expect(rebuilt.nodes.last.params, preset.outputParams);
}

void main() {
  final presets = _presets();
  group('typed quick configuration roundtrip', () {
    for (final (index, preset) in presets.indexed) {
      test(
        '${preset.fileType.name} preset $index reopens after JSON and application',
        () {
          final graph = buildApplicableQuickConfigGraph(preset, isZh: false);
          expect(graph.nodes.first.outputType, quickMediaType(preset.fileType));
          final imported = PipelineGraph.fromJson(
            jsonDecode(jsonEncode(graph.toJson())) as Map<String, dynamic>,
          );
          _expectEditableRoundtrip(preset, imported);
        },
      );
    }

    for (final type in QuickFileType.values) {
      test(
        'legacy ${type.name} application retains output settings and isolates nested boundaries',
        () {
          final preset = presets
              .firstWhere(
                (config) => config.fileType == type && config.nodes == null,
              )
              .deepCopy();
          final applied = SavedConfigChoice.quick(
            preset,
          ).prepare(_file(type), isZh: false);
          expect(applied.nodes.first.params['filepath'], isNull);
          expect(applied.nodes.first.params['node_name'], 'Saved input');
          expect(
            applied.nodes.last.params['output_dir'],
            '/saved/${type.name}',
          );
          expect(applied.nodes.last.params['naming_mode'], 'suffix');
          expect(applied.nodes.last.params['naming_value'], '_preserved');
          expect(applied.nodes.last.params['format'], switch (type) {
            QuickFileType.audio => 'flac',
            QuickFileType.image => 'png',
            QuickFileType.video => 'mp4',
          });
          final graph = buildApplicableQuickConfigGraph(preset, isZh: false);
          (graph.nodes.first.params['quick_editor_metadata']['labels'] as List)
              .add('edited');
          (graph.nodes.last.params['quick_editor_metadata']['labels'] as List)
              .add('edited');
          expect(preset.inputParams['quick_editor_metadata']['labels'], [
            'input',
          ]);
          expect(preset.outputParams['quick_editor_metadata']['labels'], [
            'output',
          ]);
          expect(preset.inputParams['filepath'], '/author/private-source');
        },
      );
    }

    test(
      'incomplete legacy mappings cannot be exported or applied partially',
      () {
        final preset = _legacy(QuickFileType.video, [
          QuickConfigItem(key: 'compress', params: {'codec': 'h264'}),
          QuickConfigItem(key: 'subtitle', params: {'subtitle_path': ''}),
        ]);
        expect(
          () => buildApplicableQuickConfigGraph(preset, isZh: false),
          throwsFormatException,
        );
        expect(
          () => SavedConfigChoice.quick(
            preset,
          ).prepare(_file(QuickFileType.video), isZh: false),
          throwsFormatException,
        );
        preset.items.last.enabled = false;
        expect(
          buildApplicableQuickConfigGraph(preset, isZh: false).nodes.length,
          3,
        );
      },
    );

    test('empty presets cannot produce a misleading export', () {
      for (final nodes in [null, <PipelineNode>[]]) {
        expect(
          () => buildApplicableQuickConfigGraph(
            QuickConfig(
              id: 'empty',
              fileType: QuickFileType.audio,
              nodes: nodes,
            ),
            isZh: false,
          ),
          throwsFormatException,
        );
      }
    });

    test('real branching graphs still require the node editor', () {
      final graph = buildApplicableQuickConfigGraph(presets.first, isZh: false);
      graph.connections.add(
        PipelineConnection(
          id: 'branch',
          fromNodeId: graph.nodes.first.id,
          toNodeId: graph.nodes.last.id,
        ),
      );
      expect(
        () => quickConfigFromGraph(graph: graph, fileType: QuickFileType.audio),
        throwsFormatException,
      );
    });
  });

  // Run with --dart-define=FFMPEGPP_TEST_LIBRARY=/path/to/libffmpegpp.so to
  // exercise the real C++ codec and AES, without requiring a native build in CI.
  const nativeLibrary = String.fromEnvironment('FFMPEGPP_TEST_LIBRARY');
  group(
    'native FPPX quick configuration roundtrip',
    () {
      late NativeProcessManager process;
      late BackendClient backend;
      late FppxService service;
      late Directory temporary;

      setUpAll(() async {
        temporary = await Directory.systemTemp.createTemp(
          'quick-fppx-roundtrip-',
        );
        process = NativeProcessManager();
        backend = BackendClient(process);
        service = FppxService(backend);
        await process.start(nativeLibrary);
      });
      tearDownAll(() async {
        backend.dispose();
        process.dispose();
        await temporary.delete(recursive: true);
      });

      test(
        'old audio quick items reproduce media loss and false complex-flow rejection',
        () async {
          final preset = presets.first;
          final path = '${temporary.path}/old-audio.fppx';
          final exported = await service.exportQuickItems(
            path,
            description: '',
            items: preset.items.map((item) => item.toJson()).toList(),
          );
          expect(exported.success, isTrue, reason: exported.error);
          final imported = await service.importFile(path);
          expect(imported.success, isTrue, reason: imported.error);
          final inferred = inferQuickFileTypeFromMaps(imported.quickItems);
          expect(inferred, QuickFileType.video);
          final wrongGraph = buildGraphFromQuickConfig(
            _legacy(
              inferred,
              imported.quickItems.map(QuickConfigItem.fromJson).toList(),
            ),
            isZh: false,
          ).graph;
          expect(
            () => quickConfigFromGraph(
              graph: wrongGraph,
              fileType: QuickFileType.audio,
            ),
            throwsFormatException,
          );
        },
      );

      for (final encrypted in [false, true]) {
        for (final (index, preset) in presets.indexed) {
          test(
            'preset $index export/import/apply/re-edit, encrypted=$encrypted',
            () async {
              final graph = buildApplicableQuickConfigGraph(
                preset,
                isZh: false,
              );
              final path = '${temporary.path}/preset-$index-$encrypted.fppx';
              final exported = await service.exportGraph(
                graph,
                path,
                description: 'Quick roundtrip',
                newFormat: true,
                encrypted: encrypted,
                password: encrypted ? 'test-password' : '',
              );
              expect(
                exported.success,
                isTrue,
                reason: '${exported.error}: ${exported.errors}',
              );
              if (encrypted) {
                expect((await service.importFile(path)).needsPassword, isTrue);
                expect(
                  (await service.importFile(path, password: 'wrong')).success,
                  isFalse,
                );
              }
              final imported = await service.importFile(
                path,
                password: encrypted ? 'test-password' : '',
              );
              expect(
                imported.success,
                isTrue,
                reason: '${imported.error}: ${imported.errors}',
              );
              expect(imported.encrypted, encrypted);
              expect(imported.graph, isNotNull);
              _expectEditableRoundtrip(preset, imported.graph!);
            },
          );
        }
      }
    },
    skip: nativeLibrary.isEmpty
        ? 'Set FFMPEGPP_TEST_LIBRARY for the native codec integration suite'
        : false,
  );
}
