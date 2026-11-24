import 'dart:async';

import 'package:ffmpegpp_gui/services/backend_client.dart';
import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:flutter_test/flutter_test.dart';

class _BackendProcess extends NativeProcessManager {
  final replies = StreamController<Map<String, dynamic>>.broadcast();
  Future<Map<String, dynamic>> Function()? reply;

  @override
  Stream<Map<String, dynamic>> get responses => replies.stream;

  @override
  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic>? params,
  ]) => reply!();

  @override
  Future<Map<String, dynamic>> requestWithTimeout(
    String action,
    int timeoutSec, [
    Map<String, dynamic>? params,
  ]) => reply!();

  @override
  Future<Map<String, dynamic>> pause(List<String> taskIds) => reply!();

  @override
  Future<Map<String, dynamic>> resume(List<String> taskIds) => reply!();
}

void main() {
  late _BackendProcess process;
  late BackendClient client;
  late DiagnosticTrace trace;
  late List<String> messages;

  setUp(() {
    messages = [];
    trace = DiagnosticTrace(messages.add)..setEnabled(true);
    process = _BackendProcess();
    client = BackendClient(process, trace: trace);
  });

  tearDown(() async {
    client.dispose();
    await process.replies.close();
    process.dispose();
  });

  test('pairs backend spans and records only response counts', () async {
    process.reply = () async => {
      'success': true,
      'data': ['private-result-path'],
    };

    expect((await client.probe('private-input-path'))['success'], isTrue);

    final start = messages.singleWhere(
      (message) => message.startsWith('backend.request.start '),
    );
    final result = messages.singleWhere(
      (message) => message.startsWith('backend.request.result '),
    );
    expect(start, contains('action=probe'));
    expect(start, contains('requestFields=1'));
    expect(result, contains('responseFields=2'));
    expect(result, contains('itemCount=1'));
    expect(result, contains('success=true'));
    expect(
      RegExp(r'opId=(\d+)').firstMatch(start)!.group(1),
      RegExp(r'opId=(\d+)').firstMatch(result)!.group(1),
    );
    expect(messages.join(' '), isNot(contains('private-')));
  });

  test(
    'classifies malformed replies and pause resume failures safely',
    () async {
      process.reply = () async => {'success': 'private-invalid-value'};
      await client.checkEnv();
      process.reply = () async => {
        'success': false,
        'error': 'private-raw-error',
      };
      await client.pause('private-task-id');
      await client.resume('private-task-id');

      final results = messages
          .where((message) => message.startsWith('backend.request.result '))
          .toList();
      expect(results, hasLength(3));
      expect(results.first, contains('failureKind=malformed_response'));
      expect(results[1], contains('action=pause'));
      expect(results[2], contains('action=resume'));
      expect(results[1], contains('failureKind=backend_rejected'));
      expect(messages.join(' '), isNot(contains('private-')));
    },
  );

  test('pairs thrown transport failures without raw errors', () async {
    process.reply = () => Future.error(TimeoutException('private-secret'));

    await expectLater(client.checkEnv(), throwsA(isA<TimeoutException>()));

    expect(messages.last, contains('failureKind=timeout'));
    expect(messages.last, contains('success=false'));
    expect(messages.join(' '), isNot(contains('private-')));
  });

  test('does not emit late or new results after disposal', () async {
    final pending = Completer<Map<String, dynamic>>();
    process.reply = () => pending.future;
    final request = client.checkEnv();
    client.dispose();
    final count = messages.length;
    pending.complete({'success': true});
    expect((await request)['success'], isTrue);
    process.reply = () async => {'success': true};
    await client.checkEnv();
    expect(messages, hasLength(count));
  });

  test('does not revive a request across diagnostic enable cycles', () async {
    final pending = Completer<Map<String, dynamic>>();
    process.reply = () => pending.future;
    final request = client.checkEnv();
    trace.setEnabled(false);
    trace.setEnabled(true);
    final count = messages.length;
    pending.complete({'success': true});
    await request;
    expect(messages, hasLength(count));
  });

  test('disabled diagnostics preserve the backend result', () async {
    trace.setEnabled(false);
    final response = {'success': false, 'error': 'private-error'};
    process.reply = () async => response;
    expect(await client.checkEnv(), same(response));
    expect(messages, isEmpty);
  });
}
