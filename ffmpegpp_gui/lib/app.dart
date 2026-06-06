import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'theme/app_theme.dart';
import 'pages/project_page.dart';
import 'pages/queue_page.dart';
import 'pages/command_page.dart';
import 'pages/ai_page.dart';
import 'pages/settings_page.dart';
import 'widgets/sidebar.dart';

class FfmpegppApp extends StatelessWidget {
  const FfmpegppApp({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final cfg = state.config;
        return MaterialApp(
          key: ValueKey('app_${cfg.fontFamily}_${cfg.fontSize}_${cfg.darkMode}_${cfg.themeColor}'),
          title: 'FFmpeg++', debugShowCheckedModeBanner: false,
          theme: AppTheme.light(seedColor: cfg.themeColor, fontFamily: cfg.fontFamily,
              fontSize: cfg.fontSize, fontWeight: cfg.fontWeightValue, glass: cfg.glassEffect),
          darkTheme: AppTheme.dark(seedColor: cfg.themeColor, fontFamily: cfg.fontFamily,
              fontSize: cfg.fontSize, fontWeight: cfg.fontWeightValue, glass: cfg.glassEffect),
          themeMode: state.darkMode ? ThemeMode.dark : ThemeMode.light,
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
  @override
  void initState() { super.initState(); windowManager.addListener(this); }
  @override
  void dispose() { windowManager.removeListener(this); super.dispose(); }
  @override
  void onWindowClose() async {
    await context.read<AppState>().shutdown();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Row(children: [
      Sidebar(selectedIndex: context.watch<AppState>().selectedNav,
          onSelected: (i) => context.read<AppState>().selectNav(i)),
      const VerticalDivider(width: 1),
      Expanded(child: _page(context.watch<AppState>().selectedNav)),
    ]);

    // 壁纸：独立 Consumer，只监听 backgroundImage 变化
    return Consumer<AppState>(
      builder: (context, state, _) {
        final bg = state.config.backgroundImage;
        if (bg.isEmpty) return Scaffold(body: body);
        // 缓存文件存在性避免每次重建都调 existsSync
        if (!_bgFileExists(bg)) return Scaffold(body: body);
        final a = ((1.0 - state.config.backgroundOpacity) * 220).round().clamp(20, 240);
        return Stack(children: [
          Positioned.fill(child: Image.file(File(bg), fit: BoxFit.cover)),
          Scaffold(backgroundColor: scheme.surface.withAlpha(a), body: body),
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
    0 => const ProjectPage(), 1 => const QueuePage(),
    2 => const CommandPage(), 3 => const AIPage(),
    4 => const SettingsPage(),
    _ => const ProjectPage(),
  };
}
