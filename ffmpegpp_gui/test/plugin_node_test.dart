import 'dart:convert';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manifest.dart';
import 'package:ffmpegpp_gui/plugins/plugin_node_catalog.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:flutter_test/flutter_test.dart';

PluginManifest fixture({bool logic = true, String version = '1.0.0'}) =>
    PluginManifest.fromJson({
      'format_version': 1,
      'api_version': 1,
      'id': 'org.ffmpegpp.volume',
      'app_version': '>=6.0.0-beta2 <7.0.0',
      'module': 'plugin.wasm',
      'Basic_info': {
        'Name': 'Volume',
        'Version': version,
        'IsPreview': false,
        'Summary': 'Volume node',
      },
      'Node_info': [
        {
          'id': 'volume',
          'name': '音量插件',
          'fun': 'Adjust audio volume',
          'IsLogic': logic,
          'IO': {'inputs': 1, 'outputs': 1},
          'input_types': ['audio'],
          'output_type': 'audio',
          'schema_version': 1,
          'fields': [
            {
              'key': 'gain',
              'label': 'Gain',
              'type': 'number',
              'default': -3,
              'min': -60,
              'max': 12,
            },
          ],
        },
      ],
    });

PipelineNode pluginNode(PluginManifest manifest) => PipelineNode(
  id: 'p',
  type: PipelineStepType.plugin,
  x: 40,
  y: 50,
  params: PipelineNode.pluginParams(
    pluginId: manifest.id,
    pluginVersion: manifest.version,
    definition: manifest.nodes.single,
  ),
);
PipelineGraph graphFor(PipelineNode node, {bool control = false}) =>
    PipelineGraph(
      nodes: [
        PipelineNode(
          id: 's',
          type: PipelineStepType.start,
          params: {'file_media_type': 'audio'},
        ),
        node,
        PipelineNode(id: 'o', type: PipelineStepType.output),
        if (control)
          PipelineNode(
            id: 'g',
            type: PipelineStepType.start,
            gateType: 'const1',
          ),
      ],
      connections: [
        PipelineConnection(id: 'a', fromNodeId: 's', toNodeId: node.id),
        PipelineConnection(id: 'b', fromNodeId: node.id, toNodeId: 'o'),
        if (control)
          PipelineConnection(
            id: 'c',
            fromNodeId: 'g',
            toNodeId: node.id,
            kind: 'control',
          ),
      ],
    );

void main() {
  setUp(() => PluginNodeCatalog.instance.clear());
  tearDown(() => PluginNodeCatalog.instance.clear());
  test(
    'opt in defaults off and round trips without coercing malformed values',
    () {
      expect(AppConfig().pluginsEnabled, isFalse);
      expect(AppConfig.fromJson({}).pluginsEnabled, isFalse);
      expect(
        AppConfig.fromJson({'plugins_enabled': 'true'}).pluginsEnabled,
        isFalse,
      );
      expect(
        AppConfig.fromJson(
          AppConfig(pluginsEnabled: true).toJson(),
        ).pluginsEnabled,
        isTrue,
      );
    },
  );
  test('fixed carrier is appended without moving old enum indices', () {
    expect(PipelineStepType.videoFade.index, 52);
    expect(PipelineStepType.plugin.index, 53);
    expect(PipelineStepType.unknown.index, 46);
  });
  test(
    'JSON copy and graph round trips preserve missing plugin envelope and links',
    () {
      final node = pluginNode(fixture());
      final graph = graphFor(node);
      final payload = jsonEncode(graph.toJson());
      final back = PipelineGraph.fromJson(
        jsonDecode(payload) as Map<String, dynamic>,
      );
      expect(jsonEncode(back.toJson()), payload);
      expect(node.copy().params, node.params);
      final deep = node.deepCopy();
      (deep.params['values'] as Map)['gain'] = -9;
      expect((node.params['values'] as Map)['gain'], -3);
      expect(graph.copy().nodes[1].params, node.params);
      expect(node.pluginDefinition, isNull);
      expect(node.label, '音量插件');
      expect(node.inputTypes, {MediaType.audio});
      expect(node.outputType, MediaType.audio);
      expect(
        GraphExecutor.validateGraph(graph).join(),
        contains(node.pluginId),
      );
    },
  );
  test(
    'live enabled declaration builds deferred _plugin action with validated values',
    () {
      final manifest = fixture();
      PluginNodeCatalog.instance.replaceAll([manifest]);
      final graph = graphFor(pluginNode(manifest));
      expect(GraphExecutor.validateGraph(graph), isEmpty);
      final plan = GraphExecutor.resolvePlans(graph).single;
      final calls = GraphExecutor.buildBackendCalls(
        plan,
        '/tmp/in.wav',
        '/tmp/out.wav',
      )!;
      final call = calls.firstWhere((call) => call.action == '_plugin');
      expect(call.params['input'], '/tmp/in.wav');
      expect(call.params['output'], '/tmp/out.wav');
      expect(call.params['media_type'], 'audio');
      expect(call.params['values'], {'gain': -3});
      expect((call.params['plugin'] as Map)['id'], manifest.id);
      final persisted = BackendCall.fromJson(call.toJson());
      expect(persisted.params, call.params);
    },
  );
  test(
    'disabling catalog after plan creation fails build and keeps node data',
    () {
      final manifest = fixture();
      PluginNodeCatalog.instance.replaceAll([manifest]);
      final node = pluginNode(manifest);
      final graph = graphFor(node);
      final plan = GraphExecutor.resolvePlans(graph).single;
      final before = jsonEncode(graph.toJson());
      PluginNodeCatalog.instance.clear();
      expect(
        GraphExecutor.buildBackendCalls(plan, '/tmp/in.wav', '/tmp/out.wav'),
        isNull,
      );
      expect(jsonEncode(graph.toJson()), before);
    },
  );
  test(
    'snapshot never authorizes undeclared nodes or invalid parameter keys',
    () {
      final manifest = fixture();
      PluginNodeCatalog.instance.replaceAll([manifest]);
      final node = pluginNode(manifest);
      (node.params['values'] as Map)['gain'] = 1000;
      expect(node.pluginUnavailableReason, isNotNull);
      (node.params['values'] as Map)
        ..clear()
        ..['shell'] = 'anything';
      expect(node.pluginUnavailableReason, isNotNull);
      (node.params['_plugin'] as Map)['node'] = 'undeclared';
      expect(node.pluginDefinition, isNull);
      expect(node.pluginUnavailableReason, isNotNull);
    },
  );
  test('version or schema mismatch remains preserved but cannot execute', () {
    final manifest = fixture();
    PluginNodeCatalog.instance.replaceAll([fixture(version: "2.0.0")]);
    final node = pluginNode(manifest);
    expect(node.pluginUnavailableReason, isNotNull);
    expect(node.pluginEnvelope['version'], '1.0.0');
    PluginNodeCatalog.instance.replaceAll([manifest]);
    (node.params['_plugin'] as Map)['schema_version'] = 2;
    expect(node.pluginUnavailableReason, isNotNull);
  });
  test('IsLogic gates both control directions and graph validation', () {
    final disabled = fixture(logic: false);
    PluginNodeCatalog.instance.replaceAll([disabled]);
    final node = pluginNode(disabled);
    expect(node.isGate, isFalse);
    expect(node.hasControlInput, isFalse);
    expect(node.hasControlOutput, isFalse);
    expect(
      GraphExecutor.validateGraph(graphFor(node, control: true)),
      isNotEmpty,
    );
    final enabled = fixture(logic: true);
    PluginNodeCatalog.instance.replaceAll([enabled]);
    final allowed = pluginNode(enabled);
    expect(allowed.hasControlInput, isTrue);
    expect(allowed.hasControlOutput, isTrue);
    expect(
      GraphExecutor.validateGraph(graphFor(allowed, control: true)),
      isEmpty,
    );
  });
}
