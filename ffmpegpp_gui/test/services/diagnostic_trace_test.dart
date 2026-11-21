import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/providers/app_state.dart';
import 'package:ffmpegpp_gui/services/diagnostic_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiagnosticTrace', () {
    test('is disabled by default and after disposal', () {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add);

      trace.record('backend.request.result', success: true);
      expect(events, isEmpty);

      trace.setEnabled(true);
      trace.dispose();
      trace.record('backend.request.result', success: true);
      expect(events, isEmpty);
    });

    test('emits safe metadata and preserves signed exit codes', () {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add)..setEnabled(true);

      trace.record(
        'ffmpeg.process.result',
        operation: 'transcode',
        elapsedMs: 12,
        argumentCount: 4,
        stdoutChars: 10,
        stderrChars: 3,
        exitCode: -15,
        success: false,
        cancelled: true,
      );

      expect(events, hasLength(1));
      expect(events.single, contains('operation=transcode'));
      expect(events.single, contains('elapsedMs=12'));
      expect(events.single, contains('exitCode=-15'));
      expect(events.single, contains('cancelled=true'));
      expect(events.single, isNot(contains('payload')));
    });

    test('pairs concurrent operations with distinct ids and elapsed time', () {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add);
      expect(trace.begin('task.run'), isNull);
      trace.setEnabled(true);
      final first = trace.begin('task.run')!;
      final second = trace.begin('task.run')!;
      second.record('task.step', details: {'stepIndex': 2});
      second.finish(success: false, error: const FormatException('secret'));
      first.finish(success: true);
      first.finish(success: true);

      expect(events, hasLength(5));
      final ids = events
          .map((event) => RegExp(r'opId=(\d+)').firstMatch(event)!.group(1))
          .toList();
      expect(ids[0], isNot(ids[1]));
      expect(ids[1], ids[2]);
      expect(ids[1], ids[3]);
      expect(ids[0], ids[4]);
      expect(events[3], contains('errorType=FormatException'));
      expect(events[3], contains('elapsedMs='));
      expect(events.join(), isNot(contains('secret')));
    });

    test('never resumes old operations after toggling off and on', () {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add)..setEnabled(true);
      final span = trace.begin('task.run')!;
      trace.setEnabled(false);
      trace.setEnabled(true);
      span.record('task.step');
      span.finish(success: true);
      expect(events, hasLength(1));
    });

    test('limits detail fields to finite numbers booleans and safe labels', () {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add)..setEnabled(true);
      trace.record(
        'test.details',
        details: {
          'phase': 'decode',
          'attempt': 2,
          'ratio': 0.5,
          'cached': true,
          'private': '/home/private/file',
          'raw error': 'secret',
          'nested': {'token': 'secret'},
          'invalidNumber': double.nan,
          'opId': 12345,
          'success': false,
        },
      );
      expect(events.single, contains('phase=decode'));
      expect(events.single, contains('attempt=2'));
      expect(events.single, contains('ratio=0.5'));
      expect(events.single, contains('cached=true'));
      expect(events.single, isNot(contains('private')));
      expect(events.single, isNot(contains('secret')));
      expect(events.single, isNot(contains('nested')));
      expect(events.single, isNot(contains('NaN')));
      expect(events.single, isNot(contains('opId=')));
      expect(events.single, isNot(contains('success=')));
    });

    test('a throwing sink cannot affect traced operations', () {
      final trace = DiagnosticTrace((_) => throw StateError('sink'))
        ..setEnabled(true);
      final span = trace.begin('task.run')!;
      expect(() => span.record('task.step'), returnsNormally);
      expect(
        () => span.finish(success: false, error: StateError('private')),
        returnsNormally,
      );
    });

    test('normalizes unsafe event labels without exposing input', () {
      final events = <String>[];
      final trace = DiagnosticTrace(events.add)..setEnabled(true);

      trace.record('backend request / secret-value', operation: '/tmp/private');

      expect(events.single, startsWith('other operation=other'));
    });
  });

  group('AppState trace logs', () {
    test(
      'requires the toggle, batches notifications, and remains bounded',
      () async {
        final state = AppState();
        var notifications = 0;
        state.addListener(() => notifications++);

        state.addLog('not enabled', category: 'trace');
        expect(state.logEntries, isEmpty);

        state.config.veryVerboseLogs = true;
        state.diagnosticTrace.setEnabled(true);
        for (var index = 0; index < 2100; index++) {
          state.addLog('safe event $index', category: 'trace');
        }

        expect(notifications, 0);
        await Future<void>.delayed(Duration.zero);
        expect(notifications, 1);
        expect(state.logEntries, hasLength(2000));
        expect(
          state.logEntries.every((entry) => entry.category == 'trace'),
          isTrue,
        );

        state.diagnosticTrace.dispose();
        state.addLog('ignored after dispose', category: 'trace');
        expect(state.logEntries, hasLength(2000));
        state.dispose();
      },
    );
  });

  group('AppConfig very verbose logs', () {
    test('defaults off and round trips snake case JSON', () {
      final defaults = AppConfig();
      expect(defaults.veryVerboseLogs, isFalse);
      expect(defaults.toJson()['very_verbose_logs'], isFalse);

      final enabled = AppConfig.fromJson({'very_verbose_logs': true});
      expect(enabled.veryVerboseLogs, isTrue);
      expect(enabled.toJson()['very_verbose_logs'], isTrue);

      final invalid = AppConfig.fromJson({'very_verbose_logs': 'yes'});
      expect(invalid.veryVerboseLogs, isFalse);
    });
  });
}
