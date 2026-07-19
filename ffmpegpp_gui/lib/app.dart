import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class FfmpegppApp extends StatelessWidget {
  const FfmpegppApp({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final cfg = state.config;
        return MaterialApp(
          key: ValueKey('app_${cfg.fontFamily}_${cfg.fontWeightValue}'),
          title: 'FFmpeg++', debugShowCheckedModeBanner: false,
          theme: AppTheme.light(seedColor: cfg.themeColor, fontFamily: cfg.fontFamily,
              fontSize: cfg.fontSize, fontWeight: cfg.fontWeightValue),
          darkTheme: AppTheme.dark(seedColor: cfg.themeColor, fontFamily: cfg.fontFamily,
              fontSize: cfg.fontSize, fontWeight: cfg.fontWeightValue),
          themeMode: state.darkMode ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) {
            final scale = cfg.fontSize / 14.0;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            );
          },
          home: state.initialized ? const AppShell() : const _SplashScreen(),
        );
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.play_circle_fill, size: 64, color: scheme.primary),
          const SizedBox(height: 16),
          Text('FFmpeg++', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: scheme.primary)),
          const SizedBox(height: 24),
          SizedBox(width: 120, child: LinearProgressIndicator(
            color: scheme.primary,
            backgroundColor: scheme.surfaceContainerHighest,
          )),
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
    windowManager.addListener(this);
    if (!Platform.isWindows) {
      windowManager.isMaximized().then((v) {
        if (mounted) setState(() => _isMaximized = v);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      state.onTaskFinished = _onTaskFinished;
      _checkPostUpdate();
      _autoCheckUpdate();
    });
  }

  Future<void> _autoCheckUpdate() async {
    final state = context.read<AppState>();
    if (!state.config.autoCheckUpdate) return;
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    final isZh = state.config.language == 'zh';
    final result = await updater.checkForUpdate(preferLanzou: isZh);
    if (!mounted || !result.hasUpdate) return;
    final s = AppStrings.of(state.config.language);
    SettingsPage.showUpdateDialogStatic(context, s, result);
  }

  Future<void> _checkPostUpdate() async {
    final status = await updater.checkPostUpdateStatus();
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
      final ps = "Add-Type -AssemblyName System.Windows.Forms;"
          "Add-Type -AssemblyName System.Drawing;"
          "\$n=New-Object System.Windows.Forms.NotifyIcon;"
          "\$n.Icon=[System.Drawing.SystemIcons]::Information;"
          "\$n.BalloonTipIcon=[System.Windows.Forms.ToolTipIcon]::$icon;"
          "\$n.BalloonTipTitle='$title';"
          "\$n.BalloonTipText='$body';"
          "\$n.Visible=\$true;"
          "\$n.ShowBalloonTip(3000);"
          "Start-Sleep -Milliseconds 3500;"
          "\$n.Dispose()";
      Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
    } else {
      final urgency = status == TaskStatus.completed ? 'normal' : 'critical';
      Process.run('notify-send', ['-u', urgency, title, body]);
    }
  }

  @override
  void dispose() { windowManager.removeListener(this); super.dispose(); }
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
    final content = Focus(
      autofocus: true,
      onKeyEvent: _handleGlobalKey,
      child: Row(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
          child: Sidebar(selectedIndex: context.watch<AppState>().selectedNav,
              onSelected: (i) => context.read<AppState>().selectNav(i)),
        ),
        Expanded(child: _page(context.watch<AppState>().selectedNav)),
      ]),
    );

    final body = Platform.isWindows
        ? content
        : Stack(children: [
            Padding(
              padding: const EdgeInsets.only(top: 36),
              child: content,
            ),
            Positioned(left: 0, right: 0, top: 0, child: _buildCsdTitleBar(scheme)),
          ]);

    // 壁纸：独立 Consumer，只监听 backgroundImage 变化
    return Consumer<AppState>(
      builder: (context, state, _) {
        final bg = state.config.backgroundImage;
        final hasBg = bg.isNotEmpty && _bgFileExists(bg);
        if (!hasBg) return Scaffold(body: body);
        // 有壁纸时：壁纸铺底 + 半透明遮罩 + 透明 Scaffold（让子页面也能看到壁纸）
        final a = ((1.0 - state.config.backgroundOpacity) * 220).round().clamp(20, 240);
        return Stack(children: [
          Positioned.fill(child: Image.file(File(bg), fit: BoxFit.cover,
              errorBuilder: (_, __, ___) {
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

  Widget _page(int i) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    switchInCurve: Curves.easeOut,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
    child: KeyedSubtree(key: ValueKey(i), child: switch (i) {
      0 => ProjectPage(key: _projectPageKey), 1 => const QueuePage(),
      2 => const CommandPage(), 3 => const ConfigLibraryPage(),
      4 => const SettingsPage(), 5 => const LogPage(),
      _ => const ProjectPage(),
    }),
  );
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
  pageBuilder: (_, __, ___) => page,
  transitionDuration: const Duration(milliseconds: 250),
  reverseTransitionDuration: const Duration(milliseconds: 200),
  transitionsBuilder: (_, anim, __, child) {
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
