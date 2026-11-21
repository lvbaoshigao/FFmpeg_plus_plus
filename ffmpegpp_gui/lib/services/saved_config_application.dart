import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
import '../widgets/app_alert_dialog.dart';
import 'graph_executor.dart';
import 'quick_config_pipeline.dart';
import 'quick_config_storage.dart';

/// A library entry is never edited in place: every application gets its own graph.
class SavedConfigChoice {
  final String name;
  final PipelineGraph? graph;
  final QuickConfig? quick;

  const SavedConfigChoice.graph(this.name, PipelineGraph value)
    : graph = value,
      quick = null;
  SavedConfigChoice.quick(QuickConfig value)
    : name = value.name,
      quick = value,
      graph = null;

  PipelineGraph prepare(VideoFile file, {required bool isZh}) {
    final preset = quick;
    PipelineGraph source;
    if (preset != null) {
      if (preset.fileType.name != file.fileMediaType.name) {
        throw const FormatException('Media type does not match');
      }
      final result = buildGraphFromQuickConfig(preset, isZh: isZh);
      // Applying only part of a saved preset would silently change its meaning.
      if (result.isEmpty || result.skippedNotes.isNotEmpty) {
        throw const FormatException('Preset needs editing before application');
      }
      source = result.graph;
    } else {
      source = graph!;
    }
    // JSON round trip also clones nested parameter lists/maps; graph.copy() is shallow.
    final copy = PipelineGraph.fromJson(
      jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
    ).copy();
    for (final node in copy.nodes.where(
      (n) => n.type == PipelineStepType.start && !n.isGate,
    )) {
      final declared = node.params['file_media_type'];
      if (declared != null && declared != file.fileMediaType.name) {
        throw const FormatException('Declared source media does not match');
      }
      node.params['file_media_type'] = file.fileMediaType.name;
      // Execution takes its input from the target VideoFile, never a template path.
      for (final key in ['filepath', 'file_path', 'input_path', 'path']) {
        node.params.remove(key);
      }
    }
    final errors = GraphExecutor.validateGraph(copy);
    if (errors.isNotEmpty) throw FormatException(errors.first);
    return copy;
  }

  bool supports(VideoFile file, {required bool isZh}) {
    try {
      prepare(file, isZh: isZh);
      return true;
    } catch (_) {
      return false;
    }
  }
}

Future<List<SavedConfigChoice>> loadSavedConfigChoices(AppState state) async {
  final library = await state.configService.loadLibrary();
  final quick = await QuickConfigStorage.loadAll(null);
  final choices = <SavedConfigChoice>[];
  for (final entry in library) {
    try {
      final graph = entry['graph'];
      if (graph is! Map<String, dynamic>) continue;
      choices.add(
        SavedConfigChoice.graph(
          entry['name'] as String? ?? '',
          PipelineGraph.fromJson(graph),
        ),
      );
    } catch (_) {
      // One damaged library entry must not hide the remaining presets.
    }
  }
  choices.addAll(quick.map(SavedConfigChoice.quick));
  return choices;
}

/// Shared by all home file cards; selection only changes this file's pipeline.
Future<void> showApplySavedConfig(
  BuildContext context,
  AppState state,
  VideoFile file, {
  Future<List<SavedConfigChoice>> Function()? loadChoices,
  bool fileOnlyInContainer = false,
}) async {
  final zh = state.config.language != 'en';
  void message(String text) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  try {
    final loaded = await (loadChoices?.call() ?? loadSavedConfigChoices(state));
    if (!context.mounted) return;
    final choices = loaded.where((c) => c.supports(file, isZh: zh)).toList();
    if (choices.isEmpty) {
      message(
        zh
            ? '配置库中没有适用于此文件的配置，请先在配置库中保存配置。'
            : 'No compatible saved configuration; save one in the library first.',
      );
      return;
    }
    final selected = await showDialog<SavedConfigChoice>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(zh ? '应用配置库' : 'Apply saved configuration'),
        content: SizedBox(
          width: 440,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: choices.length,
            itemBuilder: (_, index) {
              final choice = choices[index];
              return ListTile(
                leading: Icon(
                  choice.quick == null
                      ? Icons.account_tree_outlined
                      : Icons.tune,
                ),
                title: Text(
                  choice.name.isEmpty
                      ? (zh ? '未命名配置' : 'Untitled configuration')
                      : choice.name,
                ),
                subtitle: Text(
                  choice.quick == null
                      ? (zh ? '节点配置' : 'Node configuration')
                      : (zh ? '快捷配置' : 'Quick configuration'),
                ),
                onTap: () => Navigator.of(ctx).pop(choice),
              );
            },
          ),
        ),
        actions: [
          AppDialogAction(
            role: AppDialogActionRole.cancel,
            child: TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(zh ? '取消' : 'Cancel'),
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    final target = state.videoById(file.id);
    if (target == null) {
      message(
        zh
            ? '文件已被移除，未应用配置。'
            : 'File was removed; configuration was not applied.',
      );
      return;
    }
    final graph = selected.prepare(target, isZh: zh);
    state.updateVideoPipeline(target.id, graph);
    message(
      fileOnlyInContainer
          ? (zh
                ? '已应用到文件独立配置；容器运行仍使用容器配置。'
                : 'Applied to the file only; container runs still use the container configuration.')
          : (zh
                ? '已应用配置：${selected.name}'
                : 'Configuration applied: ${selected.name}'),
    );
  } catch (_) {
    message(
      zh
          ? '无法应用配置，请检查配置库中的配置。'
          : 'Could not apply configuration; check the saved preset.',
    );
  }
}
