import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'diagnostic_trace.dart';

/// Injectable process launch boundary; tests never launch an operating-system process.
typedef TaskProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// Cancellation is terminal for this run, independently of task ids or queue epochs.
class TaskProcessCancelled implements Exception {
  const TaskProcessCancelled();

  @override
  String toString() => 'Task process run cancelled';
}

/// Creates independent run identities. Retain one identity across probes and retries.
class TaskProcessRunner {
  TaskProcessRunner({
    TaskProcessStarter? starter,
    bool? windows,
    this.killDelay = const Duration(seconds: 2),
    this.captureLimit = 1024 * 1024,
    this.trace,
  }) : _starter =
           starter ??
           ((executable, arguments) => Process.start(executable, arguments)),
       _windows = windows ?? Platform.isWindows;

  final TaskProcessStarter _starter;
  final bool _windows;
  final Duration killDelay;
  final int captureLimit;
  final DiagnosticTrace? trace;

  TaskProcessRun createRun() => TaskProcessRun._(this);
}

/// Owns process lifetime through startup, exit and both output stream completions.
///
/// A run supports sequential invocations only. Cancellation never releases [idle]
/// early: even an OS refusing termination leaves the run occupied until it exits.
class TaskProcessRun {
  TaskProcessRun._(this._runner);

  final TaskProcessRunner _runner;
  Process? _process;
  Completer<void>? _operation;
  Timer? _killTimer;
  bool _cancelled = false;
  DiagnosticSpan? _span;

  bool get isCancelled => _cancelled;
  bool get isActive => _operation != null;
  Future<void> get idle => _operation?.future ?? Future<void>.value();

  void throwIfCancelled() {
    if (_cancelled) throw const TaskProcessCancelled();
  }

  /// Latches before signaling, including when Process.start has not resolved yet.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _span?.record('ffmpeg.process.cancel');
    _terminate();
  }

  bool pause() => _control('ffmpeg.process.pause', ProcessSignal.sigstop);

  bool resume() => _control('ffmpeg.process.resume', ProcessSignal.sigcont);

  bool _control(String event, ProcessSignal signal) {
    final process = _process;
    final failureKind = _cancelled
        ? 'cancelled'
        : _runner._windows
        ? 'unsupported_platform'
        : process == null
        ? 'not_running'
        : null;
    final success = failureKind == null && _signal(process!, signal);
    _span?.record(event, details: {
      'signalSuccess': success,
      if (!success) 'failureKind': failureKind ?? 'signal_failed',
    });
    return success;
  }

  bool _signal(Process process, ProcessSignal signal) {
    final label = signal == ProcessSignal.sigstop
        ? 'pause'
        : signal == ProcessSignal.sigcont
        ? 'resume'
        : signal == ProcessSignal.sigkill
        ? 'kill'
        : 'terminate';
    try {
      final success = process.kill(signal);
      if (!success) {
        _span?.record('ffmpeg.process.signal.failed', details: {
          'signal': label, 'failureKind': 'signal_rejected',
        });
      }
      return success;
    } catch (_) {
      _span?.record('ffmpeg.process.signal.failed', details: {
        'signal': label, 'failureKind': 'signal_exception',
      });
      return false;
    }
  }

  void _terminate() {
    final process = _process;
    if (process == null) return;
    if (!_runner._windows) _signal(process, ProcessSignal.sigcont);
    _signal(process, ProcessSignal.sigterm);
    _killTimer ??= Timer(_runner.killDelay, () {
      if (identical(_process, process)) {
        _span?.record('ffmpeg.process.kill');
        _signal(process, ProcessSignal.sigkill);
      }
    });
  }

  /// Returns complete stdout and bounded stderr after exit and both streams.
  /// Stdout overflow fails after terminating and draining the process.
  /// Progress callbacks receive decoded stderr chunks while this run is live.
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    void Function(String chunk)? onStderr,
  }) async {
    throwIfCancelled();
    if (_operation != null) {
      throw StateError('A process is already active in this run');
    }
    final span = _runner.trace?.begin(
      'ffmpeg.process',
      details: {'argumentCount': arguments.length},
    );
    _span = span;
    span?.record('ffmpeg.process.request', details: {'argumentCount': arguments.length});
    final operation = Completer<void>();
    _operation = operation;
    var stdout = '';
    var stderr = '';
    int? exitCode;
    var success = false;
    var failureKind = 'start_failed';
    var failureCount = 0;
    var stdoutBytes = 0;
    var stderrBytes = 0;
    try {
      final process = await _runner._starter(
        executable,
        List<String>.of(arguments),
      );
      _process = process;
      failureKind = 'none';
      span?.record('ffmpeg.process.started');
      // No await between registration and rechecking the latched cancellation.
      if (_cancelled) {
        _terminate();
      }
      Object? failure;
      StackTrace? failureStack;
      void recordFailure(Object error, StackTrace stack, String kind) {
        failureCount++;
        if (failure == null) failureKind = kind;
        failure ??= error;
        failureStack ??= stack;
        span?.record('ffmpeg.process.failure', details: {
          'failureKind': kind, 'failureCount': failureCount,
        });
        _terminate();
      }

      String appendTail(String previous, String chunk) {
        final text = previous + chunk;
        final limit = _runner.captureLimit;
        if (limit <= 0) return '';
        return text.length > limit ? text.substring(text.length - limit) : text;
      }

      Future<void> consume(Stream<List<int>> stream, bool errorStream) async {
        try {
          final counted = span == null ? stream : stream.map((bytes) {
            if (errorStream) {
              stderrBytes += bytes.length;
            } else {
              stdoutBytes += bytes.length;
            }
            return bytes;
          });
          await for (final chunk in counted.transform(
            const Utf8Decoder(allowMalformed: true),
          )) {
            if (errorStream) {
              stderr = appendTail(stderr, chunk);
              if (!_cancelled && failure == null && onStderr != null) {
                try {
                  onStderr(chunk);
                } catch (error, stack) {
                  recordFailure(error, stack, 'callback_failed');
                }
              }
            } else {
              if (failure == null) {
                if (stdout.length + chunk.length > _runner.captureLimit) {
                  recordFailure(
                    StateError('Task process stdout exceeded captureLimit'),
                    StackTrace.current,
                    'stdout_overflow',
                  );
                } else {
                  stdout += chunk;
                }
              }
            }
          }
        } catch (error, stack) {
          recordFailure(error, stack, errorStream ? 'stderr_read_failed' : 'stdout_read_failed');
        }
      }

      Future<void> waitExit() async {
        try {
          exitCode = await process.exitCode;
          span?.record('ffmpeg.process.exit', details: {'exitCode': exitCode});
        } catch (error, stack) {
          recordFailure(error, stack, 'exit_failed');
        }
      }

      await Future.wait<void>([
        consume(process.stdout, false),
        consume(process.stderr, true),
        waitExit(),
      ]);
      throwIfCancelled();
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      success = exitCode == 0;
      if (!success) failureKind = 'exit_nonzero';
      return ProcessResult(process.pid, exitCode ?? -1, stdout, stderr);
    } finally {
      span?.finish(
        success: success,
        cancelled: _cancelled,
        details: {
          'stdoutChars': stdout.length,
          'stderrChars': stderr.length,
          'stdoutBytes': stdoutBytes,
          'stderrBytes': stderrBytes,
          'exitCode': ?exitCode,
          if (_cancelled)
            'failureKind': 'cancelled'
          else if (failureKind != 'none')
            'failureKind': failureKind,
          'failureCount': failureCount,
        },
      );
      _span = null;
      _killTimer?.cancel();
      _killTimer = null;
      _process = null;
      _operation = null;
      operation.complete();
    }
  }
}
