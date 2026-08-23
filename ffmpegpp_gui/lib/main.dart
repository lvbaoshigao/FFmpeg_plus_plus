import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'services/integrity.dart';
import 'platform/app_platform.dart';
import 'widgets/font_picker.dart';
import 'app.dart';

final String _sep = Platform.pathSeparator;

/// 日志目录（用户可写，避免 Program Files 权限问题）— 缓存避免重复创建
final String _logDir = () {
  final String base;
  if (Platform.isAndroid) {
    // Android 无 HOME/APPDATA；systemTemp 即应用缓存目录（可写）
    base = Directory.systemTemp.path;
  } else if (Platform.isWindows) {
    base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
  } else if (Platform.isMacOS) {
    base = '${Platform.environment['HOME'] ?? '/tmp'}/Library/Application Support';
  } else {
    base = Platform.environment['XDG_DATA_HOME'] ??
        '${Platform.environment['HOME'] ?? '/tmp'}$_sep.local${_sep}share';
  }
  final dir = '$base${_sep}FFmpeg++';
  Directory(dir).createSync(recursive: true);
  return dir;
}();

/// 写启动日志到文件
void _startupLog(String msg) {
  try {
    final f = File('$_logDir${_sep}startup.log');
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    f.writeAsStringSync('[$ts] $msg\n', mode: FileMode.append);
  } catch (_) {}
}

void main() async {
  // 清空旧日志
  try {
    File('$_logDir${_sep}startup.log').writeAsStringSync('');
  } catch (_) {}

  _startupLog('=== APP START ===');

  // 杀残留进程 — fire-and-forget，不阻塞启动（移动端无此概念，跳过）
  if (!isMobilePlatform) {
    _killOldProcesses();
  }

  WidgetsFlutterBinding.ensureInitialized();
  _startupLog('1-Binding OK');

  // ── 内存优化：限制图片缓存上限，避免大量缩略图撑爆内存 ──
  PaintingBinding.instance.imageCache.maximumSizeBytes = 96 << 20; // 96MB
  PaintingBinding.instance.imageCache.maximumSize = 600; // 最多 600 张
  _startupLog('1a-ImageCache capped');

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

  // 并行执行：窗口初始化 + 字体加载（互相无依赖）；移动端无窗口
  final serverPath = _findServer();
  _startupLog('3-server: $serverPath');

  if (isMobilePlatform) {
    await _loadCustomFonts();
  } else {
    await Future.wait([
      _initWindow(),
      _loadCustomFonts(),
    ]);
  }
  _startupLog('4-window+fonts OK');

  final appState = AppState();
  _startupLog('5-AppState created');

  _startupLog('7-calling runApp');
  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const FfmpegppApp(),
    ),
  );
  _startupLog('8-runApp done');

  // ── 启动预加载（后台并行，不阻塞初始化） ──
  // 预热字体列表（FontPicker 首次打开会枚举系统字体，很慢；提前缓存）
  // 与后端初始化并行，Splash 动画期间完成，进入主界面后字体选择器秒开。
  if (!isMobilePlatform) {
    unawaited(_preloadFonts());
  }

  // 后台初始化后端，UI 先显示加载画面
  await appState.init(serverPath);
  _startupLog('6-AppState.init OK');

  // 后端就绪后预热壁纸解码（进主界面不再卡首帧）——仅在配置了壁纸时
  unawaited(_precacheWallpaper(appState));
}

/// 后台预热字体列表（仅一次，缓存在 FontPicker 静态字段中）。
Future<void> _preloadFonts() async {
  try {
    await FontPicker.preloadFonts();
    _startupLog('9-fonts preloaded');
  } catch (e) {
    _startupLog('9-fonts preload error: $e');
  }
}

/// 预热壁纸到 ImageCache（按 app.dart 同款 cacheWidth 限制解码），
/// 避免进入主界面瞬间解码大图卡顿。
Future<void> _precacheWallpaper(AppState state) async {
  try {
    final bg = state.config.backgroundImage;
    if (bg.isEmpty || !File(bg).existsSync()) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    final provider = wallpaperImageProvider(bg, size.width, size.height, view.devicePixelRatio);
    // 触发解码并等待完成，使图片进入 ImageCache（后续同参数请求直接命中）
    final stream = provider.resolve(ImageConfiguration.empty);
    final done = Completer<void>();
    late ImageStreamListener listener;
    listener = ImageStreamListener((_, _) {
      if (!done.isCompleted) done.complete();
    }, onError: (_, _) {
      if (!done.isCompleted) done.complete();
    });
    stream.addListener(listener);
    await done.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    stream.removeListener(listener);
    _startupLog('9b-wallpaper precached');
  } catch (e) {
    _startupLog('9b-wallpaper precache error: $e');
  }
}

Future<void> _initWindow() async {
  await windowManager.ensureInitialized();
  if (!Platform.isWindows) {
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
  }
  await Future.wait([
    windowManager.setMinimumSize(const Size(1100, 700)),
    windowManager.setSize(const Size(1280, 820)),
    windowManager.setTitle('FFmpeg++'),
  ]);
  await windowManager.center();
}

String _findServer() {
  // Android：libffmpegpp.so 随 APK 打包在 native 库目录，直接用库名加载
  // （DynamicLibrary.open('libffmpegpp.so') 会自动在 APK lib 目录中解析）。
  if (Platform.isAndroid) {
    return 'libffmpegpp.so';
  }
  final exeDir = Directory(Platform.resolvedExecutable).parent;
  _startupLog('5a-exeDir: ${exeDir.path}');

  // 仅搜索 exe 目录和上一级目录（防止 DLL 劫持）
  const maxSearchDepth = 2;
  final libName = Platform.isWindows ? 'ffmpegpp.dll'
      : Platform.isMacOS ? 'libffmpegpp.dylib'
      : 'libffmpegpp.so';

  var dir = exeDir;
  for (var i = 0; i < maxSearchDepth; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}$libName');
    if (candidate.existsSync()) {
      _startupLog('5b-FOUND LIB: ${candidate.absolute.path}');
      return candidate.absolute.path;
    }
    // Also check lib/ subdirectory (Linux bundle structure)
    final libSubdir = File('${dir.path}${Platform.pathSeparator}lib${Platform.pathSeparator}$libName');
    if (libSubdir.existsSync()) {
      _startupLog('5b-FOUND LIB: ${libSubdir.absolute.path}');
      return libSubdir.absolute.path;
    }
    dir = dir.parent;
  }

  _startupLog('5b-NOT FOUND');
  return '${exeDir.path}${Platform.pathSeparator}$libName';
}

/// 杀掉残留的旧进程 — fire-and-forget
void _killOldProcesses() {
  if (Platform.isWindows) {
    const names = ['._cache_ffmpegpp_gui.exe', 'HD_ffmpegpp_gui.exe'];
    for (final name in names) {
      Process.run('taskkill', ['/F', '/IM', name], runInShell: true).ignore();
    }
  } else {
    final myPid = pid.toString();
    // macOS 的 BSD xargs 不支持 -r（GNU 专属）；去掉后没有匹配项时 xargs 仍会
    // 执行一次 kill，从而把 "kill" 本身当参数——这里改用 pgrep 直接输出 PID 再逐个 kill，
    // 避免依赖平台差异。命令行不可拼接用户输入，仅常量，无注入风险。
    // 注意：Dart 字符串里的 $ 需转义——$myPid 是想要的插值，
    // 但 bash 的 $(...) 命令替换和 "$p" 里的 $ 必须写成 \$( 和 \$p。
    // grep -v $$：执行该命令的 bash -c 自身 cmdline 也包含 "ffmpegpp_gui"，
    // 必须一并排除，否则清理旧进程时会把正在运行的这条命令一起 kill 掉。
    Process.run('bash', ['-c', 'for p in \$(pgrep -f ffmpegpp_gui | grep -v $myPid | grep -v \$\$); do kill -9 "\$p" 2>/dev/null; done']).ignore();
  }
}

/// 从用户数据目录 fonts/ 加载所有 .ttf/.otf 字体（启动时调用）
Future<void> _loadCustomFonts() async {
  // Android 使用系统字体，无自定义字体目录
  if (isMobilePlatform) return;
  try {
    final fontsDir = Directory('$_logDir${_sep}fonts');
    if (!fontsDir.existsSync()) {
      // 兼容旧版：也检查 exe 同级 fonts/ 目录
      final exeDir = Directory(Platform.resolvedExecutable).parent;
      final legacyDir = Directory('${exeDir.path}${_sep}fonts');
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
    File('$_logDir${_sep}crash.log').writeAsStringSync('Error: $error\n\nStack:\n$stack');
  } catch (_) {}
}
