import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../plugins/plugin_manifest.dart';
import '../../plugins/plugin_node_catalog.dart';
import '../../providers/app_state.dart';
import '../plugin_form.dart';

/// A host-owned form. WASM may describe controls, never construct Widgets.
class PluginStepEditor extends StatefulWidget {
  const PluginStepEditor({
    super.key,
    required this.node,
    required this.isZh,
    required this.onChanged,
  });
  final PipelineNode node;
  final bool isZh;
  final VoidCallback onChanged;
  @override
  State<PluginStepEditor> createState() => _PluginStepEditorState();
}

class _PluginStepEditorState extends State<PluginStepEditor> {
  List<Map<String, dynamic>> _fields = [];
  String _signature = "";
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configure();
  }

  @override
  void didUpdateWidget(covariant PluginStepEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configure();
  }

  void _configure() {
    final node = widget.node;
    final feature = context.read<AppState>().config.pluginsEnabled;
    final signature = jsonEncode([
      node.id,
      node.pluginId,
      node.pluginNodeId,
      node.pluginEnvelope['version'],
      PluginNodeCatalog.instance.revision,
      feature,
    ]);
    if (_signature == signature) return;
    _signature = signature;
    final generation = ++_generation;
    _fields =
        node.pluginDisplayDefinition?.fields
            .map((field) => field.toJson())
            .toList() ??
        [];
    if (feature && node.pluginUnavailableReason == null) {
      unawaited(_loadOptionalEditor(generation));
    }
  }

  Future<void> _loadOptionalEditor(int generation) async {
    final node = widget.node;
    final definition = node.pluginDefinition;
    if (definition == null) return;
    try {
      final manager = context.read<AppState>().plugins;
      if (manager == null) return;
      final response = await manager.invoke(node.pluginId, 'Node_editor_add', {
        'api_version': 1,
        'plugin_id': node.pluginId,
        'node_id': node.pluginNodeId,
      });
      final raw = response['fields'];
      if (raw is! List || raw.length != definition.fields.length) return;
      final fields = <PluginFieldDefinition>[];
      for (final value in raw) {
        if (value is! Map || !value.keys.every((key) => key is String)) return;
        fields.add(
          PluginFieldDefinition.fromJson(Map<String, dynamic>.from(value)),
        );
      }
      if (fields.map((field) => field.key).toSet().length != fields.length) {
        return;
      }
      // Optional UI metadata can reorder/rename declared controls, but cannot
      // silently expand the manifest parameter schema or weaken its bounds.
      final declared = {
        for (final field in definition.fields) field.key: field,
      };
      for (final field in fields) {
        final original = declared[field.key];
        if (original == null ||
            field.type != original.type ||
            field.defaultValue != original.defaultValue ||
            field.min != original.min ||
            field.max != original.max ||
            !listEquals(field.options, original.options)) {
          return;
        }
      }
      if (!mounted ||
          generation != _generation ||
          node.pluginUnavailableReason != null) {
        return;
      }
      setState(() => _fields = fields.map((field) => field.toJson()).toList());
    } catch (_) {
      // Node_editor_add is optional. Missing export/traps leave manifest fields.
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final enabled = context.select<AppState, bool>(
      (state) => state.config.pluginsEnabled,
    );
    final definition = node.pluginDisplayDefinition;
    final ready = context.read<AppState>().plugins != null;
    final reason = !enabled
        ? (widget.isZh ? '实验性插件功能已关闭' : 'Experimental plugins are disabled')
        : !ready
        ? (widget.isZh ? '插件服务尚未就绪' : 'Plugin service is not ready')
        : node.pluginUnavailableReason;
    final rawValues = node.params['values'];
    final values =
        rawValues is Map && rawValues.keys.every((key) => key is String)
        ? Map<String, dynamic>.from(rawValues)
        : <String, dynamic>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          definition?.name ?? (widget.isZh ? '插件节点' : 'Plugin node'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (definition != null && definition.fun.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(definition.fun),
        ],
        const SizedBox(height: 6),
        SelectableText(
          '${node.pluginId}/${node.pluginNodeId}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (reason != null) ...[
          const SizedBox(height: 8),
          Text(
            reason,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          Text(
            widget.isZh
                ? '节点与原参数会保留，可保存或导出，暂不能执行。'
                : 'Node data is preserved and can be saved or exported, but cannot run.',
          ),
        ],
        const SizedBox(height: 12),
        PluginForm(
          fields: _fields,
          values: values,
          enabled: enabled && ready && node.pluginCompatibilityIssue == null,
          onChanged: (next) {
            final live = node.pluginDefinition;
            if (live == null || !enabled || !ready || node.pluginCompatibilityIssue != null) return;
            try {
              node.params['values'] = live.validateValues(next);
              widget.onChanged();
            } on FormatException {
              // Imported stale forms must never mutate the executable schema.
            }
          },
        ),
      ],
    );
  }
}
