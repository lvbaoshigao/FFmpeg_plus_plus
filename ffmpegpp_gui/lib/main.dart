import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'services/integrity.dart';
import 'app.dart';

/// 日志目录（用户可写，避免 Program Files 权限问题）— 缓存避免重复创建
final String _logDir = () {
  final dir = '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}/FFmpeg++';
  Directory(dir).createSync(recursive: true);
  return dir;
}();

/// 写启动日志到文件
void _startupLog(String msg) {
  try {
    final f = File('$_logDir/startup.log');
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    f.writeAsStringSync('[$ts] $msg\n', mode: FileMode.append);
  } catch (_) {}
}

void main() async {
  // 清空旧日志
  try {
    File('$_logDir/startup.log').writeAsStringSync('');
  } catch (_) {}

  _startupLog('=== APP START ===');

  // 杀残留进程 — fire-and-forget，不阻塞启动
  _killOldProcesses();

  WidgetsFlutterBinding.ensureInitialized();
  _startupLog('1-Binding OK');

  // 完整性校验 — 后台执行，失败不退出
  IntegrityCheck.verify().then((ok) {
    _startupLog('IntegrityCheck: ${ok ? "PASS" : "FAIL"}');
  });

  FlutterError.onError = (details) {
    _startupLog('FLUTTER ERROR: ${details.exceptionAsString()}');
    FlutterError.presentError(details);
    _logCrash(details.exceptionAsString(), details.stack?.toString() ?? '');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _startupLog('PLATFORM ERROR: $error');
    _logCrash(error.toString(), stack.toString());
    return true;
  };

  _startupLog('2-ErrorHandlers OK');

  // 并行执行：窗口初始化 + 字体加载（互相无依赖）
  final serverPath = _findServer();
  _startupLog('3-server: $serverPath');

  await Future.wait([
    _initWindow(),
    _loadCustomFonts(),
  ]);
  _startupLog('4-window+fonts OK');

  final appState = AppState();
  _startupLog('5-AppState created');
  await appState.init(serverPath);
  _startupLog('6-AppState.init OK');

  _startupLog('7-calling runApp');
  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const FfmpegppApp(),
    ),
  );
  _startupLog('8-runApp done');
}

Future<void> _initWindow() async {
  await windowManager.ensureInitialized();
  await Future.wait([
    windowManager.setMinimumSize(const Size(1100, 700)),
    windowManager.setSize(const Size(1280, 820)),
    windowManager.setTitle('FFmpeg++'),
  ]);
  await windowManager.center();
}

String _findServer() {
  final exeDir = Directory(Platform.resolvedExecutable).parent;
  _startupLog('5a-exeDir: ${exeDir.path}');

  // 优先搜索 ffmpegpp.dll（DLL 模式，更快）
  var dir = exeDir;
  for (var i = 0; i < 8; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}ffmpegpp.dll');
    if (candidate.existsSync()) {
      _startupLog('5b-FOUND DLL: ${candidate.absolute.path}');
      return candidate.absolute.path;
    }
    dir = dir.parent;
  }

  // 回退搜索 server.exe（EXE 模式，向后兼容）
  dir = exeDir;
  for (var i = 0; i < 8; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}server.exe');
    if (candidate.existsSync()) {
      _startupLog('5b-FOUND EXE: ${candidate.absolute.path}');
      return candidate.absolute.path;
    }
    dir = dir.parent;
  }

  _startupLog('5b-NOT FOUND');
  return '${exeDir.path}${Platform.pathSeparator}ffmpegpp.dll';
}

/// 杀掉残留的旧进程（管理员权限运行的 _cache / HD_ / server）— fire-and-forget
void _killOldProcesses() {
  const names = ['._cache_ffmpegpp_gui.exe', 'HD_ffmpegpp_gui.exe', 'HD_server.exe'];
  for (final name in names) {
    Process.run('taskkill', ['/F', '/IM', name], runInShell: true).ignore();
  }
}

/// 从用户数据目录 fonts/ 加载所有 .ttf/.otf 字体（启动时调用）
Future<void> _loadCustomFonts() async {
  try {
    final fontsDir = Directory('$_logDir/fonts');
    if (!fontsDir.existsSync()) {
      // 兼容旧版：也检查 exe 同级 fonts/ 目录
      final exeDir = Directory(Platform.resolvedExecutable).parent;
      final legacyDir = Directory('${exeDir.path}/fonts');
      if (!legacyDir.existsSync()) return;
      await _loadFontsFromDir(legacyDir);
      return;
    }
    await _loadFontsFromDir(fontsDir);
  } catch (_) {}
}

Future<void> _loadFontsFromDir(Directory dir) async {
  for (final file in dir.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('.ttf') && !name.endsWith('.otf')) continue;
    final fontName = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    try {
      final loader = FontLoader(fontName);
      final bytes = await file.readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  }
}

void _logCrash(String error, String stack) {
  try {
    File('$_logDir/crash.log').writeAsStringSync('Error: $error\n\nStack:\n$stack');
  } catch (_) {}
}
