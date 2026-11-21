import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:ffmpegpp_gui/services/task_process_runner.dart';
import 'package:flutter_test/flutter_test.dart';

class _TraceProcess implements Process {
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();
  final exited = Completer<int>();
  final signals = <ProcessSignal>[];
  bool signalResult = true;
  bool signalThrows = false;

  Future<void> finish([int code = 0]) async {
    if (!exited.isCompleted) exited.complete(code);
    await Future.wait([out.close(), err.close()]);
  }

  @override
  int get pid => 42;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  IOSink get stdin => throw UnsupportedError('No fake stdin');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (signalThrows) throw StateError('private-signal-error');
    return signalResult;
  }
}

void main() {
  late List<String> messages;
  late DiagnosticTrace trace;
  setUp(() {
    messages = [];
    trace = DiagnosticTrace(messages.add)..setEnabled(true);
  });

  test(
    'pairs overlapping processes by operation id and records exit counts',
    () async {
      final processes = [_TraceProcess(), _TraceProcess()];
      var index = 0;
      final runner = TaskProcessRunner(
        trace: trace,
        starter: (_, arguments) async => processes[index++],
      );
      final first = runner.createRun().run('private-program', [
        'private-secret',
      ]);
      final second = runner.createRun().run('private-program', []);
      await Future<void>.delayed(Duration.zero);
      processes[0].out.add(utf8.encode('private-stdout'));
      processes[0].err.add(utf8.encode('private-stderr'));
      await processes[1].finish(7);
      await processes[0].finish();
      expect((await first).exitCode, 0);
      expect((await second).exitCode, 7);

      final starts = messages.where(
        (m) => m.startsWith('ffmpeg.process.start '),
      );
      final results = messages.where(
        (m) => m.startsWith('ffmpeg.process.result '),
      );
      expect(starts, hasLength(2));
      expect(results, hasLength(2));
      final ids = starts
          .map((m) => RegExp(r'opId=(\d+)').firstMatch(m)!.group(1))
          .toSet();
      expect(ids, hasLength(2));
      expect(
        results
            .map((m) => RegExp(r'opId=(\d+)').firstMatch(m)!.group(1))
            .toSet(),
        ids,
      );
      expect(
        results,
        contains(
          allOf(contains('exitCode=7'), contains('failureKind=exit_nonzero')),
        ),
      );
      expect(
        results,
        contains(allOf(contains('stdoutChars=14'), contains('stderrChars=14'))),
      );
      expect(messages.join(' '), isNot(contains('private-')));
    },
  );

  test('records startup failures and keeps original exceptions', () async {
    final failure = StateError('private-start-error');
    final run = TaskProcessRunner(
      trace: trace,
      starter: (_, arguments) async => throw failure,
    ).createRun();
    await expectLater(run.run('private-path', []), throwsA(same(failure)));
    expect(messages.last, contains('failureKind=start_failed'));
    expect(messages.last, contains('success=false'));
    expect(run.isActive, isFalse);
    expect(messages.join(' '), isNot(contains('private-')));
  });

  test(
    'records pause resume signal rejection and terminal cancellation',
    () async {
      final process = _TraceProcess();
      final run = TaskProcessRunner(
        trace: trace,
        windows: false,
        starter: (_, arguments) async => process,
      ).createRun();
      final result = run.run('private-path', []);
      final cancelled = expectLater(
        result,
        throwsA(isA<TaskProcessCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(run.pause(), isTrue);
      process.signalResult = false;
      expect(run.resume(), isFalse);
      process.signalThrows = true;
      run.cancel();
      await process.finish(-9);
      await cancelled;

      expect(
        messages,
        contains(
          allOf(
            startsWith('ffmpeg.process.pause '),
            contains('signalSuccess=true'),
          ),
        ),
      );
      expect(
        messages,
        contains(
          allOf(
            startsWith('ffmpeg.process.resume '),
            contains('signalSuccess=false'),
          ),
        ),
      );
      expect(messages, contains(contains('failureKind=signal_rejected')));
      expect(messages, contains(contains('failureKind=signal_exception')));
      expect(messages.last, contains('cancelled=true'));
      expect(messages.last, contains('exitCode=-9'));
      expect(messages.join(' '), isNot(contains('private-')));
    },
  );

  for (final kind in [
    'stdout_read_failed',
    'stderr_read_failed',
    'exit_failed',
    'callback_failed',
    'stdout_overflow',
  ]) {
    test('classifies $kind without swallowing process failures', () async {
      final process = _TraceProcess();
      final failure = StateError('private-read-error');
      final run = TaskProcessRunner(
        trace: trace,
        captureLimit: kind == 'stdout_overflow' ? 2 : 1024,
        starter: (_, arguments) async => process,
      ).createRun();
      final result = run.run(
        'private-path',
        [],
        onStderr: (_) {
          if (kind == 'callback_failed') throw failure;
        },
      );
      final rejected = expectLater(result, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      if (kind == 'stdout_read_failed') process.out.addError(failure);
      if (kind == 'stderr_read_failed') process.err.addError(failure);
      if (kind == 'exit_failed') process.exited.completeError(failure);
      if (kind == 'callback_failed') {
        process.err.add(utf8.encode('private-stderr'));
      }
      if (kind == 'stdout_overflow') {
        process.out.add(utf8.encode('private-stdout'));
      }
      await process.finish();
      await rejected;
      expect(messages.last, contains('failureKind=$kind'));
      expect(messages.last, contains('failureCount=1'));
      expect(messages.join(' '), isNot(contains('private-')));
    });
  }

  test(
    'does not emit results or control events after trace disable cycles',
    () async {
      final process = _TraceProcess();
      final run = TaskProcessRunner(
        trace: trace,
        windows: false,
        starter: (_, arguments) async => process,
      ).createRun();
      final result = run.run('private-path', []);
      await Future<void>.delayed(Duration.zero);
      trace.setEnabled(false);
      trace.setEnabled(true);
      final count = messages.length;
      expect(run.pause(), isTrue);
      await process.finish();
      expect((await result).exitCode, 0);
      expect(messages, hasLength(count));
    },
  );

  test('disabled diagnostics preserve process output and failures', () async {
    trace.setEnabled(false);
    final process = _TraceProcess();
    final run = TaskProcessRunner(
      trace: trace,
      starter: (_, arguments) async => process,
    ).createRun();
    final result = run.run('private-path', []);
    await Future<void>.delayed(Duration.zero);
    process.out.add(utf8.encode('private-stdout'));
    await process.finish(2);
    expect((await result).stdout, 'private-stdout');
    expect(messages, isEmpty);
  });
}
