import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  }) : _starter =
           starter ??
           ((executable, arguments) => Process.start(executable, arguments)),
       _windows = windows ?? Platform.isWindows;

  final TaskProcessStarter _starter;
  final bool _windows;
  final Duration killDelay;
  final int captureLimit;

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
  bool _paused = false;

  bool get isCancelled => _cancelled;
  bool get isPaused => _paused;
  bool get isActive => _operation != null;
  Future<void> get idle => _operation?.future ?? Future<void>.value();

  void throwIfCancelled() {
    if (_cancelled) throw const TaskProcessCancelled();
  }

  /// Latches before signaling, including when Process.start has not resolved yet.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _terminate();
  }

  bool pause() {
    if (_cancelled || _runner._windows) return false;
    final process = _process;
    if (process == null || !_signal(process, ProcessSignal.sigstop)) {
      return false;
    }
    _paused = true;
    return true;
  }

  bool resume() {
    final process = _process;
    if (process == null || _runner._windows || _cancelled) return false;
    if (!_signal(process, ProcessSignal.sigcont)) return false;
    _paused = false;
    return true;
  }

  bool _signal(Process process, ProcessSignal signal) {
    try {
      return process.kill(signal);
    } catch (_) {
      return false;
    }
  }

  void _terminate() {
    final process = _process;
    if (process == null) return;
    if (!_runner._windows) _signal(process, ProcessSignal.sigcont);
    _signal(process, ProcessSignal.sigterm);
    _killTimer ??= Timer(_runner.killDelay, () {
      if (identical(_process, process)) _signal(process, ProcessSignal.sigkill);
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
    final operation = Completer<void>();
    _operation = operation;
    try {
      final process = await _runner._starter(
        executable,
        List<String>.of(arguments),
      );
      _process = process;
      // No await between registration and rechecking the latched cancellation.
      if (_cancelled) {
        _terminate();
      }
      var stdout = '';
      var stderr = '';
      Object? failure;
      StackTrace? failureStack;
      void recordFailure(Object error, StackTrace stack) {
        failure ??= error;
        failureStack ??= stack;
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
          await for (final chunk in stream.transform(
            const Utf8Decoder(allowMalformed: true),
          )) {
            if (errorStream) {
              stderr = appendTail(stderr, chunk);
              if (!_cancelled && failure == null && onStderr != null) {
                try {
                  onStderr(chunk);
                } catch (error, stack) {
                  recordFailure(error, stack);
                }
              }
            } else {
              if (failure == null) {
                if (stdout.length + chunk.length > _runner.captureLimit) {
                  recordFailure(
                    StateError('Task process stdout exceeded captureLimit'),
                    StackTrace.current,
                  );
                } else {
                  stdout += chunk;
                }
              }
            }
          }
        } catch (error, stack) {
          recordFailure(error, stack);
        }
      }

      var exitCode = -1;
      Future<void> waitExit() async {
        try {
          exitCode = await process.exitCode;
        } catch (error, stack) {
          recordFailure(error, stack);
        }
      }

      await Future.wait<void>([
        consume(process.stdout, false),
        consume(process.stderr, true),
        waitExit(),
      ]);
      throwIfCancelled();
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      return ProcessResult(process.pid, exitCode, stdout, stderr);
    } finally {
      _killTimer?.cancel();
      _killTimer = null;
      _process = null;
      _paused = false;
      _operation = null;
      operation.complete();
    }
  }
}
