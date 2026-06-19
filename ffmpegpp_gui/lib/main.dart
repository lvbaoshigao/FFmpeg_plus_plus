import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'services/integrity.dart';
import 'app.dart';

/// 日志目录（用户可写，避免 Program Files 权限问题）
String get _logDir {
  final dir = '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}/FFmpeg++';
  Directory(dir).createSync(recursive: true);
  return dir;
}

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

  // 杀掉残留的旧进程（以管理员权限运行的进程）
  await _killOldProcesses();

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

  await windowManager.ensureInitialized();
  _startupLog('3-windowManager.init OK');
  await windowManager.setMinimumSize(const Size(1100, 700));
  await windowManager.setSize(const Size(1280, 820));
  await windowManager.setTitle('FFmpeg++');
  await windowManager.center();
  _startupLog('4-window config OK');

  // 加载 fonts/ 目录下的自定义字体
  await _loadCustomFonts();
  _startupLog('5-fonts loaded');

  final serverPath = _findServer();
  _startupLog('6-server: $serverPath');

  final appState = AppState();
  _startupLog('7-AppState created');
  await appState.init(serverPath);
  _startupLog('8-AppState.init OK');

  _startupLog('9-calling runApp');
  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const FfmpegppApp(),
    ),
  );
  _startupLog('10-runApp done');
}

String _findServer() {
  final exeDir = Directory(Platform.resolvedExecutable).parent;
  _startupLog('5a-exeDir: ${exeDir.path}');

  // 搜索 server.exe：从 exe 目录向上逐级查找
  var dir = exeDir;
  for (var i = 0; i < 8; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}server.exe');
    if (candidate.existsSync()) {
      _startupLog('5b-FOUND: ${candidate.absolute.path}');
      return candidate.absolute.path;
    }
    dir = dir.parent;
  }

  _startupLog('5b-NOT FOUND');
  return '${exeDir.path}${Platform.pathSeparator}server.exe';
}

/// 杀掉残留的旧进程（管理员权限运行的 _cache / HD_ / server）
Future<void> _killOldProcesses() async {
  final names = ['._cache_ffmpegpp_gui.exe', 'HD_ffmpegpp_gui.exe', 'HD_server.exe'];
  for (final name in names) {
    try {
      await Process.run('taskkill', ['/F', '/IM', name], runInShell: true);
    } catch (_) {}
  }
  // 等待进程退出
  await Future.delayed(const Duration(milliseconds: 500));
}

/// 从 exe 同级 fonts/ 目录加载所有 .ttf/.otf 字体（启动时调用）
Future<void> _loadCustomFonts() async {
  try {
    final exeDir = Directory(Platform.resolvedExecutable).parent;
    final fontsDir = Directory('${exeDir.path}/fonts');
    if (!fontsDir.existsSync()) return;
    for (final file in fontsDir.listSync().whereType<File>()) {
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
  } catch (_) {}
}

void _logCrash(String error, String stack) {
  try {
    File('$_logDir/crash.log').writeAsStringSync('Error: $error\n\nStack:\n$stack');
  } catch (_) {}
}
