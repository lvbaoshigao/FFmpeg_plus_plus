import 'package:flutter/material.dart';

import 'app_card.dart';

/// Keeps final output visible independently of expandable generation details.
class AiWorkflowCard extends StatefulWidget {
  const AiWorkflowCard({
    super.key,
    required this.active,
    required this.summary,
    required this.process,
    required this.answer,
    required this.style,
  });
  final bool active;
  final String summary;
  final Widget process;
  final Widget answer;
  final String style;
  @override
  State<AiWorkflowCard> createState() => _AiWorkflowCardState();
}

class _AiWorkflowCardState extends State<AiWorkflowCard> {
  bool _expanded = false;
  @override
  void didUpdateWidget(covariant AiWorkflowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final expanded = widget.active || _expanded;
    return AppCard(
      style: widget.style,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            expanded: expanded,
            child: InkWell(
              onTap: widget.active
                  ? null
                  : () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  children: [
                    if (widget.active)
                      const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.account_tree_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.summary,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: widget.process,
            ),
          widget.answer,
        ],
      ),
    );
  }
}
