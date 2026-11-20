import 'package:flutter/material.dart';

import '../app_dropdown.dart';
import 'editor_kit.dart';

/// Reads a finite parameter value within the editor's supported range.
double editorNumberInRange(
  Object? value, {
  required double fallback,
  required double min,
  required double max,
}) {
  final parsed = value is num ? value : num.tryParse(value?.toString() ?? '');
  return parsed != null && parsed.isFinite
      ? parsed.toDouble().clamp(min, max)
      : fallback;
}

/// Reflows paired fields when their labels need more room.
class EditorFieldPair extends StatelessWidget {
  const EditorFieldPair({super.key, required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
      if (constraints.maxWidth < 400 || largeText) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 16), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 12),
          Expanded(child: second),
        ],
      );
    },
  );
}

/// Uses the app menu while allowing its field label to wrap.
class EditorChoiceField extends StatelessWidget {
  const EditorChoiceField({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Semantics(
        label: label,
        child: AppDropdown<String>(
          value: value,
          height: 48,
          items: [
            for (final (value, text) in items) AppDropdownItem(value, text),
          ],
          onChanged: onChanged,
        ),
      ),
    ],
  );
}

/// A numeric field that keeps invalid drafts out of the node parameters.
class EditorNumberField extends StatefulWidget {
  const EditorNumberField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.unit,
    this.helper,
    this.integer = false,
    this.isZh = true,
  });

  final String label;
  final num value;
  final num min;
  final num max;
  final ValueChanged<num> onChanged;
  final String? unit;
  final String? helper;
  final bool integer;
  final bool isZh;

  @override
  State<EditorNumberField> createState() => _EditorNumberFieldState();
}

class _EditorNumberFieldState extends State<EditorNumberField> {
  late final TextEditingController _controller = TextEditingController(
    text: _format(widget.value),
  );
  String? _error;

  String _format(num value) {
    if (widget.integer) {
      return value.toInt().toString();
    }
    final text = value.toString();
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  @override
  void didUpdateWidget(covariant EditorNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        num.tryParse(_controller.text) != widget.value) {
      _controller.text = _format(widget.value);
      _error = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _edit(String raw) {
    final value = widget.integer ? int.tryParse(raw) : double.tryParse(raw);
    if (value == null ||
        !value.isFinite ||
        value < widget.min ||
        value > widget.max) {
      setState(() {
        _error = widget.isZh
            ? '请输入 ${widget.min} 到 ${widget.max} 之间的${widget.integer ? "整数" : "数值"}'
            : 'Enter ${widget.integer ? "an integer" : "a value"} from ${widget.min} to ${widget.max}.';
      });
      return;
    }
    setState(() => _error = null);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: _controller,
      keyboardType: TextInputType.numberWithOptions(
        decimal: !widget.integer,
        signed: widget.min < 0,
      ),
      textInputAction: TextInputAction.next,
      style: theme.textTheme.bodyMedium,
      decoration: editorDenseField(widget.label, suffixText: widget.unit)
          .copyWith(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            helperText: widget.helper,
            helperMaxLines: 4,
            helperStyle: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            errorText: _error,
            errorMaxLines: 4,
            errorStyle: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
      onChanged: _edit,
      onTapOutside: (_) => FocusScope.of(context).unfocus(),
    );
  }
}
