import 'package:flutter/material.dart';

/// Supporting settings typography, in logical pixels before app text scaling.
abstract final class SettingsTypography {
  static const sectionTitle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.4,
  );

  static const description = TextStyle(fontSize: 10.5, height: 1.4);
}

/// A group heading outside its card, with optional contextual actions.
class SettingsSectionHeading extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Widget? trailing;

  const SettingsSectionHeading({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: SettingsTypography.sectionTitle.copyWith(color: color),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
