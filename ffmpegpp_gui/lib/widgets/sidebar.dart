import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';
import 'glass_panel.dart';

class Sidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  const Sidebar({super.key, required this.selectedIndex, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lang = context.watch<AppState>().config.language;
    final s = AppStrings.of(lang);
    final clr = scheme.onSurfaceVariant;

    final debug = context.watch<AppState>().config.debugMode;
    final items = <(IconData, String)>[
      (Icons.movie_outlined, s.navProjects),
      (Icons.list_alt_outlined, s.navQueue),
      (Icons.terminal_outlined, s.navCommand),
      (Icons.folder_copy_outlined, lang == 'zh' ? '配置库' : 'Configs'),
      (Icons.settings_outlined, s.navSettings),
      if (debug) (Icons.terminal, lang == 'zh' ? '日志' : 'Logs'),
    ];

    // 当 debug 模式关闭时，如果当前选中的是 Logs 页面，自动切回设置页面
    if (selectedIndex >= items.length && items.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onSelected(items.length - 1);
      });
    }

    return SizedBox(
      width: 190,
      child: GlassPanel(
        radius: 20,
        blur: 18,
        child: Material(
          color: Colors.transparent,
          child: DefaultTextStyle(
          style: TextStyle(color: clr, fontFamily: theme.textTheme.bodyMedium?.fontFamily),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(6),
                    child: Image.asset('rele/icon.png', width: 28, height: 28, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(Icons.play_circle_fill, color: scheme.primary, size: 28))),
                const SizedBox(width: 10),
                Text('FFmpeg++', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: scheme.primary)),
              ]),
            ),
            Divider(color: scheme.outlineVariant.withAlpha(80), height: 1),
            const SizedBox(height: 8),
            ...List.generate(items.length, (i) {
              final sel = i == selectedIndex;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: sel ? scheme.secondaryContainer.withAlpha(200) : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => onSelected(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(children: [
                          Icon(items[i].$1, size: 20,
                              color: sel ? scheme.onSecondaryContainer : clr),
                          const SizedBox(width: 10),
                          Text(items[i].$2, style: TextStyle(fontSize: 13,
                              fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                              color: sel ? scheme.onSecondaryContainer : clr)),
                        ]),
                      ),
                    ),
                  ),
                ),
              );
            }),
            const Spacer(),
            Padding(padding: const EdgeInsets.all(16), child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: scheme.surfaceContainerHighest.withAlpha(140)),
              child: Row(children: [
                Builder(builder: (ctx) {
                  final running = ctx.watch<AppState>().pythonProcess.isRunning;
                  return Container(width: 8, height: 8, decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: running ? scheme.primary : scheme.error));
                }),
                const SizedBox(width: 8),
                Expanded(child: Text(
                    context.watch<AppState>().pythonProcess.isRunning ? s.backendConnected : (lang == 'zh' ? '后端已断开' : 'Backend disconnected'),
                    style: TextStyle(fontSize: 11, color: clr))),
              ]),
            )),
          ]),
          ),
        ),
      ),
    );
  }
}
