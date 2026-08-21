import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'native_bridge.dart';


class NativeProcessManager {
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
      }
      // 响应可能同时带 'id' 与 'type'：只要有 String id 就完成挂起的请求，
      // 两条分支非互斥，避免带 id 的响应永远不被消费导致 Future 挂起。
      if (obj['id'] is String) {
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
      const Duration(minutes: 10),
      onTimeout: () {
        _pendingCompleters.remove(id);
        return {'id': id, 'success': false, 'error': '请求超时 (600s)'};
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

  /// [taskIds] 非空时同时让后端跳过队列中这些尚未开始的任务
  void cancel([List<String>? taskIds]) {
    if (!isRunning) return;
    final Map<String, dynamic> req = {'id': 'cancel_${++_reqCounter}', 'action': 'cancel'};
    if (taskIds != null && taskIds.isNotEmpty) {
      req['params'] = {'task_ids': taskIds};
    }
    _sendRequest(req);
  }

  /// 后端关闭/销毁时完成所有挂起请求，防止调用方 Future 永久挂起
  /// （transcode 等长任务请求无超时，若后端崩溃且无人 complete，会一直悬着）。
  void _failAllPending(String error) {
    final pending = _pendingCompleters.values.toList();
    _pendingCompleters.clear();
    for (final c in pending) {
      if (!c.isCompleted) {
        c.complete({'success': false, 'error': error});
      }
    }
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
    _failAllPending('后端已关闭');
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _failAllPending('后端已销毁');
    shutdown().ignore();
    if (!_responseController.isClosed) _responseController.close();
    if (!_errorController.isClosed) _errorController.close();
  }
}
