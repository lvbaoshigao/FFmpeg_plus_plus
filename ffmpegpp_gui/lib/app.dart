import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'models/models.dart';
import 'theme/app_theme.dart';
import 'theme/app_strings.dart';
import 'services/update_service.dart' as updater;
import 'pages/project_page.dart';
import 'pages/queue_page.dart';
import 'pages/command_page.dart';
import 'pages/config_library_page.dart';
import 'pages/settings_page.dart';
import 'pages/log_page.dart';
import 'widgets/sidebar.dart';
import 'widgets/toast.dart';
import 'widgets/mobile_bottom_nav.dart';
import 'platform/app_platform.dart';
import 'services/android_platform.dart';

class FfmpegppApp extends StatefulWidget {
  const FfmpegppApp({super.key});
  @override
  State<FfmpegppApp> createState() => _FfmpegppAppState();
}

class _FfmpegppAppState extends State<FfmpegppApp> {
  /// Android Monet 动态取色的种子色（从系统壁纸读取；null = 不可用）
  int? _monetSeed;

  @override
  void initState() {
    super.initState();
    _loadMonetSeed();
  }

  Future<void> _loadMonetSeed() async {
    if (!isAndroidPlatform) return;
    final seed = await AndroidPlatformBridge.wallpaperPrimaryColor();
    if (mounted && seed != null) {
      setState(() => _monetSeed = seed);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 只用 select 订阅主题相关字段：进度/日志等高频 notify 不再重建 MaterialApp
    // 和两份 ThemeData。
    return Selector<AppState, _ThemeKey>(
      selector: (_, s) => _ThemeKey(
        lang: s.config.language,
        themeColor: s.config.themeColor,
        fontFamily: s.config.fontFamily,
        fontSize: s.config.fontSize,
        fontWeight: s.config.fontWeightValue,
        darkMode: s.darkMode,
        initialized: s.initialized,
        useDynamicColor: isAndroidPlatform && s.config.useDynamicColor,
        monetSeed: _monetSeed,
      ),
      builder: (context, k, _) {
        // Monet 生效时用壁纸种子色覆盖用户主题色（tonalSpot 方案）
        final dynamicSeed = k.useDynamicColor ? (k.monetSeed ?? k.themeColor) : null;
        return MaterialApp(
          key: const ValueKey('app'),
          title: 'FFmpeg++', debugShowCheckedModeBanner: false,
          // 本地化支持：让 showDatePicker/showTimePicker 等系统组件跟随语言
          locale: Locale(k.lang == 'zh' ? 'zh' : 'en'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.light(seedColor: k.themeColor, fontFamily: k.fontFamily,
              fontSize: k.fontSize, fontWeight: k.fontWeight, dynamicSeed: dynamicSeed),
          darkTheme: AppTheme.dark(seedColor: k.themeColor, fontFamily: k.fontFamily,
              fontSize: k.fontSize, fontWeight: k.fontWeight, dynamicSeed: dynamicSeed),
          themeMode: k.darkMode ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) {
            final scale = k.fontSize / 14.0;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            );
          },
          home: k.initialized ? const AppShell() : const _SplashScreen(),
        );
      },
    );
  }
}

/// MaterialApp 重建所需的最小配置快照（相等比较避免无谓重建）。
class _ThemeKey {
  final String lang;
  final int themeColor;
  final String fontFamily;
  final double fontSize;
  final int fontWeight;
  final bool darkMode;
  final bool initialized;
  final bool useDynamicColor;
  final int? monetSeed;
  const _ThemeKey({
    required this.lang,
    required this.themeColor,
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    required this.darkMode,
    required this.initialized,
    required this.useDynamicColor,
    required this.monetSeed,
  });

  @override
  bool operator ==(Object other) =>
      other is _ThemeKey &&
      other.lang == lang &&
      other.themeColor == themeColor &&
      other.fontFamily == fontFamily &&
      other.fontSize == fontSize &&
      other.fontWeight == fontWeight &&
      other.darkMode == darkMode &&
      other.initialized == initialized &&
      other.useDynamicColor == useDynamicColor &&
      other.monetSeed == monetSeed;

  @override
  int get hashCode => Object.hash(lang, themeColor, fontFamily, fontSize, fontWeight, darkMode, initialized, useDynamicColor, monetSeed);
}

/// 启动加载画面：旋转光晕 + 品牌图标 + 进度提示。
/// 期间后台并行执行：后端启动、配置加载、字体/壁纸预加载（见 main.dart）。
class _SplashScreen extends StatefulWidget {
  const _SplashScreen();
  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // 旋转光环 + 品牌图标
          SizedBox(
            width: 148,
            height: 148,
            child: AnimatedBuilder(
              animation: _spin,
              builder: (context, _) {
                final t = _spin.value;
                return Stack(alignment: Alignment.center, children: [
                  // 外圈光晕：旋转的锥形渐变环
                  Transform.rotate(
                    angle: t * 2 * 3.14159,
                    child: Container(
                      width: 148,
                      height: 148,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(
                          startAngle: 0,
                          endAngle: 3.14159 * 2,
                          colors: [
                            scheme.primary.withValues(alpha: 0.0),
                            scheme.primary.withValues(alpha: 0.55),
                            scheme.primary.withValues(alpha: 0.0),
                            scheme.primary.withValues(alpha: 0.0),
                          ],
                          stops: const [0.0, 0.18, 0.35, 1.0],
                        ),
                      ),
                    ),
                  ),
                  // 内圈虚线环（反向旋转，制造层次）
                  Transform.rotate(
                    angle: -t * 3.14159,
                    child: Container(
                      width: 112,
                      height: 112,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.28),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                  // 品牌图标
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: 72,
                      height: 72,
                      color: scheme.surfaceContainerHighest,
                      child: Image.asset('rele/icon.png', width: 72, height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(Icons.play_circle_fill,
                              size: 60, color: scheme.primary)),
                    ),
                  ),
                ]);
              },
            ),
          ),
          const SizedBox(height: 20),
          Text('FFmpeg++',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                  letterSpacing: 0.5)),
          const SizedBox(height: 6),
          Text(isDark ? '正在初始化 FFmpeg 引擎…' : 'Initializing FFmpeg engine…',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 26),
          // 进度条：不确定进度（真实进度由初始化状态驱动）
          SizedBox(
            width: 140,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 4,
                color: scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}
class _AppShellState extends State<AppShell> with WindowListener {
  final _projectPageKey = GlobalKey<ProjectPageState>();
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    // 移动端没有窗口管理器，跳过窗口相关初始化
    if (!isMobilePlatform) {
      windowManager.addListener(this);
      if (!Platform.isWindows) {
        windowManager.isMaximized().then((v) {
          if (mounted) setState(() => _isMaximized = v);
        });
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      state.onTaskFinished = _onTaskFinished;
      if (!isMobilePlatform) {
        _checkPostUpdate();
        _autoCheckUpdate();
      }
      // 主界面首帧后：后台分帧预热其余页面，减少首次切换卡顿
      _prewarmPages();
    });
  }

  Future<void> _autoCheckUpdate() async {
    final state = context.read<AppState>();
    if (!state.config.autoCheckUpdate) return;
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    final isZh = state.config.language == 'zh';
    try {
      final result = await updater.checkForUpdate(preferLanzou: isZh);
      if (!mounted || !result.hasUpdate) return;
      final s = AppStrings.of(state.config.language);
      SettingsPage.showUpdateDialogStatic(context, s, result);
    } catch (_) {
      return;
    }
  }

  Future<void> _checkPostUpdate() async {
    final String? status;
    try {
      status = await updater.checkPostUpdateStatus();
    } catch (_) {
      return;
    }
    if (!mounted || status == null) return;
    if (status == 'updated') {
      final s = AppStrings.of(context.read<AppState>().config.language);
      final scheme = Theme.of(context).colorScheme;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          icon: Icon(Icons.check_circle, color: Colors.green, size: 32),
          title: Text(s.isZh ? '更新完成' : 'Update Complete', style: TextStyle(color: scheme.onSurface)),
          content: Text(
            s.isZh ? 'FFmpeg++ 已更新到 v${updater.currentVersion}' : 'FFmpeg++ updated to v${updater.currentVersion}',
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(s.isZh ? '好的' : 'OK'))],
        ),
      );
    }
    // 'downgraded' — silent, cache already updated
  }

  void _onTaskFinished(String filename, TaskStatus status) {
    if (!mounted) return;
    final s = AppStrings.of(context.read<AppState>().config.language);
    if (status == TaskStatus.completed) {
      showToast(context, s.isZh ? '$filename 已完成' : '$filename completed', type: ToastType.success);
    } else if (status == TaskStatus.failed) {
      showToast(context, s.isZh ? '$filename 处理失败' : '$filename failed', type: ToastType.error);
    }
    if (context.read<AppState>().config.enableSystemNotification) {
      _sendSystemNotification(filename, status);
    }
  }

  void _sendSystemNotification(String filename, TaskStatus status) {
    final isZh = context.read<AppState>().config.language == 'zh';
    final title = 'FFmpeg++';
    final body = status == TaskStatus.completed
        ? (isZh ? '$filename 已完成' : '$filename completed')
        : (isZh ? '$filename 处理失败' : '$filename failed');

    if (Platform.isWindows) {
      final icon = status == TaskStatus.completed ? 'Info' : 'Warning';
      // 文件名可能包含 ' " 等字符，拼接进 PowerShell 单引号字符串会提前终止或注入。
      // 用单引号内替换 '' 的方式转义：PowerShell 单引号字符串转义单引号需写成两个。
      final escTitle = title.replaceAll("'", "''");
      final escBody = body.replaceAll("'", "''");
      final ps = "Add-Type -AssemblyName System.Windows.Forms;"
          "Add-Type -AssemblyName System.Drawing;"
          "\$n=New-Object System.Windows.Forms.NotifyIcon;"
          "\$n.Icon=[System.Drawing.SystemIcons]::Information;"
          "\$n.BalloonTipIcon=[System.Windows.Forms.ToolTipIcon]::$icon;"
          "\$n.BalloonTipTitle='$escTitle';"
          "\$n.BalloonTipText='$escBody';"
          "\$n.Visible=\$true;"
          "\$n.ShowBalloonTip(3000);"
          "Start-Sleep -Milliseconds 3500;"
          "\$n.Dispose()";
      Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]).ignore();
    } else if (Platform.isMacOS) {
      // macOS 没有 notify-send，用 osascript 发系统通知。
      // 文件名里的 " 或 \ 会破坏 AppleScript 字符串并可能注入，先转义。
      final escTitle = title.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final escBody = body.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final script = 'display notification "$escBody" with title "$escTitle"';
      Process.run('osascript', ['-e', script]).ignore();
    } else {
      // notify-send 直接收独立 argv，无需 shell 拼接，天然安全。
      final urgency = status == TaskStatus.completed ? 'normal' : 'critical';
      Process.run('notify-send', ['-u', urgency, title, body]).ignore();
    }
  }

  @override
  void dispose() {
    if (!isMobilePlatform) windowManager.removeListener(this);
    super.dispose();
  }
  @override
  void onWindowClose() async {
    final state = context.read<AppState>();
    await state.shutdown();
    await windowManager.destroy();
  }

  @override
  void onWindowMaximize() { if (mounted) setState(() => _isMaximized = true); }
  @override
  void onWindowUnmaximize() { if (mounted) setState(() => _isMaximized = false); }

  static String? _modifierLabel(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.controlLeft || k == LogicalKeyboardKey.controlRight) return 'Control';
    if (k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight) return 'Shift';
    if (k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight) return 'Alt';
    if (k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight) return 'Meta';
    return null;
  }

  bool _matchesBinding(KeyEvent event, List<String> binding) {
    if (event is! KeyDownEvent || binding.isEmpty) return false;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final heldModifiers = <String>{};
    for (final k in pressed) {
      final m = _modifierLabel(k);
      if (m != null) heldModifiers.add(m);
    }
    final bindingModifiers = binding.where((b) => const {'Control', 'Shift', 'Alt', 'Meta'}.contains(b)).toSet();
    final bindingKey = binding.where((b) => !const {'Control', 'Shift', 'Alt', 'Meta'}.contains(b)).join();
    if (heldModifiers.length != bindingModifiers.length) return false;
    if (!heldModifiers.containsAll(bindingModifiers)) return false;
    final eventLabel = event.logicalKey.keyLabel;
    return eventLabel.isNotEmpty && eventLabel.toLowerCase() == bindingKey.toLowerCase();
  }

  KeyEventResult _handleGlobalKey(FocusNode node, KeyEvent event) {
    final state = context.read<AppState>();
    final bindings = state.config.keyBindings;
    final s = AppStrings.of(state.config.language);
    final nav = state.selectedNav;

    // Project page shortcuts (nav == 0)
    if (nav == 0) {
      final selectAllBinding = bindings['project_select_all'] ?? ['Control', 'A'];
      if (_matchesBinding(event, selectAllBinding)) {
        if (state.videos.isNotEmpty) {
          _projectPageKey.currentState?.selectAll(state.videos);
        }
        return KeyEventResult.handled;
      }

      final addAllBinding = bindings['queue_add_all'] ?? ['Control', 'Shift', 'A'];
      if (_matchesBinding(event, addAllBinding)) {
        final parsed = state.videos.where((v) => v.parsed).toList();
        if (parsed.isNotEmpty) {
          for (final v in parsed) {
            state.addTask(v.id);
          }
          showToast(context, s.isZh ? '已添加 ${parsed.length} 个任务到队列' : 'Added ${parsed.length} tasks to queue', type: ToastType.success);
        }
        return KeyEventResult.handled;
      }

      final clearAllBinding = bindings['project_clear_all'] ?? ['Control', 'Shift', 'Delete'];
      if (_matchesBinding(event, clearAllBinding)) {
        if (state.videos.isNotEmpty) {
          state.clearAllVideos();
          _projectPageKey.currentState?.selectAll([]);
          showToast(context, s.isZh ? '已删除所有项目' : 'All projects deleted', type: ToastType.info);
        }
        return KeyEventResult.handled;
      }
    }

    // 全局导航快捷键（任意页面可用）
    final navProjects = bindings['nav_projects'] ?? ['Control', '1'];
    if (_matchesBinding(event, navProjects)) { state.selectNav(0); return KeyEventResult.handled; }
    final navQueue = bindings['nav_queue'] ?? ['Control', '2'];
    if (_matchesBinding(event, navQueue)) { state.selectNav(1); return KeyEventResult.handled; }
    final navCommand = bindings['nav_command'] ?? ['Control', '3'];
    if (_matchesBinding(event, navCommand)) { state.selectNav(2); return KeyEventResult.handled; }
    final navSettings = bindings['nav_settings'] ?? ['Control', '4'];
    if (_matchesBinding(event, navSettings)) { state.selectNav(4); return KeyEventResult.handled; }

    // Queue page shortcuts (nav == 1)
    if (nav == 1) {
      final startAllBinding = bindings['queue_start_all'] ?? ['Control', 'Shift', 'S'];
      if (_matchesBinding(event, startAllBinding)) {
        final pendingCount = state.tasks.where((t) => t.status == TaskStatus.pending).length;
        if (pendingCount > 0) {
          state.processAllTasks();
          showToast(context, s.isZh ? '已开始 $pendingCount 个任务' : 'Started $pendingCount tasks', type: ToastType.success);
        }
        return KeyEventResult.handled;
      }

      final stopAllBinding = bindings['queue_stop_all'] ?? ['Control', 'Shift', 'X'];
      if (_matchesBinding(event, stopAllBinding)) {
        if (state.processing) {
          state.cancelProcessing();
          showToast(context, s.isZh ? '已停止所有任务' : 'All tasks stopped', type: ToastType.warning);
        }
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 用 select 只监听导航索引，避免任何进度/日志 notify 都重建整棵页面树。
    final nav = context.select<AppState, int>((s) => s.selectedNav);
    final mobile = isMobilePlatform;

    // 桌面端：左侧边栏 + 页面；移动端：仅页面（导航在底部栏）
    final Widget page = mobile
        ? _pageStack(nav)
        : Focus(
            autofocus: true,
            onKeyEvent: _handleGlobalKey,
            child: Row(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
                child: Sidebar(selectedIndex: nav,
                    onSelected: (i) => context.read<AppState>().selectNav(i)),
              ),
              Expanded(child: _pageStack(nav)),
            ]),
          );

    final Widget body;
    if (mobile) {
      // 移动端布局：内容区 + 底部液态玻璃导航栏；顶部避开状态栏
      body = Column(children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            child: page,
          ),
        ),
        MobileBottomNav(
          selectedIndex: nav,
          onSelected: (i) => context.read<AppState>().selectNav(i),
        ),
      ]);
    } else {
      body = Platform.isWindows
          ? page
          // 无边框窗口会失去原生边框的拖拽缩放能力，用 DragToResizeArea 在四边
          // 补上透明的 resize 热区（宽 6px），鼠标移到边缘即可拖动调整窗口大小。
          : DragToResizeArea(
              resizeEdgeSize: 6,
              child: Stack(children: [
                Padding(
                  padding: const EdgeInsets.only(top: 36),
                  child: page,
                ),
                Positioned(left: 0, right: 0, top: 0, child: _buildCsdTitleBar(scheme)),
              ]),
            );
    }

    // 壁纸：独立 Selector，只监听 backgroundImage/backgroundOpacity，
    // 进度 tick 之类的 notify 不会重建这棵子树。
    return Selector<AppState, (String, double)>(
      selector: (_, s) => (s.config.backgroundImage, s.config.backgroundOpacity),
      builder: (context, bgTuple, _) {
        final bg = bgTuple.$1;
        final hasBg = bg.isNotEmpty && _bgFileExists(bg);
        if (!hasBg) return Scaffold(body: body);
        // 有壁纸时：壁纸铺底 + 半透明遮罩 + 透明 Scaffold（让子页面也能看到壁纸）
        final a = ((1.0 - bgTuple.$2) * 220).round().clamp(20, 240);
        // 内存优化：按窗口逻辑尺寸解码壁纸（而不是原图全尺寸），
        // 2560×1914 的壁纸解码后可节省 70%+ 内存。
        final w = MediaQuery.sizeOf(context).width.ceil();
        final h = MediaQuery.sizeOf(context).height.ceil();
        return Stack(children: [
          Positioned.fill(child: Image.file(File(bg), fit: BoxFit.cover,
              cacheWidth: (w * 1.25).ceil(), cacheHeight: (h * 1.25).ceil(),
              errorBuilder: (_, a, b) {
                clearBgCache();
                return const SizedBox.shrink();
              })),
          Positioned.fill(child: Container(color: scheme.surface.withAlpha(a))),
          // 用 Theme 覆盖 scaffoldBackgroundColor 为透明，让子页面 Scaffold 不遮壁纸
          Theme(
            data: Theme.of(context).copyWith(scaffoldBackgroundColor: Colors.transparent),
            child: Scaffold(backgroundColor: Colors.transparent, body: body),
          ),
        ]);
      },
    );
  }

  static final Map<String, bool> _bgCache = {};
  static bool _bgFileExists(String path) {
    return _bgCache.putIfAbsent(path, () => File(path).existsSync());
  }
  static void clearBgCache() => _bgCache.clear();

  Widget _buildCsdTitleBar(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.surface.withAlpha(isDark ? 160 : 180),
                scheme.surface.withAlpha(isDark ? 120 : 140),
              ],
            ),
            border: Border(bottom: BorderSide(
              color: scheme.outlineVariant.withAlpha(isDark ? 60 : 80),
              width: 0.5,
            )),
          ),
          child: Stack(children: [
            DragToMoveArea(child: GestureDetector(
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
              child: Container(color: Colors.transparent),
            )),
            Positioned(right: 0, top: 0, bottom: 0, child: Row(mainAxisSize: MainAxisSize.min, children: [
              _csdButton(Icons.remove, scheme.onSurfaceVariant, null, () => windowManager.minimize()),
              _csdButton(
                _isMaximized ? Icons.filter_none : Icons.crop_square,
                scheme.onSurfaceVariant, null,
                () async {
                  if (await windowManager.isMaximized()) {
                    windowManager.unmaximize();
                  } else {
                    windowManager.maximize();
                  }
                },
              ),
              _csdButton(Icons.close, scheme.onSurface, Colors.red, () => windowManager.close()),
            ])),
          ]),
        ),
      ),
    );
  }

  Widget _csdButton(IconData icon, Color color, Color? hoverBg, VoidCallback onTap) {
    return _CsdWindowButton(icon: icon, color: color, hoverBg: hoverBg, onTap: onTap);
  }

  /// 页面懒加载缓存：首次访问才构建，切换时保留状态（IndexedStack），
  /// 避免 AnimatedSwitcher 每次切换重建整页导致的卡顿。
  final List<Widget?> _pageCache = List.filled(6, null);

  Widget _page(int i) {
    final cached = _pageCache[i];
    if (cached != null) return KeyedSubtree(key: ValueKey(i), child: cached);
    // 首次访问：构建页面并缓存
    final page = switch (i) {
      0 => ProjectPage(key: _projectPageKey), 1 => const QueuePage(),
      2 => const CommandPage(), 3 => const ConfigLibraryPage(),
      4 => const SettingsPage(), 5 => const LogPage(),
      _ => const ProjectPage(),
    };
    _pageCache[i] = page;
    return KeyedSubtree(key: ValueKey(i), child: page);
  }

  /// 所有页面同时存在于 IndexedStack（已访问的缓存、未访问的占位），
  /// 切换零重建、零动画开销。
  Widget _pageStack(int current) => IndexedStack(
    index: current,
    children: [
      for (var i = 0; i < 6; i++)
        i == current ? _page(i) : (_pageCache[i] ?? const SizedBox.shrink()),
    ],
  );

  /// 后台分帧预热其余页面到缓存（主界面显示后逐帧构建），
  /// 之后首次点击进入不再卡顿（构建成本已摊到空闲帧）。
  void _prewarmPages() {
    if (_warming) return;
    _warming = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      for (var i = 0; i < 6; i++) {
        if (!mounted) return;
        // 每帧只构建一页，避免单帧长任务
        await Future<void>.delayed(const Duration(milliseconds: 160));
        if (!mounted) return;
        setState(() { _page(i); });
      }
    });
  }
  bool _warming = false;
}

class _CsdWindowButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final Color? hoverBg;
  final VoidCallback onTap;
  const _CsdWindowButton({required this.icon, required this.color, this.hoverBg, required this.onTap});
  @override
  State<_CsdWindowButton> createState() => _CsdWindowButtonState();
}

class _CsdWindowButtonState extends State<_CsdWindowButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 36,
          color: _hovering
              ? (widget.hoverBg ?? widget.color.withAlpha(30))
              : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 18,
            color: _hovering && widget.hoverBg != null ? Colors.white : widget.color,
          ),
        ),
      ),
    );
  }
}

Route<T> smoothRoute<T>(Widget page) => PageRouteBuilder<T>(
  pageBuilder: (_, a, b) => page,
  transitionDuration: const Duration(milliseconds: 250),
  reverseTransitionDuration: const Duration(milliseconds: 200),
  transitionsBuilder: (_, anim, c, child) {
    final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(curve),
        child: child,
      ),
    );
  },
);
