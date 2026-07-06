import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'native_bridge.dart';


class PythonProcessManager {
  // DLL 模式
  NativeBridge? _bridge;
  Timer? _pollTimer;

  final _responseController = StreamController<Map<String, dynamic>>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _pendingCompleters = <String, Completer<Map<String, dynamic>>>{};
  int _reqCounter = 0;

  Map<String, dynamic>? _cachedReady;
  Completer<Map<String, dynamic>>? _readyCompleter;

  Stream<Map<String, dynamic>> get responses => _responseController.stream;
  Stream<String> get errors => _errorController.stream;
  bool get isRunning => _bridge != null;

  Future<Map<String, dynamic>> waitForReady({Duration timeout = const Duration(seconds: 30)}) async {
    if (_cachedReady != null) return _cachedReady!;
    if (_readyCompleter == null) return {'type': 'timeout'};
    return _readyCompleter!.future.timeout(timeout, onTimeout: () {
      return {'type': 'timeout'};
    });
  }

  Future<void> start(String serverPath) async {
    _readyCompleter = Completer<Map<String, dynamic>>();
    await _startDll(serverPath);
  }

  Future<void> _startDll(String dllPath) async {
    if (_bridge != null) return;

    debugPrint('[DLL] loading: $dllPath');
    try {
      _bridge = NativeBridge(dllPath);
      final result = _bridge!.init();
      debugPrint('[DLL] init returned: $result');

      _startPolling();
    } catch (e) {
      debugPrint('[DLL] LOAD ERROR: $e');
      _errorController.add('DLL load error: $e');
      _bridge = null;
    }
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_bridge == null) return;
      int count = 0;
      while (count < 100) {
        final line = _bridge!.poll();
        if (line == null) break;
        _handleLine(line.trim());
        count++;
      }
    });
  }

  void _handleLine(String line) {
    if (line.isEmpty) return;
    try {
      final obj = jsonDecode(line) as Map<String, dynamic>;
      if (obj.containsKey('type')) {
        if (obj['type'] == 'ready') {
          _cachedReady = obj;
          if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
            _readyCompleter!.complete(obj);
          }
        }
        _responseController.add(obj);
      } else if (obj.containsKey('id')) {
        final id = obj['id'] as String;
        final completer = _pendingCompleters.remove(id);
        if (completer != null) completer.complete(obj);
      }
    } catch (e) {
      _errorController.add('parse error: $e');
    }
  }

  void _sendRequest(Map<String, dynamic> req) {
    if (_bridge == null) return;
    _bridge!.request(jsonEncode(req));
  }

  Future<Map<String, dynamic>> request(String action, [Map<String, dynamic>? params]) async {
    return _doRequest(action, params, 120);
  }

  Future<Map<String, dynamic>> requestWithTimeout(String action, int timeoutSec, [Map<String, dynamic>? params]) async {
    return _doRequest(action, params, timeoutSec);
  }

  Future<Map<String, dynamic>> requestWithId(String id, String action, [Map<String, dynamic>? params]) async {
    if (!isRunning) {
      return {'id': id, 'success': false, 'error': '后端未启动'};
    }
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[id] = completer;

    final Map<String, dynamic> req = {'id': id, 'action': action};
    if (params != null) req['params'] = params;

    _sendRequest(req);

    return completer.future.timeout(
      const Duration(seconds: 3600),
      onTimeout: () {
        _pendingCompleters.remove(id);
        return {'id': id, 'success': false, 'error': '超时'};
      },
    );
  }

  Future<Map<String, dynamic>> _doRequest(String action, Map<String, dynamic>? params, int timeoutSec) async {
    if (!isRunning) {
      return {'success': false, 'error': '后端未启动'};
    }
    final id = 'req_${++_reqCounter}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[id] = completer;

    final Map<String, dynamic> req = {'id': id, 'action': action};
    if (params != null) req['params'] = params;

    _sendRequest(req);

    return completer.future.timeout(
      Duration(seconds: timeoutSec),
      onTimeout: () {
        _pendingCompleters.remove(id);
        return {'id': id, 'success': false, 'error': '请求超时 (${timeoutSec}s)'};
      },
    );
  }

  void cancel() {
    if (!isRunning) return;
    final Map<String, dynamic> req = {'id': 'cancel_${++_reqCounter}', 'action': 'cancel'};
    _sendRequest(req);
  }

  Future<void> shutdown() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_bridge != null) {
      try {
        _bridge!.shutdown();
      } catch (_) {}
      _bridge = null;
    }
  }

  void dispose() {
    final responseClosed = _responseController.isClosed;
    final errorClosed = _errorController.isClosed;
    shutdown().whenComplete(() {
      if (!responseClosed) _responseController.close();
      if (!errorClosed) _errorController.close();
    });
    if (!responseClosed) _responseController.close();
    if (!errorClosed) _errorController.close();
  }
}
