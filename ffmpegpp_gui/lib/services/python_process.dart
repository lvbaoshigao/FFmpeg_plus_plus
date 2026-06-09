import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';


class PythonProcessManager {
  Process? _process;
  final _responseController = StreamController<Map<String, dynamic>>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _pendingCompleters = <String, Completer<Map<String, dynamic>>>{};
  int _reqCounter = 0;

  // ready 消息缓存 + Completer
  Map<String, dynamic>? _cachedReady;
  Completer<Map<String, dynamic>>? _readyCompleter;

  Stream<Map<String, dynamic>> get responses => _responseController.stream;
  Stream<String> get errors => _errorController.stream;
  bool get isRunning => _process != null;

  Future<Map<String, dynamic>> waitForReady({Duration timeout = const Duration(seconds: 30)}) async {
    if (_cachedReady != null) return _cachedReady!;
    if (_readyCompleter == null) return {'type': 'timeout'};
    return _readyCompleter!.future.timeout(timeout, onTimeout: () {
      return {'type': 'timeout'};
    });
  }

  Future<void> start(String serverPath) async {
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

    _readyCompleter = Completer<Map<String, dynamic>>();
    debugPrint('[PyProc] starting: $executable ${args.join(" ")}');
    _process = await Process.start(executable, args, mode: ProcessStartMode.normal);
    debugPrint('[PyProc] started, pid=${_process!.pid}');

    // 写文件日志到 exe 目录，确认 stdout 是否真的收到数据
    final logFile = File('${Directory(Platform.resolvedExecutable).parent.path}/flutter_stdout.log');
    logFile.writeAsStringSync('');
    int lineCount = 0;

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      lineCount++;
      final ts = DateTime.now().toIso8601String().substring(11, 23);
      final preview = line.length > 300 ? line.substring(0, 300) : line;
      logFile.writeAsStringSync('[$ts] #$lineCount: $preview\n', mode: FileMode.append);
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
        _errorController.add('stdout parse error: $e');
      }
    }, onError: (e) {
      logFile.writeAsStringSync('[ERROR] $e\n', mode: FileMode.append);
      _errorController.add('stdout error: $e');
    }, onDone: () {
      logFile.writeAsStringSync('[DONE] stdout closed after $lineCount lines\n', mode: FileMode.append);
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

  Future<Map<String, dynamic>> request(String action, [Map<String, dynamic>? params]) async {
    return _doRequest(action, params, 120);
  }

  Future<Map<String, dynamic>> requestWithTimeout(String action, int timeoutSec, [Map<String, dynamic>? params]) async {
    return _doRequest(action, params, timeoutSec);
  }

  Future<Map<String, dynamic>> requestWithId(String id, String action, [Map<String, dynamic>? params]) async {
    if (_process == null) {
      return {'id': id, 'success': false, 'error': '后端进程未启动'};
    }
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[id] = completer;

    final Map<String, dynamic> req = {'id': id, 'action': action};
    if (params != null) req['params'] = params;

    _process!.stdin.writeln(jsonEncode(req));
    await _process!.stdin.flush();

    return completer.future.timeout(
      const Duration(seconds: 3600),
      onTimeout: () {
        _pendingCompleters.remove(id);
        return {'id': id, 'success': false, 'error': '超时'};
      },
    );
  }

  Future<Map<String, dynamic>> _doRequest(String action, Map<String, dynamic>? params, int timeoutSec) async {
    if (_process == null) {
      return {'success': false, 'error': '后端进程未启动'};
    }
    final id = 'req_${++_reqCounter}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[id] = completer;

    final Map<String, dynamic> req = {'id': id, 'action': action};
    if (params != null) req['params'] = params;

    _process!.stdin.writeln(jsonEncode(req));
    await _process!.stdin.flush();

    return completer.future.timeout(
      Duration(seconds: timeoutSec),
      onTimeout: () {
        _pendingCompleters.remove(id);
        return {'id': id, 'success': false, 'error': '请求超时 (${timeoutSec}s)'};
      },
    );
  }

  void cancel() {
    if (_process == null) return;
    final Map<String, dynamic> req = {'id': 'cancel_${++_reqCounter}', 'action': 'cancel'};
    _process!.stdin.writeln(jsonEncode(req));
    _process!.stdin.flush();
  }

  Future<void> shutdown() async {
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
