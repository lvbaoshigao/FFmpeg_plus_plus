import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef PanelIpcRequestHandler =
    FutureOr<dynamic> Function(String method, Map<String, dynamic> args);

class PanelProcessIpc {
  PanelProcessIpc(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (_) => _finish(StateError('Panel IPC socket failed')),
      onDone: () => _finish(StateError('Panel IPC peer disconnected')),
      cancelOnError: true,
    );
  }

  static const int maxMessageBytes = 8 * 1024 * 1024;
  static const int maxPendingRequests = 64;

  final Socket _socket;
  late final StreamSubscription<List<int>> _subscription;
  final Map<int, Completer<dynamic>> _pending = {};
  List<int> _buffer = [];
  int _nextId = 0;
  bool _closed = false;
  PanelIpcRequestHandler? onRequest;
  void Function()? onClosed;

  Future<dynamic> invoke(
    String method, [
    Map<String, dynamic>? args,
    Duration timeout = const Duration(seconds: 15),
  ]) async {
    if (_closed) throw StateError('Panel IPC connection is closed');
    if (_pending.length >= maxPendingRequests) {
      throw StateError('Too many pending panel IPC requests');
    }

    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      _write({
        'id': id,
        'method': method,
        'args': args ?? const <String, dynamic>{},
      });
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  void _write(Map<String, dynamic> message) {
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    if (bytes.length > maxMessageBytes) {
      throw StateError('Panel IPC message exceeds the size limit');
    }
    _socket.add(bytes);
  }

  void _onData(List<int> bytes) {
    for (final byte in bytes) {
      if (byte == 10) {
        final line = _buffer;
        _buffer = [];
        _onLine(line);
        if (_closed) return;
      } else {
        if (_buffer.length >= maxMessageBytes) {
          _finish(StateError('Panel IPC message exceeds the size limit'));
          return;
        }
        _buffer.add(byte);
      }
    }
  }

  void _onLine(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const FormatException('Invalid IPC envelope');
      final envelope = Map<String, dynamic>.from(decoded);
      final replyTo = envelope['replyTo'];
      if (replyTo is int) {
        final completer = _pending[replyTo];
        if (completer == null || completer.isCompleted) return;
        final error = envelope['error'];
        if (error is String) {
          completer.completeError(StateError(error));
        } else {
          completer.complete(envelope['result']);
        }
        return;
      }

      final id = envelope['id'];
      final method = envelope['method'];
      final rawArgs = envelope['args'];
      if (id is! int ||
          id < 0 ||
          method is! String ||
          method.length > 128 ||
          rawArgs is! Map) {
        throw const FormatException('Invalid IPC request');
      }
      unawaited(_dispatch(id, method, Map<String, dynamic>.from(rawArgs)));
    } catch (_) {
      _finish(StateError('Invalid panel IPC data'));
    }
  }

  Future<void> _dispatch(
    int id,
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final handler = onRequest;
      if (handler == null) throw StateError('Panel IPC handler is unavailable');
      _write({'replyTo': id, 'result': await handler(method, args)});
    } catch (_) {
      if (!_closed) {
        try {
          _write({'replyTo': id, 'error': 'request_failed'});
        } catch (_) {
          _finish(StateError('Could not reply over panel IPC'));
        }
      }
    }
  }

  void _finish(Object error) {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    _buffer = [];
    _socket.destroy();
    onClosed?.call();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Panel IPC connection closed'));
      }
    }
    _pending.clear();
    _buffer = [];
    await _subscription.cancel();
    await _socket.close();
    onClosed?.call();
  }
}
