import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'services/integrity.dart';
import 'app.dart';

/// 写启动日志到文件
void _startupLog(String msg) {
  try {
    final exeDir = Directory(Platform.resolvedExecutable).parent;
    final f = File('${exeDir.path}/startup.log');
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    f.writeAsStringSync('[$ts] $msg\n', mode: FileMode.append);
  } catch (_) {}
}

void main() async {
  // 清空旧日志
  try {
    final exeDir = Directory(Platform.resolvedExecutable).parent;
    File('${exeDir.path}/startup.log').writeAsStringSync('');
  } catch (_) {}

  _startupLog('=== APP START ===');
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

  final serverPath = _findServer();
  _startupLog('5-server: $serverPath');

  final appState = AppState();
  _startupLog('6-AppState created');
  await appState.init(serverPath);
  _startupLog('7-AppState.init OK');

  _startupLog('8-calling runApp');
  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const FfmpegppApp(),
    ),
  );
  _startupLog('9-runApp done');
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

void _logCrash(String error, String stack) {
  try {
    final exeDir = Directory(Platform.resolvedExecutable).parent;
    File('${exeDir.path}/crash.log').writeAsStringSync('Error: $error\n\nStack:\n$stack');
  } catch (_) {}
}
