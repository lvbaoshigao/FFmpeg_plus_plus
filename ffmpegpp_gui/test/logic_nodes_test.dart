import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/services/graph_executor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 逻辑节点专项回归测试（对应 .workbuddy/reports/logic-nodes-audit-2026-10-02.md）。
///
/// 覆盖：
///   A1 逻辑门/使能端真正影响执行（fail-open，无门图行为不变）
///   A2 hasGateInput 与 inputCount 同源
///   B1 循环分组按逻辑块身份，而不是 loopCount
///   B2 条件块按任务源输入判定，而不是链路中途的临时产物
///   B3 末步豁免不再静默（写进 plan.warnings）
///   C4 ExecutionStep 不再有只写不读的字段

PipelineNode _node(String id, PipelineStepType t, {Map<String, dynamic>? params, String? gate}) =>
    PipelineNode(id: id, type: t, params: params ?? {}, gateType: gate);

PipelineGraph _chain({List<LogicBlock> blocks = const [], List<PipelineConnection> extra = const []}) {
  final nodes = [
    _node('S', PipelineStepType.start, params: {'file_media_type': 'video'}),
    _node('A', PipelineStepType.videoFilter),
    _node('B', PipelineStepType.videoGeometry),
    _node('O', PipelineStepType.output),
  ];
  final conns = [
    PipelineConnection(id: 'c1', fromNodeId: 'S', toNodeId: 'A'),
    PipelineConnection(id: 'c2', fromNodeId: 'A', toNodeId: 'B'),
    PipelineConnection(id: 'c3', fromNodeId: 'B', toNodeId: 'O'),
    ...extra,
  ];
  return PipelineGraph(nodes: nodes, connections: conns, logicBlocks: blocks);
}

/// 三步链 S→A→B→C→O：条件块必须落在**中间**步骤才能暴露 B2 ——
/// 落在首步时 currentInput 恰好等于源文件，旧实现也"碰巧正确"；
/// 落在末步又会被 B3 的末步豁免挡住。
PipelineGraph _chain3({List<LogicBlock> blocks = const []}) {
  final nodes = [
    _node('S', PipelineStepType.start, params: {'file_media_type': 'video'}),
    _node('A', PipelineStepType.videoFilter),
    _node('B', PipelineStepType.videoGeometry),
    _node('C', PipelineStepType.videoFilter),
    _node('O', PipelineStepType.output),
  ];
  final conns = [
    PipelineConnection(id: 'c1', fromNodeId: 'S', toNodeId: 'A'),
    PipelineConnection(id: 'c2', fromNodeId: 'A', toNodeId: 'B'),
    PipelineConnection(id: 'c3', fromNodeId: 'B', toNodeId: 'C'),
    PipelineConnection(id: 'c4', fromNodeId: 'C', toNodeId: 'O'),
  ];
  return PipelineGraph(nodes: nodes, connections: conns, logicBlocks: blocks);
}

List<BackendCall> _build(PipelineGraph g, {String input = '/tmp/in.mp4'}) {
  final plans = GraphExecutor.resolvePlans(g);
  expect(plans, isNotEmpty, reason: '应解析出至少一个执行计划');
  final calls = GraphExecutor.buildBackendCalls(plans.first, input, '/tmp/out.mp4');
  expect(calls, isNotNull, reason: '计划构建应成功，告警=${plans.first.warnings}');
  return calls!;
}

int _stepCalls(List<BackendCall> calls) =>
    calls.where((c) => c.action != '_cleanup').length;

void main() {
  group('A1 使能端（逻辑门）真正影响执行', () {
    test('无门图：两个处理步骤照常都跑（既有行为不变）', () {
      final calls = _build(_chain());
      expect(_stepCalls(calls), 2);
    });

    test('恒 1 门接到使能端：该步骤照常执行', () {
      final g = _chain(
        extra: [PipelineConnection(id: 'e1', fromNodeId: 'G', toNodeId: 'A', kind: 'control')],
      );
      g.nodes.add(_node('G', PipelineStepType.start, gate: 'const1'));
      expect(_stepCalls(_build(g)), 2);
    });

    test('恒 0 门接到使能端：该步骤被跳过（此前会照常执行）', () {
      final g = _chain(
        extra: [PipelineConnection(id: 'e1', fromNodeId: 'G', toNodeId: 'A', kind: 'control')],
      );
      g.nodes.add(_node('G', PipelineStepType.start, gate: 'const0'));
      final calls = _build(g);
      expect(_stepCalls(calls), 1, reason: 'A 被禁用，只剩 B 一步');
    });

    test('非门 + 恒 1 → 输出 0 → 该步骤被跳过（组合门也生效）', () {
      final g = _chain(
        extra: [
          PipelineConnection(id: 'g1', fromNodeId: 'K1', toNodeId: 'NT', kind: 'control'),
          PipelineConnection(id: 'g2', fromNodeId: 'NT', toNodeId: 'A', kind: 'control'),
        ],
      );
      g.nodes
        ..add(_node('K1', PipelineStepType.start, gate: 'const1'))
        ..add(_node('NT', PipelineStepType.start, gate: 'not'));
      expect(_stepCalls(_build(g)), 1);
    });

    test('未知门值（悬空输入）→ fail-open，步骤照常执行', () {
      final g = _chain(
        extra: [PipelineConnection(id: 'e1', fromNodeId: 'AND1', toNodeId: 'A', kind: 'control')],
      );
      g.nodes.add(_node('AND1', PipelineStepType.start, gate: 'and')); // 无输入 → 未知
      expect(_stepCalls(_build(g)), 2, reason: '算不出来时必须按启用处理，不能静默停掉转码');
    });

    test('最后一个处理步骤被禁用 → 构建失败并给出可读原因', () {
      final g = _chain(
        extra: [PipelineConnection(id: 'e1', fromNodeId: 'G', toNodeId: 'B', kind: 'control')],
      );
      g.nodes.add(_node('G', PipelineStepType.start, gate: 'const0'));
      final plans = GraphExecutor.resolvePlans(g);
      final calls = GraphExecutor.buildBackendCalls(plans.first, '/tmp/in.mp4', '/tmp/out.mp4');
      expect(calls, isNull);
      expect(plans.first.warnings.join('；'), contains('使能端'));
      expect(plans.first.warnings.join('；'), contains('最后一个处理步骤'));
    });
  });

  group('A2 hasGateInput 与 inputCount 同源', () {
    test('时间触发器没有输入端口', () {
      final g = _node('G', PipelineStepType.start, gate: 'timeTrigger');
      expect(g.gate, LogicGateType.timeTrigger);
      expect(g.gate!.inputCount, 0);
      expect(g.hasGateInput, isFalse, reason: '原实现用 !isConstant 判定，这里会误判为 true');
      expect(g.hasGateOutput, isTrue);
    });

    test('恒门同样没有输入端口，二输入门有', () {
      expect(_node('G', PipelineStepType.start, gate: 'const1').hasGateInput, isFalse);
      expect(_node('G', PipelineStepType.start, gate: 'and').hasGateInput, isTrue);
      expect(_node('G', PipelineStepType.start, gate: 'not').hasGateInput, isTrue);
    });
  });

  group('B1 循环分组按逻辑块身份', () {
    test('两个相邻且同次数的循环块不会被合并', () {
      final blocks = [
        LogicBlock(id: 'LA', type: LogicBlockType.loop, childNodeIds: ['A'],
            params: {'countMode': 'count', 'count': 3}),
        LogicBlock(id: 'LB', type: LogicBlockType.loop, childNodeIds: ['B'],
            params: {'countMode': 'range', 'from': 5, 'to': 9, 'step': 2}),
      ];
      final calls = _build(_chain(blocks: blocks));
      final a = calls.firstWhere((c) => c.loopCount > 1);
      final b = calls.where((c) => c.loopCount > 1).elementAt(1);
      expect(a.loopCount, 3);
      expect(b.loopCount, 3, reason: '两块次数恰好相同——这正是原实现误合并的条件');
      expect(a.blockId, 'LA');
      expect(b.blockId, 'LB');
      expect(a.blockId, isNot(b.blockId), reason: '必须能区分是两个不同的块');
      expect(b.loopIndexBase, 5, reason: '块 B 自己的区间基准不能被块 A 覆盖');
      expect(b.loopIndexStep, 2);
    });
  });

  group('B2 条件块按任务源输入判定（而不是链路中途的临时产物）', () {
    LogicBlock cond(Map<String, dynamic> params) => LogicBlock(
        id: 'LC', type: LogicBlockType.condition, childNodeIds: ['B'], params: params);

    test('parentDir：命中源文件所在目录 → 三个步骤都跑', () {
      final g = _chain3(blocks: [
        cond({'condField': 'parentDir', 'condOp': 'eq', 'condValue': 'aaa', 'condElse': 'skip'}),
      ]);
      // 源文件在 /tmp/aaa/src.mp4。旧实现拿中间步骤的输入比 —— 那是
      // <systemTemp>/ffmpegpp_work_XXXX/ffmpegpp_<hash>_src_step0.mp4，目录名是
      // 随机临时目录，永远不等于 aaa → 会错误地跳过 B（只产出 2 通调用）。
      expect(_stepCalls(_build(g, input: '/tmp/aaa/src.mp4')), 3);
    });

    test('parentDir：不命中 → 中间步骤被跳过（末步豁免不适用于它）', () {
      final g = _chain3(blocks: [
        cond({'condField': 'parentDir', 'condOp': 'eq', 'condValue': 'bbb', 'condElse': 'skip'}),
      ]);
      expect(_stepCalls(_build(g, input: '/tmp/aaa/src.mp4')), 2);
    });

    test('filename：用源文件名对得上（旧实现比的是带 hash 前后缀的临时名）', () {
      final g = _chain3(blocks: [
        cond({'condField': 'filename', 'condOp': 'eq', 'condValue': 'src.mp4', 'condElse': 'skip'}),
      ]);
      expect(_stepCalls(_build(g, input: '/tmp/aaa/src.mp4')), 3);
    });

    test('extension：仍按源文件扩展名判定', () {
      final g = _chain3(blocks: [
        cond({'condField': 'extension', 'condOp': 'eq', 'condValue': 'mp4', 'condElse': 'skip'}),
      ]);
      expect(_stepCalls(_build(g, input: '/tmp/aaa/src.mp4')), 3);
    });
  });

  group('B3 末步豁免不再静默', () {
    test('条件块覆盖最后一个处理步骤 → 写入 plan.warnings 且该步仍执行', () {
      final blocks = [
        LogicBlock(id: 'LC', type: LogicBlockType.condition, childNodeIds: ['B'],
            params: {
              'condField': 'extension',
              'condOp': 'eq',
              'condValue': 'zzz', // 永远不成立
              'condElse': 'skip',
            }),
      ];
      final g = _chain(blocks: blocks);
      final plans = GraphExecutor.resolvePlans(g);
      final calls = GraphExecutor.buildBackendCalls(plans.first, '/tmp/in.mp4', '/tmp/out.mp4')!;
      expect(_stepCalls(calls), 2, reason: '末步不跳过');
      expect(plans.first.warnings.join('；'), contains('最后一个处理步骤'));
    });
  });
}
