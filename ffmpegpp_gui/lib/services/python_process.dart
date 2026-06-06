import 'dart:async';
import 'dart:convert';
import 'dart:io';


class PythonProcessManager {
  Process? _process;
  final _responseController = StreamController<Map<String, dynamic>>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _pendingCompleters = <String, Completer<Map<String, dynamic>>>{};
  int _reqCounter = 0;

  Stream<Map<String, dynamic>> get responses => _responseController.stream;
  Stream<String> get errors => _errorController.stream;
  bool get isRunning => _process != null;

  /// 启动后端（支持 .exe 直接运行 或 .py 通过 python 解释）
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

    _process = await Process.start(executable, args, mode: ProcessStartMode.normal);

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onStdoutLine, onError: (e) {
      _errorController.add('stdout error: $e');
    });

    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
_errorController.add(line);
    });

    _process!.exitCode.then((code) {
      _process = null;
    });
  }

  Future<Map<String, dynamic>> request(String action, [Map<String, dynamic>? params]) async {
    return _doRequest(action, params, 120);
  }

  Future<Map<String, dynamic>> requestWithTimeout(String action, int timeoutSec, [Map<String, dynamic>? params]) async {
    return _doRequest(action, params, timeoutSec);
  }

  Future<Map<String, dynamic>> _doRequest(String action, Map<String, dynamic>? params, int timeoutSec) async {
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

  Future<Map<String, dynamic>> requestWithId(String id, String action, [Map<String, dynamic>? params]) async {
    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleters[id] = completer;
    final Map<String, dynamic> req = {'id': id, 'action': action};
    if (params != null) req['params'] = params;
    _process!.stdin.writeln(jsonEncode(req));
    await _process!.stdin.flush();
    return completer.future.timeout(const Duration(seconds: 3600), onTimeout: () {
      _pendingCompleters.remove(id);
      return {'id': id, 'success': false, 'error': '超时'};
    });
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

  void _onStdoutLine(String line) {
    try {
      final obj = jsonDecode(line) as Map<String, dynamic>;
      if (obj.containsKey('type')) {
        _responseController.add(obj);
      } else if (obj.containsKey('id')) {
        final id = obj['id'] as String;
        final completer = _pendingCompleters.remove(id);
        if (completer != null) completer.complete(obj);
      }
    } catch (e) {
      _errorController.add('stdout parse error: $e');
    }
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
