// FPPX 节点图在 Dart 模型层的往返测试，包括强制导入的未知节点。
// C++ 端的格式编解码测试在 server_cpp/tests/fppx_test.cpp。
import 'dart:convert';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('未知节点 toJson/fromJson 保留 type_id', () {
    final node = PipelineNode(
      id: 'u1', type: PipelineStepType.unknown, unknownTypeId: 19243,
      params: {'x': 1}, x: 12, y: 34,
    );
    final json = node.toJson();
    expect(json['type'], 'unknown');
    expect(json['type_id'], 19243);

    final back = PipelineNode.fromJson(json);
    expect(back.type, PipelineStepType.unknown);
    expect(back.unknownTypeId, 19243);
    expect(back.label, contains('19243'));
  });

  test('普通节点不携带 type_id', () {
    final node = PipelineNode(id: 'a', type: PipelineStepType.avProcess);
    expect(node.toJson().containsKey('type_id'), isFalse);
  });

  test('未知节点的图无法通过执行校验（错误信息含类型 ID）', () {
    final graph = PipelineGraph(nodes: [
      PipelineNode(id: 's', type: PipelineStepType.start, params: {'file_media_type': 'video'}),
      PipelineNode(id: 'u', type: PipelineStepType.unknown, unknownTypeId: 19243),
      PipelineNode(id: 'o', type: PipelineStepType.output),
    ], connections: [
      PipelineConnection(id: 'c1', fromNodeId: 's', toNodeId: 'u'),
      PipelineConnection(id: 'c2', fromNodeId: 'u', toNodeId: 'o'),
    ]);
    final errors = GraphExecutor.validateGraph(graph);
    expect(errors, isNotEmpty);
    expect(errors.join('\n'), contains('19243'));
  });

  group('FPPX 新媒体节点', () {
    const paramsByType = {
      PipelineStepType.audioSpectrum: {
        'width': 1080,
        'height': 640,
        'output_format': 'webp',
      },
      PipelineStepType.audioWaveform: {
        'width': 640,
        'height': 360,
        'output_format': 'jpg',
      },
      PipelineStepType.audioReverse: {'node_name': 'Reverse audio'},
      PipelineStepType.videoReverse: {'node_name': 'Reverse video'},
      PipelineStepType.audioEqualizer: {
        'bass_db': -3.5,
        'mid_db': 0,
        'treble_db': 5,
      },
      PipelineStepType.videoFade: {
        'fade_in': 1.5,
        'fade_out': 3,
        'fade_out_start': 7.5,
      },
    };
    for (final MapEntry(key: type, value: params) in paramsByType.entries) {
      test('往返保留 ${type.name} 的类型和参数', () {
        final node = PipelineNode(id: 'new', type: type, params: Map.of(params));
        final graph = PipelineGraph(nodes: [node], connections: []);
        final payload = jsonDecode(jsonEncode(graph.toJson()))
            as Map<String, dynamic>;
        final back = PipelineGraph.fromJson(payload).nodes.single;
        expect(back.type, type);
        expect(back.unknownTypeId, isNull);
        expect(back.params, params);
      });
    }
  });

  test('旧版 fromJson 兜底：未知类型名映射为 unknown 而非 start', () {
    final back = PipelineNode.fromJson({'id': 'x', 'type': 'brandNewNode'});
    expect(back.type, PipelineStepType.unknown);
  });
}
