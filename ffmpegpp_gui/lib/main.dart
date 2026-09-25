import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, ByteData;
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'platform/app_platform.dart';
import 'providers/app_state.dart';
import 'services/gpu_info.dart';
import 'services/integrity.dart';
// 高刷新率（Android 专用）：在支持 90/120/144Hz 的屏幕上按设置请求最高刷新率
import 'services/refresh_rate.dart';
import 'widgets/font_picker.dart';
// shaderGlassSupported：玻璃 shader 是否被当前后端支持（Skia/Windows 为 false）。
// 用于门控下面的 shader 预加载，避免在永远走不到 shader 分支的平台上白编译。
import 'widgets/liquid_glass_fallback.dart';

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

  // 完整性校验 — 后台执行，失败不退出（策略：写日志 + 记录原因，不阻断启动）
  IntegrityCheck.verify().then((ok) {
    _startupLog('IntegrityCheck(assets): ${ok ? "PASS" : "FAIL"}'
        '${ok ? "" : " - ${IntegrityCheck.lastFailure}"}');
  });
  IntegrityCheck.verifyCritical().then((ok) {
    _startupLog('IntegrityCheck(critical): ${ok ? "PASS" : "FAIL"}'
        '${ok ? "" : " - ${IntegrityCheck.lastFailure}"}');
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
  // 预加载液态玻璃 shader：Impeller 平台（移动端 / macOS / 开启
  // --enable-impeller 的 Windows）上首块玻璃不用等异步加载，避免闪烁。
  //
  // 必须用 shaderGlassSupported 门控：Skia 平台（Windows 默认）下
  // `ImageFilter.isShaderFilterSupported == false`，玻璃渲染**永远不会走到**
  // shader 分支（见 liquid_glass_fallback.gpuGlassEnabledOf），但
  // FragmentProgram.fromAsset 仍会真的加载并编译 SkSL 运行时效应 —— 一份
  // 永远用不到的编译产物白占内存。（原注释称「加载即被短路，无开销」是错的：
  // 短路的是渲染路径，不是这次预加载本身。）
  //
  // 为什么这一处**不**受「关闭预加载」门控：它必须在 `runApp` 之前发起，而此刻
  // 配置还没读出来（`AppState.init` 要等首帧之后才 await）；而它编译的是首帧过去
  // 之后马上就会用到的 shader，推迟到 init 之后再加载会真的闪一下（先走无 shader 的
  // 回退路径再切换）。代价侧：一次编译、一个程序对象，且在**不支持 shader 玻璃的
  // 平台整块跳过** —— 而「关闭预加载」主要使用的 Windows 桌面端正是这一类。
  if (shaderGlassSupported) {
    unawaited(OCLiquidGlassGroup.precacheShader().catchError((_) {}));
  }
  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const FfmpegppApp(),
    ),
  );
  _startupLog('8-runApp done');

  // ── 首帧后的「必需加载」：自定义字体 ──
  // 只有它是无条件执行的：不做就是缺字体（文字回退到系统字体），属于功能而非预热，
  // 所以不受「关闭预加载」门控。推迟到首帧后是为了避开「读数 MB 字体字节 +
  // 后端 dlopen + 壁纸解码」叠加造成的启动内存峰值。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_loadCustomFonts());
  });

  // 后台初始化后端，UI 先显示加载画面。等待首帧完成后才启动：
  // 首帧期间只保留 Flutter 引擎 + Splash，避免配置读取、后端 dlopen、
  // 自定义字体读取同时发生，降低启动峰值内存并让窗口及时显示。
  await WidgetsBinding.instance.endOfFrame;
  await appState.init(serverPath);
  _startupLog('6-AppState.init OK');

  // ── 纯预热项目的总闸：「关闭预加载」（config.noPreload）──
  // 门控的是「做与不做都不影响功能、只是首次用到时现场付代价」的动作：
  //   * 字体列表枚举（FontPicker.preloadFonts，缓存在静态字段里）
  //   * 壁纸按物理分辨率解码进 ImageCache
  // 这两处此前无条件执行，于是开关只对外壳的页面预热生效、对启动内存几乎没影响。
  // 必须等 `appState.init` 之后才判定：配置要读出来才知道开没开。
  final warmupEnabled = !appState.config.noPreload;
  if (!warmupEnabled) {
    _startupLog('6b-warmup: 关闭预加载已开启，跳过字体列表 / 壁纸预热');
  }

  // 高刷新率：在支持 90 / 120 / 144Hz 的设备上按设置请求屏幕的最高刷新率。
  // 必须等到窗口已 attach 之后再调用（原生侧 setFrameRate 作用于已挂载的
  // SurfaceView 的 Surface），所以放在这里而不是 main() 开头。
  // Android 专用，其它平台 no-op。
  // 注意：这不是预热 —— 不调用就真的跑不到高刷，所以不受 warmupEnabled 门控。
  unawaited(RefreshRate.applyEnabled(appState.config.highRefreshRate).then((ok) {
    _startupLog('6a-highRefreshRate: '
        '${appState.config.highRefreshRate ? "max" : "system default"} -> $ok');
  }));

  // 后端就绪后预热：字体列表 + 壁纸解码（进主界面不再卡首帧）。
  // 壁纸那一项内部还会再判一次「有没有配壁纸」。
  if (warmupEnabled) {
    unawaited(_preloadFonts());
    unawaited(_precacheWallpaper(appState));
  }

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
/// 自动降级对每个安装只**主动**执行一次（写入 config.glassAutoTuned）：
/// 之后用户手动重新开启的玻璃样式不会再被自动降级 —— 详见字段注释。
///
/// 各字段的「无模糊」取值（兼容新旧两套样式体系共存期）：
///  - glassEffect（GlassPanel 系非卡片表面）：'liquid'/'blur' → 'none'
///  - cardStyle（卡片）：→ 'flat'（旧消费者=纯色；加载时自动迁移为 'gray'，
///    新 AppCard 也按纯色渲染）
///  - navStyle/pillStyle（移动端菜单栏/药丸，新四值体系）：→ 'gray'
///  - menuStyle（桌面端左侧菜单栏/顶部菜单栏，新四值体系）：→ 'gray'
Future<void> _autoTuneGlass(AppState state) async {
  try {
    final name = await GpuInfo.detectName();
    if (!GpuInfo.isSoftwareRendered(name)) return;
    final c = state.config;
    final needsGlass = c.glassEffect == 'liquid' || c.glassEffect == 'blur';
    final needsCard = c.cardStyle != 'flat';
    final needsNav = c.navStyle == 'liquid' || c.navStyle == 'blur';
    final needsPill = c.pillStyle == 'liquid' || c.pillStyle == 'blur';
    final needsMenu = c.menuStyle == 'liquid' || c.menuStyle == 'blur';
    if (!needsGlass && !needsCard && !needsNav && !needsPill && !needsMenu) return;
    // 自动降级只主动执行一次：若上次已降级、而现在玻璃样式又是开启状态，
    // 说明用户在设置里手动重新开启了 —— 尊重用户选择，不再每次启动都改回去。
    // （旧行为：每次启动都重新降级，「可在设置中重新开启」的承诺实际不成立。）
    if (c.glassAutoTuned) {
      _startupLog('autoTuneGlass: software GPU ($name) but glass re-enabled by user, skip');
      return;
    }
    state.addLog(
        '检测到软件/基础渲染显卡（$name），已自动关闭玻璃模糊效果（改为纯色）以保证流畅，可在「设置」中重新开启（重新开启后不会再被自动关闭）',
        category: 'info');
    await state.updateConfig((c) {
      if (c.glassEffect == 'liquid' || c.glassEffect == 'blur') c.glassEffect = 'none';
      c.cardStyle = 'flat';
      if (c.navStyle == 'liquid' || c.navStyle == 'blur') c.navStyle = 'gray';
      if (c.pillStyle == 'liquid' || c.pillStyle == 'blur') c.pillStyle = 'gray';
      if (c.menuStyle == 'liquid' || c.menuStyle == 'blur') c.menuStyle = 'gray';
      c.glassAutoTuned = true;
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
    // [FIX L-9] 收紧匹配，避免误杀无关进程（如 "vim ffmpegpp_gui.log"）。
    // 策略：先用 pgrep -f 取候选 PID，再逐个用 ps -o comm= 二次确认其可执行名 basename
    // 确为 ffmpegpp_gui（或 .exe）才 kill；命令里无用户输入，仅常量，无注入风险。
    // 这样既不会误杀 comm 为 vim 的编辑器进程，也无需依赖 grep -v $$ 排除 bash 自身。
    Process.run('bash', ['-c',
      'for p in \$(pgrep -f "ffmpegpp_gui" 2>/dev/null); do '
      '[ "\$p" = "$myPid" ] && continue; '
      'comm=\$(ps -o comm= -p "\$p" 2>/dev/null | tr -d " \\n"); '
      'base=\$(basename "\$comm"); '
      'case "\$base" in '
      'ffmpegpp_gui|ffmpegpp_gui.exe) kill -9 "\$p" 2>/dev/null ;; '
      'esac; '
      'done']).ignore();
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
