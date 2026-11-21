import 'dart:async';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/services/backend_client.dart';
import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:ffmpegpp_gui/services/fppx2_service.dart';
import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:flutter_test/flutter_test.dart';

class _FppxBackend extends BackendClient {
  _FppxBackend(DiagnosticTrace trace)
    : super(NativeProcessManager(), trace: trace);

  Future<Map<String, dynamic>> Function() reply = () async => {'success': true};
  bool? lastForce;
  String? lastPassword;
  int? lastMode;
  bool legacy = false;

  @override
  Future<Map<String, dynamic>> fppxImport(
    String path, {
    bool force = false,
    String password = '',
  }) {
    lastForce = force;
    lastPassword = password;
    return reply();
  }

  @override
  Future<Map<String, dynamic>> fppx2Export(
    String path, {
    required int mode,
    required String description,
    Map<String, dynamic>? graph,
    List<dynamic>? quickItems,
    bool encrypted = false,
    String password = '',
    int encryptAlgo = 0x02,
  }) {
    lastMode = mode;
    lastPassword = password;
    return reply();
  }

  @override
  Future<Map<String, dynamic>> fppxLegacyExport(
    String path, {
    required Map<String, dynamic> graph,
    required String description,
  }) {
    legacy = true;
    return reply();
  }
}

void main() {
  late List<String> messages;
  late DiagnosticTrace trace;
  late _FppxBackend backend;
  late FppxService service;
  final graph = PipelineGraph(
    nodes: [PipelineNode(id: 'private-node-id', type: PipelineStepType.start)],
    connections: [],
  );

  setUp(() {
    messages = [];
    trace = DiagnosticTrace(messages.add)..setEnabled(true);
    backend = _FppxBackend(trace);
    service = FppxService(backend);
  });
  tearDown(() => backend.dispose());

  test('imports model semantics and safe counts from backend trace', () async {
    backend.reply = () async => {
      'success': true,
      'data': {
        'graph': graph.toJson(),
        'mode': FppxService.modeNodeEditor,
        'is_new_format': true,
        'description': 'private-description',
        'encrypted': true,
        'forced': true,
        'unknown_type_ids': ['private-type-id'],
        'warnings': ['private-warning'],
      },
    };
    final result = await service.importFile(
      'private-path',
      force: true,
      password: 'private-password',
    );
    expect(result.success, isTrue);
    expect(result.graph!.nodes.single.id, 'private-node-id');
    expect(result.description, 'private-description');
    expect(backend.lastPassword, 'private-password');
    final start = messages.singleWhere(
      (m) => m.startsWith('fppx.import.start '),
    );
    final done = messages.singleWhere(
      (m) => m.startsWith('fppx.import.result '),
    );
    expect(
      RegExp(r'opId=(\d+)').firstMatch(done)!.group(1),
      RegExp(r'opId=(\d+)').firstMatch(start)!.group(1),
    );
    for (final field in [
      'mode=1',
      'newFormat=true',
      'encrypted=true',
      'forced=true',
      'unknownCount=1',
      'nodeCount=1',
      'warningCount=1',
      'errorCount=0',
    ]) {
      expect(done, contains(field));
    }
    expect(messages.join(' '), isNot(contains('private-')));
  });

  test(
    'reports password challenge without recording password or raw errors',
    () async {
      backend.reply = () async => {
        'success': false,
        'data': {
          'need_password': true,
          'warnings': ['private-warning'],
        },
      };
      final result = await service.importFile('private-path');
      expect(result.needsPassword, isTrue);
      expect(result.error, isNull);
      expect(messages.last, contains('needPassword=true'));
      expect(messages.last, contains('failureKind=password_required'));
      expect(messages.join(' '), isNot(contains('private-')));
    },
  );

  test(
    'reports force confirmation using counts without unknown node ids',
    () async {
      backend.reply = () async => {
        'success': true,
        'data': {
          'unknown_type_ids': ['private-type-id'],
        },
      };
      final result = await service.importFile('private-path');
      expect(result.needsForceConfirm, isTrue);
      expect(messages.last, contains('unknownCount=1'));
      expect(messages.last, contains('failureKind=unknown_nodes'));
      expect(messages.join(' '), isNot(contains('private-')));
    },
  );

  test(
    'classifies graph parse validation failure and preserves return model',
    () async {
      backend.reply = () async => {
        'success': true,
        'data': {
          'graph': {'nodes': 'private-invalid-graph'},
        },
      };
      final result = await service.importFile('private-path');
      expect(result.success, isFalse);
      expect(result.error, '节点图数据解析失败');
      expect(messages, contains(contains('failureKind=graph_parse_failed')));
      expect(messages.last, contains('success=false'));
      expect(messages.join(' '), isNot(contains('private-')));
    },
  );

  test(
    'pairs graph and quick exports with fixed mode and validation counts',
    () async {
      backend.reply = () async => {
        'success': false,
        'error': 'private-backend-error',
        'data': {
          'errors': ['private-validation-error'],
          'warnings': ['private-warning'],
        },
      };
      final graphResult = await service.exportGraph(
        graph,
        'private-path',
        description: 'private-description',
        newFormat: false,
      );
      expect(backend.legacy, isTrue);
      expect(graphResult.error, 'private-backend-error');
      final quickResult = await service.exportQuickItems(
        'private-path',
        description: 'private-description',
        items: [
          {'argument': 'private-value'},
        ],
        encrypted: true,
        password: 'private-password',
      );
      expect(backend.lastMode, FppxService.modeQuick);
      expect(quickResult.errors, ['private-validation-error']);
      final graphDone = messages.singleWhere(
        (m) => m.startsWith('fppx.export_graph.result '),
      );
      final quickDone = messages.singleWhere(
        (m) => m.startsWith('fppx.export_quick.result '),
      );
      expect(graphDone, contains('mode=1'));
      expect(graphDone, contains('newFormat=false'));
      expect(graphDone, contains('nodeCount=1'));
      expect(quickDone, contains('mode=2'));
      expect(quickDone, contains('itemCount=1'));
      expect(quickDone, contains('encrypted=true'));
      expect(quickDone, contains('warningCount=1'));
      expect(quickDone, contains('errorCount=1'));
      expect(quickDone, contains('failureKind=validation_failed'));
      expect(messages.join(' '), isNot(contains('private-')));
    },
  );

  test(
    'records malformed response and thrown failures without wrapping them',
    () async {
      backend.reply = () async => {
        'success': true,
        'data': 'private-invalid-data',
      };
      await expectLater(
        service.importFile('private-path'),
        throwsA(isA<TypeError>()),
      );
      expect(messages.last, contains('failureKind=malformed_response'));
      final failure = StateError('private-transport-error');
      backend.reply = () => Future.error(failure);
      await expectLater(
        service.exportQuickItems('private-path', description: '', items: []),
        throwsA(same(failure)),
      );
      expect(messages.last, contains('failureKind=transport_failure'));
      expect(messages.join(' '), isNot(contains('private-')));
    },
  );

  test(
    'suppresses late import results across disable cycles and disposal',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      backend.reply = () => pending.future;
      final result = service.importFile('private-path');
      trace.setEnabled(false);
      trace.setEnabled(true);
      final count = messages.length;
      pending.complete({'success': true});
      expect((await result).success, isTrue);
      backend.dispose();
      backend.reply = () async => {'success': true};
      expect((await service.importFile('private-path')).success, isTrue);
      expect(messages, hasLength(count));
    },
  );

  test('disabled diagnostics retain normal result models', () async {
    trace.setEnabled(false);
    backend.reply = () async => {'success': true};
    expect((await service.importFile('private-path')).success, isTrue);
    expect(
      (await service.exportQuickItems(
        'private-path',
        description: '',
        items: [],
      )).success,
      isTrue,
    );
    expect(messages, isEmpty);
  });
}
