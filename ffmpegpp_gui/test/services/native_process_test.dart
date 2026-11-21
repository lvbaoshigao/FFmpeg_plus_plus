import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:ffmpegpp_gui/services/native_bridge.dart';
import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBridge implements NativeBridge {
  int requestResult = -1;
  int pollCount = 0;
  bool autoReply = true;
  Object? requestError;
  final replies = <String>[];

  @override
  int init() => 0;

  @override
  int request(String encoded) {
    final request = jsonDecode(encoded) as Map<String, dynamic>;
    if (requestError != null) throw requestError!;
    if (requestResult == 0 && autoReply) {
      replies.add(jsonEncode({'id': request['id'], 'success': true}));
    }
    return requestResult;
  }

  @override
  String? poll() {
    pollCount++;
    return replies.isEmpty ? null : replies.removeAt(0);
  }

  @override
  void shutdown() {}
}

void main() {
  group('NativeProcessManager', () {
    late NativeProcessManager process;

    setUp(() => process = NativeProcessManager());
    tearDown(() => process.dispose());

    test('should report a missing backend without waiting for ready', () async {
      await expectLater(
        process.start('/missing/ffmpegpp/libffmpegpp.so'),
        throwsArgumentError,
      );
      expect(process.isRunning, isFalse);
      final ready = await process.waitForReady().timeout(
        const Duration(seconds: 1),
      );
      expect(ready['type'], 'error');
      expect(ready['error'], contains('libffmpegpp.so'));
    });

    group('synchronous native rejection', () {
      late _FakeBridge bridge;

      setUp(() async {
        process.dispose();
        bridge = _FakeBridge();
        process = NativeProcessManager.withBridgeFactory((_) => bridge);
        await process.start('isolated-fake-bridge');
      });

      test('should fail an unbounded request and release its ID', () async {
        final rejected = await process
            .requestWithId('job', 'transcode')
            .timeout(const Duration(seconds: 1));
        expect(rejected['id'], 'job');
        expect(rejected['success'], isFalse);
        expect(rejected['error'], contains('code=-1'));

        bridge.requestResult = 0;
        final accepted = await process
            .requestWithId('job', 'transcode')
            .timeout(const Duration(seconds: 1));
        expect(accepted['success'], isTrue);
      });

      test('should fail a timed request before its response timeout', () async {
        bridge.requestResult = 7;
        final rejected = await process
            .requestWithTimeout('probe', 120)
            .timeout(const Duration(seconds: 1));
        expect(rejected['success'], isFalse);
        expect(rejected['error'], contains('code=7'));

        // Reuse the generated ID to prove rejection removed the pending entry.
        bridge.requestResult = 0;
        final accepted = await process
            .requestWithId(rejected['id'] as String, 'probe')
            .timeout(const Duration(seconds: 1));
        expect(accepted['success'], isTrue);
      });

      test('should report a rejected cancellation without throwing', () async {
        final error = process.errors.first.timeout(const Duration(seconds: 1));

        expect(() => process.cancel(['private-task-id']), returnsNormally);

        expect(await error, '取消请求被拒绝或发送失败');
      });

      test('should accept cancellation without an error event', () async {
        bridge.requestResult = 0;
        final errors = process.errors.toList();

        expect(() => process.cancel(['job']), returnsNormally);
        expect(bridge.replies, hasLength(1));

        process.dispose();
        expect(await errors, isEmpty);
      });

      test(
        'should also reject the default-timeout request immediately',
        () async {
          final rejected = await process
              .request('ping')
              .timeout(const Duration(seconds: 1));
          expect(rejected['success'], isFalse);
          expect(rejected['error'], contains('code=-1'));
        },
      );
    });

    testWidgets('should back off idle polls and wake for a request', (
      tester,
    ) async {
      final bridge = _FakeBridge()..requestResult = 0;
      process.dispose();
      process = NativeProcessManager.withBridgeFactory((_) => bridge);
      await process.start('isolated-fake-bridge');
      try {
        bridge.replies.add(jsonEncode({'type': 'ready'}));
        Map<String, dynamic>? ready;
        unawaited(process.waitForReady().then((reply) => ready = reply));
        await tester.pump(const Duration(milliseconds: 16));
        expect(ready?['type'], 'ready');

        final firstIdlePoll = bridge.pollCount;
        await tester.pump(const Duration(seconds: 2));
        expect(bridge.pollCount - firstIdlePoll, inInclusiveRange(1, 16));

        Map<String, dynamic>? reply;
        unawaited(process.request('ping').then((value) => reply = value));
        await tester.pump(const Duration(milliseconds: 16));
        expect(reply?['success'], isTrue);
      } finally {
        await process.shutdown();
      }
      final stopped = bridge.pollCount;
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.pollCount, stopped);
    });

    testWidgets('should trace real FFI work without payloads or idle polls', (
      tester,
    ) async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final bridge = _FakeBridge()..requestResult = 0;
      process.dispose();
      process = NativeProcessManager.withBridgeFactory(
        (_) => bridge,
        trace: trace,
      );
      await process.start('private-library-path');
      try {
        bridge.replies.add(jsonEncode({'type': 'ready'}));
        final reply = process.request('probe', {'input': 'private-input-path'});
        await tester.pump(const Duration(milliseconds: 16));
        expect((await reply)['success'], isTrue);
        await tester.pump(const Duration(milliseconds: 400));
        expect(messages, contains(startsWith('ffi.library.load')));
        expect(messages, contains(startsWith('ffi.init')));
        expect(messages, contains(startsWith('ffi.send')));
        expect(
          messages.where((message) => message.startsWith('ffi.responses')),
          hasLength(1),
        );
        expect(messages.join(' '), contains('itemCount=2'));
        expect(messages.join(' '), isNot(contains('private-')));

        final last = messages.length;
        await tester.pump(const Duration(seconds: 1));
        expect(messages, hasLength(last));
        trace.setEnabled(false);
        final silent = process.request('ping');
        await tester.pump(const Duration(milliseconds: 16));
        expect((await silent)['success'], isTrue);
        await tester.pump(const Duration(milliseconds: 400));
        expect(messages, hasLength(last));
      } finally {
        await process.shutdown();
      }
    });

    test(
      'should resolve pending readiness and requests when shut down',
      () async {
        final bridge = _FakeBridge()..requestResult = 0;
        process.dispose();
        process = NativeProcessManager.withBridgeFactory((_) => bridge);
        await process.start('isolated-fake-bridge');
        final ready = process.waitForReady();
        final reply = process.requestWithId('job', 'transcode');
        await process.shutdown();
        expect(
          (await ready.timeout(const Duration(seconds: 1)))['type'],
          'error',
        );
        expect(
          (await reply.timeout(const Duration(seconds: 1)))['success'],
          isFalse,
        );
      },
    );

    testWidgets('pairs native request timeout spans without payloads', (tester) async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final bridge = _FakeBridge()..requestResult = 0..autoReply = false;
      process.dispose();
      process = NativeProcessManager.withBridgeFactory((_) => bridge, trace: trace);
      await process.start('private-library');
      final reply = process.requestWithTimeout('probe', 1, {'input': 'private-path'});
      await tester.pump(const Duration(seconds: 1));
      expect((await reply)['success'], isFalse);
      final result = messages.singleWhere((m) => m.startsWith('ffi.request.result '));
      expect(result, contains('failureKind=timeout'));
      expect(result, contains('timeoutMs=1000'));
      expect(messages, contains(startsWith('ffi.reply.timeout ')));
      expect(messages.join(' '), isNot(contains('private-')));
      await process.shutdown();
    });

    testWidgets('classifies malformed native responses and releases requests', (tester) async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final bridge = _FakeBridge()..requestResult = 0..autoReply = false;
      process.dispose();
      process = NativeProcessManager.withBridgeFactory((_) => bridge, trace: trace);
      await process.start('private-library');
      final reply = process.requestWithId('private-task', 'transcode');
      bridge.replies.add('{"id":"private-task","success":');
      await tester.pump(const Duration(milliseconds: 16));
      expect((await reply)['success'], isFalse);
      expect(messages, contains(allOf(startsWith('ffi.request.result '), contains('failureKind=malformed_response'))));
      expect(messages, contains(allOf(startsWith('ffi.response.decode_failed '), contains('pendingCount=1'))));
      expect(messages.join(' '), isNot(contains('private-')));
      await process.shutdown();
    });

    test('classifies native transport and cancellation rejection', () async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final bridge = _FakeBridge();
      process.dispose();
      process = NativeProcessManager.withBridgeFactory((_) => bridge, trace: trace);
      await process.start('private-library');
      expect((await process.request('private-action'))['success'], isFalse);
      bridge.requestError = StateError('private-send-error');
      expect((await process.request('ping'))['success'], isFalse);
      process.cancel(['private-task']);
      expect(messages, contains(allOf(startsWith('ffi.send.result '), contains('exitCode=-1'))));
      expect(messages, contains(contains('failureKind=native_rejected')));
      expect(messages, contains(contains('failureKind=transport_failure')));
      expect(messages, contains(allOf(startsWith('ffi.cancel.result '), contains('success=false'))));
      expect(messages.join(' '), isNot(contains('private-')));
    });

    testWidgets('does not revive a received batch across enable cycles', (tester) async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final bridge = _FakeBridge()..requestResult = 0;
      process.dispose();
      process = NativeProcessManager.withBridgeFactory((_) => bridge, trace: trace);
      await process.start('private-library');
      final reply = process.request('ping');
      await tester.pump(const Duration(milliseconds: 16));
      await reply;
      trace.setEnabled(false);
      trace.setEnabled(true);
      final count = messages.length;
      await tester.pump(const Duration(milliseconds: 400));
      expect(messages, hasLength(count));
      await process.shutdown();
    });

    test('does not emit shutdown or late request results after disposal', () async {
      final messages = <String>[];
      final trace = DiagnosticTrace(messages.add)..setEnabled(true);
      final bridge = _FakeBridge()..requestResult = 0..autoReply = false;
      process.dispose();
      process = NativeProcessManager.withBridgeFactory((_) => bridge, trace: trace);
      await process.start('private-library');
      final reply = process.requestWithId('private-task', 'transcode');
      final count = messages.length;
      process.dispose();
      expect((await reply)['success'], isFalse);
      await process.shutdown();
      await process.request('ping');
      expect(messages, hasLength(count));
    });

    final library = Platform.environment['FFMPEGPP_TEST_LIBRARY'];
    test(
      'should start the bundled backend, check the environment and restart',
      () async {
        for (var attempt = 0; attempt < 2; attempt++) {
          await process.start(library!);
          final ready = await process.waitForReady(
            timeout: const Duration(seconds: 5),
          );
          expect(ready['type'], 'ready');
          await process.start(library);
          expect((await process.waitForReady())['type'], 'ready');
          final environment = await process.requestWithTimeout('check_env', 10);
          expect(environment['success'], isTrue);
          expect(environment['data']['all_ok'], isTrue);
          await process.shutdown();
          expect(process.isRunning, isFalse);
        }
      },
      skip: library == null
          ? 'Set FFMPEGPP_TEST_LIBRARY to the built library.'
          : false,
    );
  });
}
