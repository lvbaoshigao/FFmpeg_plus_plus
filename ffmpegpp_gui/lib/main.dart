import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'app.dart';

/// 全局启动日志（供其他模块写入）
final List<String> startupLog = [];
final _t0 = DateTime.now();
void startupLogAdd(String msg) {
  final elapsed = DateTime.now().difference(_t0).inMilliseconds;
  final line = '[${elapsed}ms] $msg';
  debugPrint(line);
  startupLog.add(line);
}
void startupLogFlush() {
  try {
    File('${Directory(Platform.resolvedExecutable).parent.path}/startup.log')
        .writeAsStringSync(startupLog.join('\n'));
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  startupLogAdd('1-FlutterBinding');

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _logCrash(details.exceptionAsString(), details.stack?.toString() ?? '');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _logCrash(error.toString(), stack.toString());
    return true;
  };

  await windowManager.ensureInitialized();
  startupLogAdd('2-windowManager init');
  await windowManager.setMinimumSize(const Size(1100, 700));
  await windowManager.setSize(const Size(1280, 820));
  await windowManager.setTitle('FFmpeg++');
  await windowManager.center();
  startupLogAdd('3-window configured');

  final serverPath = _findServer();
  startupLogAdd('4-server path: $serverPath');

  final appState = AppState();
  startupLogAdd('5-AppState created');
  await appState.init(serverPath);
  startupLogAdd('8-AppState.init done');

  startupLogFlush();
  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const FfmpegppApp(),
    ),
  );
  startupLogAdd('9-runApp done');
}

String _findServer() {
  final exeDir = Directory(Platform.resolvedExecutable).parent;
  final candidates = <String>[
    '${exeDir.path}/server.dist/server.exe',
    '${exeDir.path}/../server.dist/server.exe',
    '${exeDir.path}/../../server.dist/server.exe',
    '${exeDir.path}/server.exe',
    '${exeDir.path}/../server.exe',
    '${exeDir.path}/../../server.exe',
    '${exeDir.path}/../../../server.exe',
    'server.dist/server.exe',
    'server.exe',
    '../server.exe',
    'ffmpeg_video_tool/server.py',
    'server.py',
  ];

  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) {
      return f.absolute.path;
    }
  }
  return 'server.py';
}

void _logCrash(String error, String stack) {
  try {
    File('crash_${DateTime.now().millisecondsSinceEpoch}.log')
        .writeAsStringSync('Error: $error\n\nStack:\n$stack');
  } catch (_) {}
}
