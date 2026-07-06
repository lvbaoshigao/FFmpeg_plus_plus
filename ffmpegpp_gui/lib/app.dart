import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'models/models.dart';
import 'theme/app_theme.dart';
import 'theme/app_strings.dart';
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
          // 全局文字缩放：放在 builder 里覆盖 MaterialApp 内部的 MediaQuery
          builder: (context, child) {
            final scale = cfg.fontSize / 14.0;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            );
          },
          home: const AppShell(),
        );
      },
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

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      state.onTaskFinished = _onTaskFinished;
    });
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
  }

  @override
  void dispose() { windowManager.removeListener(this); super.dispose(); }
  @override
  void onWindowClose() async {
    final state = context.read<AppState>();
    await state.shutdown();
    await windowManager.destroy();
  }

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
    final body = Focus(
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

  Widget _page(int i) => switch (i) {
    0 => ProjectPage(key: _projectPageKey), 1 => const QueuePage(),
    2 => const CommandPage(), 3 => const ConfigLibraryPage(),
    4 => const SettingsPage(), 5 => const LogPage(),
    _ => const ProjectPage(),
  };
}
