// 新版 FPPX 未知节点（强制导入）在 Dart 模型层的往返测试。
// C++ 端的格式编解码测试在 server_cpp/tests/fppx_test.cpp。
import 'package:flutter_test/flutter_test.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';

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

  test('旧版 fromJson 兜底：未知类型名映射为 unknown 而非 start', () {
    final back = PipelineNode.fromJson({'id': 'x', 'type': 'brandNewNode'});
    expect(back.type, PipelineStepType.unknown);
  });
}
