import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'services/gpu_info.dart';
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
  // 移动端内存更紧张：24MB / 150 张（原 32MB/200，缩略图 80×45 足够）；
  // 桌面端缩略图均为 80×45 小图、壁纸最多一张物理分辨率大图，48MB 足够
  // （原 64MB，实测占用不到一半）。启动 300-400MB 峰值的一大部分是
  // ImageCache 预留 + 壁纸解码，这里把上限压低。
  if (isMobilePlatform) {
    PaintingBinding.instance.imageCache.maximumSizeBytes = 24 << 20; // 24MB
    PaintingBinding.instance.imageCache.maximumSize = 150; // 最多 150 张
  } else {
    PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20; // 48MB
    PaintingBinding.instance.imageCache.maximumSize = 300; // 最多 300 张
  }
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

  // 并行执行：窗口初始化（仅桌面）+ 字体加载（互相无依赖）。
  // 注意：自定义字体枚举改为首帧后（见 _loadCustomFonts 调用处），
  // 避免启动瞬间把用户 fonts/ 目录里所有 .ttf/.otf 全量读进内存——
  // 这是启动 300-400MB 峰值的主要来源之一。首帧后按需加载不阻塞首屏。
  final serverPath = _findServer();
  _startupLog('3-server: $serverPath');

  if (!isMobilePlatform) {
    await _initWindow();
  }
  _startupLog('4-window OK');

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

  // ── 启动预加载（首帧之后后台并行，不阻塞初始化，压低启动内存峰值） ──
  // 字体加载 + 字体列表预热都推迟到首帧后：启动瞬间只做窗口 + 后端初始化，
  // 避免「读 fonts/ 目录全部字节 + 壁纸按物理分辨率解码 + 后端 dlopen + 字
  // 体枚举」叠加导致 300-400MB 峰值。首帧后摊到空闲期完成。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_loadCustomFonts());
    unawaited(_preloadFonts());
  });

  // 后台初始化后端，UI 先显示加载画面。等待首帧完成后才启动：
  // 首帧期间只保留 Flutter 引擎 + Splash，避免配置读取、后端 dlopen、
  // 自定义字体读取同时发生，降低启动峰值内存并让窗口及时显示。
  await WidgetsBinding.instance.endOfFrame;
  await appState.init(serverPath);
  _startupLog('6-AppState.init OK');

  // 后端就绪后预热壁纸解码（进主界面不再卡首帧）——仅在配置了壁纸时
  unawaited(_precacheWallpaper(appState));

  // 低配/软件渲染显卡自动降级玻璃效果（后台探测，不阻塞启动）
  unawaited(_autoTuneGlass(appState));
}

/// 低配/软件渲染显卡自动降级玻璃效果。
///
/// BackdropFilter 高斯模糊依赖 GPU 光栅化。在软件渲染环境（llvmpipe /
/// Microsoft Basic Render Driver / 远程桌面基础适配器）上，每块玻璃面板都是
/// CPU 光栅化，低端设备会明显卡顿。探测到这类环境时，把所有会触发模糊的
/// 表面样式一次性切到纯色，写入配置并记录日志；用户可在设置里手动重新开启。
/// 真实 GPU 环境不受影响。
///
/// 各字段的「无模糊」取值（兼容新旧两套样式体系共存期）：
///  - glassEffect（GlassPanel 系非卡片表面）：'liquid'/'blur' → 'none'
///  - cardStyle（卡片）：→ 'flat'（旧消费者=纯色；加载时自动迁移为 'gray'，
///    新 AppCard 也按纯色渲染）
///  - navStyle/pillStyle（移动端菜单栏/药丸，新四值体系）：→ 'gray'
Future<void> _autoTuneGlass(AppState state) async {
  try {
    final name = await GpuInfo.detectName();
    if (!GpuInfo.isSoftwareRendered(name)) return;
    final c = state.config;
    final needsGlass = c.glassEffect == 'liquid' || c.glassEffect == 'blur';
    final needsCard = c.cardStyle != 'flat';
    final needsNav = c.navStyle == 'liquid' || c.navStyle == 'blur';
    final needsPill = c.pillStyle == 'liquid' || c.pillStyle == 'blur';
    if (!needsGlass && !needsCard && !needsNav && !needsPill) return;
    state.addLog(
        '检测到软件/基础渲染显卡（$name），已自动关闭玻璃模糊效果（改为纯色）以保证流畅，可在「设置」中重新开启',
        category: 'info');
    await state.updateConfig((c) {
      if (c.glassEffect == 'liquid' || c.glassEffect == 'blur') c.glassEffect = 'none';
      c.cardStyle = 'flat';
      if (c.navStyle == 'liquid' || c.navStyle == 'blur') c.navStyle = 'gray';
      if (c.pillStyle == 'liquid' || c.pillStyle == 'blur') c.pillStyle = 'gray';
      return c;
    });
    _startupLog('autoTuneGlass: disabled glass for software GPU: $name');
  } catch (e) {
    _startupLog('autoTuneGlass error: $e');
  }
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
  if (Platform.isWindows || Platform.isMacOS) {
    // Windows / macOS：使用系统默认标题栏（含系统窗口按钮与拖拽/缩放）。
    // Windows 上显式设置是幂等的：即使插件内部残留 hidden 状态也能恢复标题栏。
    // macOS 此前走 hidden + Flutter 自绘标题栏，实测有丢失风险，统一改用系统默认。
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    // 运行期防御：标题栏样式设置后立即二次确认一次（时序竞争下首次
    // DwmExtendFrameIntoClientArea/SetWindowPos 可能发生在窗口尚未就绪时）。
    // 真双保险在原生侧 win32_window.cpp 的 EnsureCaptionPresent（WM_ACTIVATE/
    // WM_STYLECHANGED 时强制补回 WS_CAPTION），这里只是尽早把插件状态拉齐。
    unawaited(Future.delayed(const Duration(milliseconds: 400), () async {
      try {
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      } catch (_) {}
    }));
  } else {
    // Linux：自定义标题栏（Flutter 自绘 CSD，见 app.dart _buildCsdTitleBar）
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
  try {
    if (isMobilePlatform) {
      // 移动端：字体由设置页 _copyToAppDir 复制到「应用文档目录/FFmpeg++/fonts」，
      // 必须与那里保持一致 —— 之前这里直接 return（不加载）且 _logDir 指向的是
      // systemTemp 缓存目录（会被系统清理），导致安卓重启后字体永远回退系统字体。
      final doc = await getApplicationDocumentsDirectory();
      final fontsDir = Directory('${doc.path}${_sep}FFmpeg++${_sep}fonts');
      if (!fontsDir.existsSync()) return;
      await _loadFontsFromDir(fontsDir);
      return;
    }
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
