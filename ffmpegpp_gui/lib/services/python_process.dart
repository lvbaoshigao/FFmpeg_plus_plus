import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'native_bridge.dart';


class PythonProcessManager {
  // EXE 模式
  Process? _process;

  // DLL 模式
  NativeBridge? _bridge;
  Timer? _pollTimer;
  bool _isDllMode = false;

  final _responseController = StreamController<Map<String, dynamic>>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _pendingCompleters = <String, Completer<Map<String, dynamic>>>{};
  int _reqCounter = 0;

  Map<String, dynamic>? _cachedReady;
  Completer<Map<String, dynamic>>? _readyCompleter;

  Stream<Map<String, dynamic>> get responses => _responseController.stream;
  Stream<String> get errors => _errorController.stream;
  bool get isRunning => _isDllMode ? _bridge != null : _process != null;

  Future<Map<String, dynamic>> waitForReady({Duration timeout = const Duration(seconds: 30)}) async {
    if (_cachedReady != null) return _cachedReady!;
    if (_readyCompleter == null) return {'type': 'timeout'};
    return _readyCompleter!.future.timeout(timeout, onTimeout: () {
      return {'type': 'timeout'};
    });
  }

  Future<void> start(String serverPath) async {
    _isDllMode = serverPath.toLowerCase().endsWith('.dll');
    _readyCompleter = Completer<Map<String, dynamic>>();

    if (_isDllMode) {
      await _startDll(serverPath);
    } else {
      await _startExe(serverPath);
    }
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

  Future<void> _startExe(String serverPath) async {
    if (_process != null) return;

    final isExe = serverPath.toLowerCase().endsWith('.exe');
    late final String executable;
    late final List<String> args;

    if (isExe) {
      executable = serverPath;
      args = [];
    } else {
      executable = await _findPython();
      args = ['-u', serverPath];
    }

    debugPrint('[PyProc] starting: $executable ${args.join(" ")}');
    _process = await Process.start(executable, args, mode: ProcessStartMode.normal);
    debugPrint('[PyProc] started, pid=${_process!.pid}');

    final logDir = Directory('${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}/FFmpeg++');
    if (!logDir.existsSync()) logDir.createSync(recursive: true);
    final logFile = File('${logDir.path}/flutter_stdout.log');
    try { logFile.writeAsStringSync(''); } catch (_) {}
    int lineCount = 0;
    final logSink = logFile.openWrite(mode: FileMode.append);

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      lineCount++;
      final ts = DateTime.now().toIso8601String().substring(11, 23);
      final preview = line.length > 300 ? line.substring(0, 300) : line;
      logSink.writeln('[$ts] #$lineCount: $preview');
      _handleLine(line);
    }, onError: (e) {
      logSink.writeln('[ERROR] $e');
      _errorController.add('stdout error: $e');
    }, onDone: () {
      logSink.writeln('[DONE] stdout closed after $lineCount lines');
      logSink.close();
    });
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      debugPrint('[PyProc] stderr: $line');
      _errorController.add(line);
    });

    _process!.exitCode.then((code) {
      debugPrint('[PyProc] EXITED with code=$code');
      _errorController.add('server process exited with code $code');
      _process = null;
    });
  }

  void _sendRequest(Map<String, dynamic> req) {
    if (_isDllMode) {
      if (_bridge == null) return;
      _bridge!.request(jsonEncode(req));
    } else {
      if (_process == null) return;
      _process!.stdin.writeln(jsonEncode(req));
      _process!.stdin.flush();
    }
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
    if (_isDllMode) {
      _pollTimer?.cancel();
      _pollTimer = null;
      if (_bridge != null) {
        try {
          _bridge!.shutdown();
        } catch (_) {}
        _bridge = null;
      }
    } else {
      if (_process == null) return;
      try {
        final Map<String, dynamic> req = {'id': 'shutdown_${++_reqCounter}', 'action': 'shutdown'};
        _process!.stdin.writeln(jsonEncode(req));
        await _process!.stdin.flush();
        await Future.delayed(const Duration(milliseconds: 500));
        _process?.kill();
      } catch (_) {}
      _process = null;
    }
  }

  void dispose() {
    shutdown();
    _responseController.close();
    _errorController.close();
  }

  Future<String> _findPython() async {
    try {
      final result = await Process.run('python', ['--version']);
      if (result.exitCode == 0) return 'python';
    } catch (_) {}
    try {
      final result = await Process.run('python3', ['--version']);
      if (result.exitCode == 0) return 'python3';
    } catch (_) {}
    return 'python';
  }
}
