import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _logCrash(details.exceptionAsString(), details.stack?.toString() ?? '');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _logCrash(error.toString(), stack.toString());
    return true;
  };

  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(1100, 700));
  await windowManager.setSize(const Size(1280, 820));
  await windowManager.setTitle('FFmpeg++');
  await windowManager.center();

  final serverPath = _findServer();

  final appState = AppState();
  await appState.init(serverPath);

  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const FfmpegppApp(),
    ),
  );
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
    if (f.existsSync()) return f.absolute.path;
  }
  return 'server.py';
}

void _logCrash(String error, String stack) {
  try {
    File('crash_${DateTime.now().millisecondsSinceEpoch}.log')
        .writeAsStringSync('Error: $error\n\nStack:\n$stack');
  } catch (_) {}
}
