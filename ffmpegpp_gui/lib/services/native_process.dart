import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'diagnostic_trace.dart';
import 'native_bridge.dart';

class NativeProcessManager {
  NativeProcessManager({DiagnosticTrace? trace})
    // Keep the optional injection parameter public.
    // ignore: prefer_initializing_formals
    : _trace = trace,
      _bridgeFactory = NativeBridge.new;

  /// Uses an isolated transport without loading a native library in tests.
  @visibleForTesting
  NativeProcessManager.withBridgeFactory(
    NativeBridge Function(String path) bridgeFactory, {
    DiagnosticTrace? trace,
  // Keep the optional injection parameter public.
  // ignore: prefer_initializing_formals
  }) : _trace = trace,
       _bridgeFactory = bridgeFactory;

  final DiagnosticTrace? _trace;
  final NativeBridge Function(String path) _bridgeFactory;

  // DLL 模式
  NativeBridge? _bridge;
  static const _activePollMs = 16;
  static const _maxIdlePollMs = 250;
  static const _pollBurstLimit = 100;
  static const _pollBudgetUs = 3000;
  Timer? _pollTimer;
  int _pollDelayMs = _activePollMs;
  Timer? _receiveTraceTimer;
  int _receivedMessages = 0;
  int _receiveMicros = 0;
  DiagnosticSpan? _receiveSpan;

  final _responseController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _pendingCompleters = <String, Completer<Map<String, dynamic>>>{};
  final _pendingSpans = <String, DiagnosticSpan>{};
  int _reqCounter = 0;
  // [FIX M-2] 析构标志：置位后所有 Stream add 与轮询回调静默跳过，避免关闭
  // Controller 后继续 add 抛 StateError（Controller closed）。
  bool _disposed = false;

  Map<String, dynamic>? _cachedReady;
  Completer<Map<String, dynamic>>? _readyCompleter;

  Stream<Map<String, dynamic>> get responses => _responseController.stream;
  Stream<String> get errors => _errorController.stream;
  bool get isRunning => _bridge != null;

  Future<Map<String, dynamic>> waitForReady({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final span = _begin('ffi.ready.wait', {'timeoutMs': timeout.inMilliseconds});
    final result = _cachedReady ?? (_readyCompleter == null
        ? <String, dynamic>{'type': 'timeout'}
        : await _readyCompleter!.future.timeout(
            timeout,
            onTimeout: () {
              if (!_disposed) span?.record('ffi.ready.timeout');
              return {'type': 'timeout'};
            },
          ));
    if (!_disposed) {
      span?.finish(success: result['type'] == 'ready', details: {
        if (result['type'] != 'ready')
          'failureKind': result['type'] == 'timeout' ? 'timeout' : 'unavailable',
      });
    }
    return result;
  }

  Future<void> start(String serverPath) async {
    if (_disposed) throw StateError('后端已销毁');
    if (_bridge != null) return;
    _cachedReady = null;
    _readyCompleter = Completer<Map<String, dynamic>>();
    await _startDll(serverPath);
  }

  Future<void> _startDll(String dllPath) async {
    if (_bridge != null) return;

    debugPrint('[DLL] loading native library');
    try {
      _bridge = _traceCall('ffi.library.load', () => _bridgeFactory(dllPath));
      final result = _traceCall('ffi.init', _bridge!.init);
      debugPrint('[DLL] init returned: $result');
      if (result != 0) {
        throw StateError('后端初始化失败 (code=$result)');
      }

      _startPolling();
    } catch (e) {
      debugPrint('[DLL] native library load failed');
      // [FIX M-2] 析构后不要对已关闭的 Controller 调 add
      if (!_errorController.isClosed) {
        _errorController.add('DLL load error: $e');
      }
      _bridge = null;
      _cachedReady = {'type': 'error', 'error': 'DLL load error: $e'};
      if (!_readyCompleter!.isCompleted) {
        _readyCompleter!.complete(_cachedReady!);
      }
      rethrow;
    }
  }

  void _schedulePoll() {
    _pollTimer = Timer(Duration(milliseconds: _pollDelayMs), _poll);
  }

  void _startPolling() {
    // Do not postpone a fast poll when several requests arrive together.
    if (_pollTimer != null && _pollDelayMs == _activePollMs) return;
    _pollTimer?.cancel();
    _pollDelayMs = _activePollMs;
    _schedulePoll();
  }

  void _poll() {
    _pollTimer = null;
    final bridge = _bridge;
    if (_disposed || bridge == null) return;

    var count = 0;
    final elapsed = Stopwatch()..start();
    try {
      // Always consume at least one response, then yield between messages.
      while (count < _pollBurstLimit &&
          (count == 0 || elapsed.elapsedMicroseconds < _pollBudgetUs)) {
        final line = bridge.poll();
        if (line == null) break;
        _handleLine(line.trim());
        count++;
      }
    } catch (_) {
      _record('ffi.read.failed', {
        'failureKind': 'read_failure',
        'pendingCount': _pendingCompleters.length,
        'itemCount': count,
      });
      rethrow;
    } finally {
      if (!_disposed && count > 0 && _trace?.enabled == true) {
        if (_receiveSpan?.enabled == false) {
          _receiveSpan?.finish(success: false);
          _receiveSpan = null;
          _receivedMessages = 0;
          _receiveMicros = 0;
        }
        _receiveSpan ??= _begin('ffi.receive');
        _receivedMessages += count;
        _receiveMicros += elapsed.elapsedMicroseconds;
        _receiveTraceTimer ??= Timer(
          const Duration(milliseconds: 400),
          _flushReceiveTrace,
        );
      }
      if (!_disposed && identical(_bridge, bridge)) {
        if (count > 0 ||
            _pendingCompleters.isNotEmpty ||
            _readyCompleter?.isCompleted == false) {
          _pollDelayMs = _activePollMs;
        } else {
          _pollDelayMs = (_pollDelayMs * 2).clamp(
            _activePollMs,
            _maxIdlePollMs,
          );
        }
        _schedulePoll();
      }
    }
  }

  void _flushReceiveTrace() {
    _receiveTraceTimer?.cancel();
    _receiveTraceTimer = null;
    final span = _receiveSpan;
    _receiveSpan = null;
    if (!_disposed && _receivedMessages > 0) {
      span?.record('ffi.responses', details: {
        'itemCount': _receivedMessages,
        'receiveMs': _receiveMicros ~/ 1000,
      });
      span?.finish(success: true, details: {'itemCount': _receivedMessages});
    }
    _receivedMessages = 0;
    _receiveMicros = 0;
  }

  DiagnosticSpan? _begin(String operation, [Map<String, Object?>? details]) =>
      _disposed ? null : _trace?.begin(operation, details: details);

  void _record(String event, [Map<String, Object?>? details]) {
    if (!_disposed) _trace?.record(event, details: details);
  }

  T _traceCall<T>(String event, T Function() run) {
    final span = _begin(event);
    if (span == null) return run();
    try {
      final result = run();
      if (!_disposed) {
        span.finish(success: result is! int || result == 0, details: {
          if (result is int) 'exitCode': result,
          if (result is int && result != 0) 'failureKind': 'native_rejected',
        });
      }
      return result;
    } catch (_) {
      if (!_disposed) {
        span.finish(success: false, details: {'failureKind': 'transport_failure'});
      }
      rethrow;
    }
  }

  // Action names cross the public request boundary; never log arbitrary values.
  static String _actionLabel(String action) => switch (action) {
    'check_env' || 'set_paths' || 'probe' || 'transcode' || 'subtitle' ||
    'extract_frame' || 'remove_metadata' || 'concat' ||
    'image_sequence' || 'fppx_import' || 'fppx2_export' ||
    'fppx_legacy_export' || 'pause' || 'resume' || 'cancel' || 'ping' => action,
    _ => 'other',
  };

  void _finishRequest(
    String id,
    Map<String, dynamic> result, {
    String? failureKind,
    int? timeoutMs,
  }) {
    final span = _pendingSpans.remove(id);
    if (_disposed) return;
    span?.finish(
      success: result['success'] == true,
      cancelled: result['cancelled'] == true,
      details: {
        'responseFields': result.length,
        'pendingCount': _pendingCompleters.length,
        'timeoutMs': ?timeoutMs,
        if (failureKind != null)
          'failureKind': failureKind
        else if (result['success'] is! bool)
          'failureKind': 'malformed_response'
        else if (result['success'] == false)
          'failureKind': 'backend_rejected',
      },
    );
  }

  void _handleLine(String line) {
    // [FIX M-2] 析构后丢弃后续行，避免对已关闭的 Controller 调 add
    if (_disposed || line.isEmpty) return;
    try {
      final obj = jsonDecode(line) as Map<String, dynamic>;
      if (obj.containsKey('type')) {
        if (obj['type'] == 'ready') {
          _record('ffi.ready');
          _cachedReady = obj;
          if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
            _readyCompleter!.complete(obj);
          }
        }
        // [FIX M-2] 关闭后仍可能进入，先判 isClosed 再 add
        if (!_responseController.isClosed) _responseController.add(obj);
      }
      // 响应可能同时带 'id' 与 'type'：只要有 String id 就完成挂起的请求，
      // 两条分支非互斥，避免带 id 的响应永远不被消费导致 Future 挂起。
      if (obj['id'] is String) {
        final id = obj['id'] as String;
        final completer = _pendingCompleters.remove(id);
        if (completer != null) {
          _finishRequest(id, obj);
          completer.complete(obj);
        } else {
          _record('ffi.response.unmatched', {'pendingCount': _pendingCompleters.length});
        }
      }
    } catch (e) {
      _record('ffi.response.decode_failed', {
        'failureKind': 'malformed_response',
        'pendingCount': _pendingCompleters.length,
      });
      // [FIX M-2] 关闭后不要对已关闭的 Controller 调 add
      if (!_errorController.isClosed) _errorController.add('parse error: $e');
      // [FIX S-2] 解析失败时兜底完成对应 completer，避免长任务 Future 永久挂起
      final m = RegExp(r'"id"\s*:\s*"([^"]+)"').firstMatch(line);
      final c = m == null ? null : _pendingCompleters.remove(m.group(1));
      if (c != null && !c.isCompleted) {
        final failure = <String, dynamic>{
          'success': false, 'error': '响应解析失败（后端返回的 JSON 不完整）',
        };
        _finishRequest(m!.group(1)!, failure, failureKind: 'malformed_response');
        c.complete(failure);
      }
    }
  }

  void _sendRequest(Map<String, dynamic> req) {
    final bridge = _bridge;
    if (bridge == null) throw StateError('后端未启动');
    final result = _traceCall(
      'ffi.send',
      () => bridge.request(jsonEncode(req)),
    );
    if (result != 0) {
      // Rejection may not enqueue a reply. Both request paths catch this and
      // remove their pending completer before returning a failure immediately.
      throw StateError('后端拒绝请求 (code=$result)');
    }
    _startPolling();
  }

  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic>? params,
  ]) async {
    return _doRequest(action, params, 120);
  }

  Future<Map<String, dynamic>> requestWithTimeout(
    String action,
    int timeoutSec, [
    Map<String, dynamic>? params,
  ]) async {
    return _doRequest(action, params, timeoutSec);
  }

  Future<Map<String, dynamic>> requestWithId(
    String id,
    String action, [
    Map<String, dynamic>? params,
  ]) async {
    final span = _begin('ffi.request', {
      'action': _actionLabel(action),
      'requestFields': params?.length ?? 0,
      'pendingCount': _pendingCompleters.length,
      'bounded': false,
    });
    if (!isRunning) {
      span?.finish(success: false, details: {'failureKind': 'unavailable'});
      return {'id': id, 'success': false, 'error': '后端未启动'};
    }
    if (_pendingCompleters.containsKey(id)) {
      span?.finish(success: false, details: {'failureKind': 'duplicate_request'});
      return {'id': id, 'success': false, 'error': '请求 ID 已在使用中'};
    }
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[id] = completer;
    if (span != null) _pendingSpans[id] = span;

    final Map<String, dynamic> req = {'id': id, 'action': action};
    if (params != null) req['params'] = params;

    try {
      _sendRequest(req);
    } catch (e) {
      _pendingCompleters.remove(id);
      final failure = <String, dynamic>{
        'id': id, 'success': false, 'error': '请求发送失败: $e',
      };
      _finishRequest(id, failure, failureKind: 'send_failed');
      return failure;
    }

    // 长任务（transcode/subtitle/自定义命令/抽帧/合并/图片序列）不设超时：
    // 后端关闭或崩溃时由 _failAllPending 统一 complete，避免长时间编码被 600s 硬超时误判失败。
    return completer.future;
  }

  Future<Map<String, dynamic>> _doRequest(
    String action,
    Map<String, dynamic>? params,
    int timeoutSec,
  ) async {
    final span = _begin('ffi.request', {
      'action': _actionLabel(action),
      'requestFields': params?.length ?? 0,
      'pendingCount': _pendingCompleters.length,
      'timeoutMs': timeoutSec * 1000,
      'bounded': true,
    });
    if (!isRunning) {
      span?.finish(success: false, details: {'failureKind': 'unavailable'});
      return {'success': false, 'error': '后端未启动'};
    }
    final id = 'req_${++_reqCounter}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[id] = completer;
    if (span != null) _pendingSpans[id] = span;

    final Map<String, dynamic> req = {'id': id, 'action': action};
    if (params != null) req['params'] = params;

    try {
      _sendRequest(req);
    } catch (e) {
      _pendingCompleters.remove(id);
      final failure = <String, dynamic>{
        'id': id, 'success': false, 'error': '请求发送失败: $e',
      };
      _finishRequest(id, failure, failureKind: 'send_failed');
      return failure;
    }

    return completer.future.timeout(
      Duration(seconds: timeoutSec),
      onTimeout: () {
        _pendingCompleters.remove(id);
        if (!_disposed) {
          span?.record('ffi.reply.timeout', details: {
            'itemCount': _pendingCompleters.length,
            'timeoutMs': timeoutSec * 1000,
            'failureKind': 'timeout',
          });
        }
        final failure = <String, dynamic>{
          'id': id, 'success': false, 'error': '请求超时 (${timeoutSec}s)',
        };
        _finishRequest(id, failure, failureKind: 'timeout', timeoutMs: timeoutSec * 1000);
        return failure;
      },
    );
  }

  /// 真正冻结 / 解冻后端正在执行的 ffmpeg 子进程（按任务 id）。
  ///
  /// C++ 端对 task id 记录暂停标记：runWithProgress 在 POSIX 上发 SIGSTOP /
  /// SIGCONT，在 Windows 上调用 NtSuspendProcess / NtResumeProcess。因此
  /// 冻结的是**那个 ffmpeg 进程本身**（CPU 归零、不再产出），恢复后从同一
  /// 时刻继续，不重启、不丢进度。
  ///
  /// 注意 pause/resume 在 C++ 里是**内联**处理的（不进 worker 队列）：
  /// 否则 worker 正阻塞在 runWithProgress 里等这个信号，永远轮不到执行它。
  /// 返回后端回执；后端未启动或 id 为空时返回 success=false，调用方必须据此
  /// 显示真实失败，绝不能只改 UI 状态。
  Future<Map<String, dynamic>> pause(List<String> taskIds) async {
    if (taskIds.isEmpty) {
      return {'success': false, 'error': 'pause 缺少 task_id'};
    }
    return _doRequest('pause', {'task_ids': taskIds}, 10);
  }

  Future<Map<String, dynamic>> resume(List<String> taskIds) async {
    if (taskIds.isEmpty) {
      return {'success': false, 'error': 'resume 缺少 task_id'};
    }
    return _doRequest('resume', {'task_ids': taskIds}, 10);
  }

  /// [taskIds] 非空时同时让后端跳过队列中这些尚未开始的任务
  void cancel([List<String>? taskIds]) {
    final span = _begin('ffi.cancel', {'itemCount': taskIds?.length ?? 0});
    if (!isRunning) {
      span?.finish(success: false, details: {'failureKind': 'unavailable'});
      return;
    }
    final Map<String, dynamic> req = {
      'id': 'cancel_${++_reqCounter}',
      'action': 'cancel',
    };
    if (taskIds != null && taskIds.isNotEmpty) {
      req['params'] = {'task_ids': taskIds};
    }
    try {
      _sendRequest(req);
      if (!_disposed) span?.finish(success: true);
    } catch (_) {
      if (!_disposed) {
        span?.finish(success: false, details: {'failureKind': 'send_failed'});
      }
      // Cancellation is fire-and-forget: preserve caller cleanup on rejection.
      if (!_disposed && !_errorController.isClosed) {
        _errorController.add('取消请求被拒绝或发送失败');
      }
    }
  }

  /// 后端关闭/销毁时完成所有挂起请求，防止调用方 Future 永久挂起
  /// （transcode 等长任务请求无超时，若后端崩溃且无人 complete，会一直悬着）。
  // [FIX M-1] 失败所有挂起请求时把 id 一并写进响应，调用方可用 resp['id'] 关联任务
  void _failAllPending(String error) {
    final pending = Map<String, Completer<Map<String, dynamic>>>.from(
      _pendingCompleters,
    );
    _pendingCompleters.clear();
    if (pending.isNotEmpty) {
      _record('ffi.pending.aborted', {'itemCount': pending.length});
    }
    pending.forEach((id, c) {
      if (!c.isCompleted) {
        final failure = <String, dynamic>{'id': id, 'success': false, 'error': error};
        _finishRequest(id, failure, failureKind: 'shutdown');
        c.complete(failure);
      }
    });
    _pendingSpans.clear();
  }

  void _stopPolling(String error) {
    _pollTimer?.cancel();
    _pollTimer = null;
    _flushReceiveTrace();
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      final failure = <String, dynamic>{'type': 'error', 'error': error};
      _cachedReady = failure;
      ready.complete(failure);
    }
  }

  Future<void> shutdown() async {
    _stopPolling('后端已关闭');
    _shutdownBridge();
    _failAllPending('后端已关闭');
  }

  void _shutdownBridge() {
    final bridge = _bridge;
    if (bridge == null) return;
    try {
      _traceCall('ffi.shutdown', bridge.shutdown);
    } catch (_) {
    } finally {
      _bridge = null;
    }
  }

  void dispose() {
    if (_disposed) return;
    // [FIX M-2] 先置析构标志并取消轮询 Timer，再关闭流控制器；不 await 异步
    // shutdown（dispose 同步），但各 add 点已被 _disposed / isClosed 守卫，
    // 末尾到达的 poll 回调不会再对已关闭的 Controller 调 add 而抛 StateError。
    _disposed = true;
    _stopPolling('后端已销毁');
    _failAllPending('后端已销毁');
    _shutdownBridge();
    if (!_responseController.isClosed) _responseController.close();
    if (!_errorController.isClosed) _errorController.close();
  }
}
