import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_strings.dart';

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
      (Icons.auto_awesome, s.navAI),
      (Icons.settings_outlined, s.navSettings),
      if (debug) (Icons.terminal, 'Logs'),
    ];

    return SizedBox(
      width: 200,
      child: Material(
        color: scheme.surfaceContainerLow,
        child: DefaultTextStyle(
          style: TextStyle(color: clr, fontFamily: theme.textTheme.bodyMedium?.fontFamily),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: Row(children: [
                Icon(Icons.play_circle_fill, color: scheme.primary, size: 28),
                const SizedBox(width: 10),
                Text('FFmpeg++', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: scheme.primary)),
              ]),
            ),
            const Divider(),
            const SizedBox(height: 8),
            ...List.generate(items.length, (i) {
              final sel = i == selectedIndex;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Material(
                  color: sel ? scheme.secondaryContainer : Colors.transparent,
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
              );
            }),
            const Spacer(),
            Padding(padding: const EdgeInsets.all(16), child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: scheme.surfaceContainerHighest),
              child: Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary)),
                const SizedBox(width: 8),
                Expanded(child: Text(s.backendConnected, style: TextStyle(fontSize: 11, color: clr))),
              ]),
            )),
          ]),
        ),
      ),
    );
  }
}
