/// Local, opt-in diagnostics. Call sites pass only fixed labels, counts,
/// timings and booleans, never paths, credentials, commands or request bodies.
/// Failures expose their type, not their potentially sensitive message.
class DiagnosticTrace {
  DiagnosticTrace(this._emit);

  final void Function(String message) _emit;
  bool _enabled = false;
  bool _disposed = false;
  int _generation = 0;
  int _nextId = 0;

  bool get enabled => _enabled && !_disposed;

  /// A new enable period must not receive results from an older operation.
  void setEnabled(bool value) {
    if (_disposed || value == _enabled) return;
    _generation++;
    _enabled = value;
  }

  void dispose() {
    _generation++;
    _enabled = false;
    _disposed = true;
  }

  /// Returns null without allocating a stopwatch while diagnostics are off.
  DiagnosticSpan? begin(String operation, {Map<String, Object?>? details}) {
    if (!enabled) return null;
    final span = DiagnosticSpan._(
      this,
      _safeLabel(operation),
      ++_nextId,
      _generation,
    );
    span.record('${span._operation}.start', details: details);
    return span;
  }

  /// Emits a single-line event. Detail strings must be fixed labels at the call
  /// site; user-controlled strings, nested objects and nonfinite numbers are
  /// rejected. The limit also bounds formatting work per event.
  void record(
    String event, {
    String? operation,
    int? opId,
    int? elapsedMs,
    int? requestFields,
    int? responseFields,
    int? itemCount,
    int? argumentCount,
    int? stdoutChars,
    int? stderrChars,
    int? byteCount,
    int? exitCode,
    bool? success,
    bool? cancelled,
    Object? error,
    Map<String, Object?>? details,
  }) {
    if (!enabled) return;
    final message = StringBuffer(_safeLabel(event));
    final written = <String>{
      'operation',
      'opId',
      'elapsedMs',
      'success',
      'cancelled',
      'errorType',
    };
    void addInt(String key, int? value, {bool signed = false}) {
      if (value == null) return;
      written.add(key);
      message.write(' $key=${signed ? value : (value < 0 ? 0 : value)}');
    }

    void addBool(String key, bool? value) {
      if (value != null) message.write(' $key=$value');
    }

    if (operation != null) {
      message.write(' operation=${_safeLabel(operation)}');
    }
    addInt('opId', opId);
    addInt('elapsedMs', elapsedMs);
    addInt('requestFields', requestFields);
    addInt('responseFields', responseFields);
    addInt('itemCount', itemCount);
    addInt('argumentCount', argumentCount);
    addInt('stdoutChars', stdoutChars);
    addInt('stderrChars', stderrChars);
    addInt('byteCount', byteCount);
    addInt('exitCode', exitCode, signed: true);
    addBool('success', success);
    addBool('cancelled', cancelled);
    if (error != null) {
      message.write(' errorType=${_safeLabel(error.runtimeType.toString())}');
    }
    if (details != null) {
      var count = 0;
      for (final entry in details.entries) {
        if (count++ >= 32) break;
        final key = entry.key;
        if (!_labelPattern.hasMatch(key) || !written.add(key)) continue;
        final value = entry.value;
        if (value is bool ||
            value is num && value.isFinite ||
            value is String && _labelPattern.hasMatch(value)) {
          message.write(' $key=$value');
        }
      }
    }
    try {
      _emit(message.toString());
    } catch (_) {
      // Diagnostics must never change the result of the operation being traced.
    }
  }

  static final RegExp _labelPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,48}$');
  static String _safeLabel(String value) =>
      _labelPattern.hasMatch(value) ? value : 'other';
}

/// A paired operation with an opaque id. Results remain suppressed after
/// disable/dispose, including when logging has since been enabled again.
class DiagnosticSpan {
  DiagnosticSpan._(this._trace, this._operation, this.id, this._generation);

  final DiagnosticTrace _trace;
  final String _operation;
  final int id;
  final int _generation;
  final Stopwatch _watch = Stopwatch()..start();
  bool _finished = false;

  bool get enabled =>
      !_finished && _trace.enabled && _trace._generation == _generation;

  void record(String event, {Map<String, Object?>? details}) {
    if (!enabled) return;
    _trace.record(
      event,
      operation: _operation,
      opId: id,
      elapsedMs: _watch.elapsedMilliseconds,
      details: details,
    );
  }

  void finish({
    required bool success,
    bool cancelled = false,
    Object? error,
    Map<String, Object?>? details,
  }) {
    if (_finished) return;
    if (enabled) {
      _trace.record(
        '$_operation.result',
        operation: _operation,
        opId: id,
        elapsedMs: _watch.elapsedMilliseconds,
        success: success,
        cancelled: cancelled,
        error: error,
        details: details,
      );
    }
    _finished = true;
    _watch.stop();
  }
}
