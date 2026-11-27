import 'dart:io';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manifest.dart';
import 'package:ffmpegpp_gui/plugins/plugin_node_catalog.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:flutter_test/flutter_test.dart';

PluginManifest _manifest(String input, String output) =>
    PluginManifest.fromJson({
      'format_version': 1,
      'api_version': 1,
      'id': 'org.ffmpegpp.conversion',
      'app_version': '>=6.0.0-beta2 <7.0.0',
      'module': 'plugin.wasm',
      'Basic_info': {
        'Name': 'Media conversion',
        'Version': '1.0.0',
        'IsPreview': false,
        'Summary': 'A conversion supplied by the plugin.',
      },
      'Node_info': [
        {
          'id': 'convert',
          'name': 'Convert',
          'fun': 'Convert media',
          'IsLogic': false,
          'IO': {'inputs': 1, 'outputs': 1},
          'input_types': [input],
          'output_type': output,
          'fields': [],
        },
      ],
    });

PipelineGraph _graph(
  PluginManifest manifest, {
  PipelineNode? after,
  String format = 'keep',
}) {
  final start = PipelineNode(
    id: 'start',
    type: PipelineStepType.start,
    params: {'file_media_type': manifest.nodes.single.inputTypes.single},
  );
  final plugin = PipelineNode(
    id: 'plugin',
    type: PipelineStepType.plugin,
    params: PipelineNode.pluginParams(
      pluginId: manifest.id,
      pluginVersion: manifest.version,
      definition: manifest.nodes.single,
    ),
  );
  final output = PipelineNode(
    id: 'output',
    type: PipelineStepType.output,
    params: {'format': format},
  );
  return PipelineGraph(
    nodes: [start, plugin, if (after != null) after, output],
    connections: [
      PipelineConnection(id: 'a', fromNodeId: start.id, toNodeId: plugin.id),
      PipelineConnection(
        id: 'b',
        fromNodeId: plugin.id,
        toNodeId: after?.id ?? output.id,
      ),
      if (after != null)
        PipelineConnection(id: 'c', fromNodeId: after.id, toNodeId: output.id),
    ],
  );
}

ExecutionPlan _plan(
  PluginManifest manifest, {
  PipelineNode? after,
  String format = 'keep',
}) {
  PluginNodeCatalog.instance.replaceAll([manifest]);
  final graph = _graph(manifest, after: after, format: format);
  expect(GraphExecutor.validateGraph(graph), isEmpty);
  return GraphExecutor.resolvePlans(graph).single;
}

String _resolve(ExecutionPlan plan, String filename, MediaType input) =>
    GraphExecutor.resolveOutputPath(
      plan,
      VideoFile(
        id: 'source',
        filepath: '/tmp/$filename',
        filename: filename,
        fileMediaType: input,
      ),
      AppConfig(defaultOutputDir: '/tmp/plugin-output'),
    );

void main() {
  setUp(() => PluginNodeCatalog.instance.clear());
  tearDown(() => PluginNodeCatalog.instance.clear());

  for (final conversion in [
    ('video', 'audio', 'movie.mp4', 'wav'),
    ('audio', 'image', 'song.flac', 'png'),
    ('image', 'video', 'still.jpg', 'mkv'),
  ]) {
    test(
      'plugin ${conversion.$1} to ${conversion.$2} resolves a matching container',
      () {
        final manifest = _manifest(conversion.$1, conversion.$2);
        final plan = _plan(manifest);
        final output = _resolve(
          plan,
          conversion.$3,
          MediaType.values.byName(conversion.$1),
        );
        expect(output, endsWith('.${conversion.$4}'));
        final call = GraphExecutor.buildBackendCalls(
          plan,
          '/tmp/${conversion.$3}',
          output,
        )!.firstWhere((call) => call.action == '_plugin');
        expect(call.params['media_type'], conversion.$1);
        expect(call.params['input_media_type'], conversion.$1);
        expect(call.params['output_media_type'], conversion.$2);
        expect(call.params['output'], output);
        expect(BackendCall.fromJson(call.toJson()).params, call.params);
      },
    );
  }

  test(
    'converted temporary output is passed to the next media processor and cleaned',
    () {
      final manifest = _manifest('audio', 'image');
      final plan = _plan(
        manifest,
        after: PipelineNode(
          id: 'resize',
          type: PipelineStepType.imageScale,
          params: {'width': 320, 'height': 180},
        ),
      );
      final calls = GraphExecutor.buildBackendCalls(
        plan,
        '/tmp/source.wav',
        '/tmp/final.png',
      )!;
      final pluginCall = calls.firstWhere((call) => call.action == '_plugin');
      final next = calls
          .where((call) => call.action != '_cleanup')
          .elementAt(1);
      expect(pluginCall.params['output'], endsWith('.png'));
      expect(next.params['input'], pluginCall.params['output']);
      expect(
        calls
            .where((call) => call.action == '_cleanup')
            .map((call) => call.params['path']),
        contains(pluginCall.params['output']),
      );
    },
  );

  test(
    'same-media plugins retain the source extension and explicit output choice',
    () {
      final manifest = _manifest('audio', 'audio');
      final plan = _plan(manifest);
      expect(_resolve(plan, 'song.flac', MediaType.audio), endsWith('.flac'));
      final explicit = _plan(manifest, format: 'mp3');
      expect(
        _resolve(explicit, 'song.flac', MediaType.audio),
        endsWith('.mp3'),
      );
    },
  );

  test('plugin image conversion ignores retained video output format', () {
    final manifest = _manifest('audio', 'image');
    final plan = _plan(manifest, format: 'mp4');
    expect(_resolve(plan, 'song.wav', MediaType.audio), endsWith('.png'));
  });

  test(
    'plugin image conversion replaces custom extension and preserves existing files',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'plugin_conversion_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final manifest = _manifest('audio', 'image');
      final plan = _plan(manifest);
      plan.outputNode!.params.addAll({
        'naming_mode': 'custom',
        'naming_value': 'cover.jpg',
        'output_dir': directory.path,
      });
      final existing = File('${directory.path}/cover.png')
        ..writeAsStringSync('keep');
      final output = _resolve(plan, 'song.wav', MediaType.audio);
      expect(output, '${directory.path}/cover_2.png');
      expect(existing.readAsStringSync(), 'keep');
    },
  );

  test('later explicit image conversion wins after plugin conversion', () {
    final manifest = _manifest('audio', 'image');
    final plan = _plan(
      manifest,
      after: PipelineNode(
        id: 'format',
        type: PipelineStepType.imageConvert,
        params: {'output_format': 'webp'},
      ),
    );
    expect(_resolve(plan, 'song.wav', MediaType.audio), endsWith('.webp'));
  });
}
