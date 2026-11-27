import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../plugins/plugin_manifest.dart';
import 'option_menu_bar.dart';

/// Host-owned controls for a plugin's declarative fields. No executable UI,
/// callback names, Widget factories or expressions are accepted from a plugin.
class PluginForm extends StatefulWidget {
  const PluginForm({
    super.key,
    required this.fields,
    required this.values,
    required this.onChanged,
    this.enabled = true,
  });

  final List<Map<String, dynamic>> fields;
  final Map<String, dynamic> values;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool enabled;

  @override
  State<PluginForm> createState() => _PluginFormState();
}

class _PluginFormState extends State<PluginForm> {
  final _controllers = <String, TextEditingController>{};
  final _errors = <String, String>{};
  Map<String, dynamic> _values = {};
  List<PluginFieldDefinition> _fields = [];
  String? _schemaError;

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void didUpdateWidget(covariant PluginForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameFields(oldWidget.fields, widget.fields) ||
        !mapEquals(oldWidget.values, widget.values)) {
      _configure();
    }
  }

  bool _sameFields(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (final key in a[i].keys) {
        final left = a[i][key];
        final right = b[i][key];
        if (left is List && right is List) {
          if (!listEquals(left, right)) return false;
        } else if (left != right) {
          return false;
        }
      }
    }
    return true;
  }

  void _configure() {
    _schemaError = null;
    _errors.clear();
    try {
      if (widget.fields.length > 64) {
        throw const FormatException('Too many plugin fields (maximum 64).');
      }
      final fields = widget.fields.map(PluginFieldDefinition.fromJson).toList();
      final keys = fields.map((f) => f.key).toSet();
      if (keys.length != fields.length ||
          widget.values.keys.any((key) => !keys.contains(key))) {
        throw const FormatException('Duplicate fields or undeclared values.');
      }
      _fields = fields;
      _values = {
        for (final field in fields)
          field.key: widget.values.containsKey(field.key)
              ? widget.values[field.key]
              : field.defaultValue,
      };
      for (final field in fields) {
        final error = _error(field, _values[field.key]);
        if (error != null) {
          _errors[field.key] = error;
        } else {
          _values[field.key] = field.validateValue(_values[field.key]);
        }
        if (field.type != 'boolean' && field.type != 'select') {
          final text = '${_values[field.key] ?? ''}';
          final controller = _controllers.putIfAbsent(
            field.key,
            () => TextEditingController(text: text),
          );
          if (controller.text != text) controller.text = text;
        }
      }
      final removed = _controllers.keys
          .where((key) => !keys.contains(key))
          .toList();
      for (final key in removed) {
        _controllers.remove(key)?.dispose();
      }
    } on FormatException catch (error) {
      _schemaError = error.message;
      _fields = [];
    }
  }

  String? _error(PluginFieldDefinition field, Object? value) {
    try {
      field.validateValue(value);
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  void _change(PluginFieldDefinition field, dynamic value) {
    if (!widget.enabled || _schemaError != null) return;
    setState(() {
      final error = _error(field, value);
      if (error == null) {
        _errors.remove(field.key);
        _values[field.key] = field.validateValue(value);
      } else {
        _errors[field.key] = error;
      }
    });
    // Invalid drafts never enter graph state or cross the WASM boundary.
    if (_errors.isEmpty) widget.onChanged(Map<String, dynamic>.of(_values));
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_schemaError != null) {
      return Text(
        'Invalid plugin form: $_schemaError',
        key: const ValueKey('plugin_form_schema_error'),
        style: TextStyle(color: scheme.error),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in _fields)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _control(field),
          ),
      ],
    );
  }

  Widget _control(PluginFieldDefinition field) {
    final value = _values[field.key];
    final error = _errors[field.key];
    if (field.type == 'boolean') {
      return SwitchListTile.adaptive(
        key: ValueKey('plugin_field_${field.key}'),
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: error == null ? null : Text(error),
        value: value == true,
        onChanged: widget.enabled ? (v) => _change(field, v) : null,
      );
    }
    if (field.type == 'select') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeFocus(
            excluding: !widget.enabled,
            child: IgnorePointer(
              ignoring: !widget.enabled,
              child: Opacity(
                opacity: widget.enabled ? 1 : 0.5,
                child: OptionMenuBar<String>(
                  key: ValueKey('plugin_field_${field.key}'),
                  label: field.label,
                  value: field.options.contains(value)
                      ? value as String
                      : field.options.first,
                  items: [
                    for (final option in field.options)
                      OptionItem(option, option),
                  ],
                  onChanged: (v) => _change(field, v),
                ),
              ),
            ),
          ),
          if (error != null)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    }
    return TextField(
      key: ValueKey('plugin_field_${field.key}'),
      controller: _controllers[field.key],
      enabled: widget.enabled,
      keyboardType: field.type == 'string'
          ? TextInputType.text
          : TextInputType.numberWithOptions(
              decimal: field.type == 'number',
              signed: true,
            ),
      maxLength: field.type == 'string' ? 16384 : 32,
      decoration: InputDecoration(
        labelText: field.label,
        errorText: error,
        counterText: '',
        helperText: field.min != null || field.max != null
            ? '${field.min ?? '−∞'} … ${field.max ?? '∞'}'
            : null,
        border: const OutlineInputBorder(),
      ),
      onChanged: (raw) => _change(
        field,
        field.type == 'integer'
            ? int.tryParse(raw.trim())
            : field.type == 'number'
            ? num.tryParse(raw.trim())
            : raw,
      ),
    );
  }
}
