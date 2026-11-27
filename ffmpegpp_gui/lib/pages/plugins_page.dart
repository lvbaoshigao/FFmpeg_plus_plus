import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/app_platform.dart';
import '../plugins/plugin_contributions.dart';
import '../plugins/plugin_manager.dart';
import '../plugins/plugin_manifest.dart';
import '../plugins/plugin_sdk.dart';
import '../providers/app_state.dart';
import '../widgets/adaptive_top_bar.dart';
import '../widgets/app_alert_dialog.dart';
import '../widgets/app_card.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mobile_glass_pill.dart';
import '../widgets/mobile_nav_scope.dart';
import '../widgets/mobile_ui.dart';
import '../widgets/option_menu_bar.dart';
import '../widgets/toast.dart';

/// Experimental plugin management. All executable work is delegated to the
/// manager; this page only collects user consent and displays host-owned UI.
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginIcon extends StatefulWidget {
  const _PluginIcon({
    required this.manager,
    required this.pluginId,
    required this.iconPath,
    required this.version,
    required this.enabled,
    this.size = 56,
  });

  final PluginManager manager;
  final String pluginId;
  final String? iconPath;
  final String version;
  final bool enabled;
  final double size;

  @override
  State<_PluginIcon> createState() => _PluginIconState();
}

class _PluginIconState extends State<_PluginIcon> {
  Future<Uint8List?>? _iconBytes;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(covariant _PluginIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager ||
        oldWidget.pluginId != widget.pluginId ||
        oldWidget.version != widget.version ||
        oldWidget.iconPath != widget.iconPath) {
      _loadIcon();
    }
  }

  void _loadIcon() {
    final path = widget.iconPath?.trim();
    _iconBytes = path == null || path.isEmpty
        ? null
        : widget.manager.iconBytes(widget.pluginId);
  }

  Widget _fallback(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Icon(
      Icons.extension_outlined,
      size: widget.size * 0.52,
      color: widget.enabled ? colors.primary : colors.onSurfaceVariant,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.enabled
            ? colors.primaryContainer.withValues(alpha: 0.7)
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: _iconBytes == null
          ? _fallback(context)
          : FutureBuilder<Uint8List?>(
              future: _iconBytes,
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes == null || bytes.isEmpty) return _fallback(context);
                return Image.memory(
                  bytes,
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => _fallback(context),
                );
              },
            ),
    );
  }
}

class _PluginsPageState extends State<PluginsPage> {
  final _operationBusy = ValueNotifier(false);
  bool get _busy => _operationBusy.value;

  @override
  void dispose() {
    _operationBusy.dispose();
    super.dispose();
  }

  bool get _zh => context.read<AppState>().config.language == 'zh';
  PluginManager? get _manager => context.read<AppState>().plugins;
  PluginManager get _readyManager =>
      _manager ??
      (throw const PluginException('Plugin manager is not initialized.'));

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _operationBusy.value = true;
    setState(() {});
    try {
      await action();
    } catch (error) {
      if (mounted) showToast(context, '$error', type: ToastType.error);
    } finally {
      if (mounted) {
        _operationBusy.value = false;
        setState(() {});
      }
    }
  }

  Future<void> _exportSdk() => _run(() async {
    final bytes = await PluginSdk.createArchive();
    if (!mounted) return;
    final saved = await FilePicker.saveFile(
      dialogTitle: _zh ? '导出插件开发 SDK' : 'Export plugin SDK',
      fileName: PluginSdk.archiveFileName,
      mimeType: 'application/zip',
      bytes: bytes,
    );
    if (saved != null && mounted) {
      showToast(
        context,
        _zh ? 'SDK 已导出' : 'SDK exported',
        type: ToastType.success,
      );
    }
  });

  Future<void> _install() => _run(() async {
    final manager = _readyManager;
    final picked = await FilePicker.pickFile(
      type: FileType.any,
      dialogTitle: _zh ? '选择插件包' : 'Choose plugin package',
    );
    if (picked == null || !mounted) return;
    if (!picked.name.toLowerCase().endsWith('.fppplugin')) {
      throw FormatException(
        _zh ? '请选择 .fppplugin 插件包' : 'Choose a .fppplugin package',
      );
    }
    const maxPackageBytes = 16 * 1024 * 1024;
    final reportedSize = picked.lengthSync();
    if (reportedSize != null && reportedSize > maxPackageBytes) {
      throw const FormatException('Plugin package exceeds 16 MiB.');
    }
    // Stream with a hard bound, including Android content URIs without a path.
    // Inspection independently validates ZIP entry and expanded-size quotas.
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in picked.readAsByteStream()) {
      if (buffer.length + chunk.length > maxPackageBytes) {
        throw const FormatException('Plugin package exceeds 16 MiB.');
      }
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    if (!mounted) return;
    final inspection = await manager.inspectPackage(bytes);
    if (!mounted) return;
    final proceed = await _confirm(
      _zh ? '安装插件预览' : 'Install plugin preview',
      _manifestDetails(
        inspection.manifest,
        extra:
            '${inspection.filePaths.length} files · ${inspection.expandedSize} bytes',
      ),
      _zh ? '安装（默认禁用）' : 'Install disabled',
    );
    if (!proceed || !mounted) return;
    await _readyManager.installPackage(Uint8List.fromList(bytes));
    if (mounted) {
      showToast(
        context,
        _zh ? '插件已安装，尚未启用' : 'Plugin installed and disabled',
        type: ToastType.success,
      );
    }
  });

  Future<bool> _confirm(String title, Widget content, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AppAlertDialog(
          scrollable: true,
          title: Text(title),
          content: SizedBox(width: 480, child: content),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_zh ? '取消' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _enable(InstalledPlugin plugin) => _run(() async {
    final manifest = plugin.manifest;
    final requested = _permissionKeys(manifest);
    final granted = <String>{};
    var trustAcknowledged = false;
    var previewAcknowledged = !manifest.isPreview;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => AppAlertDialog(
          scrollable: true,
          title: Text(_zh ? '启用前请确认风险' : 'Review risks before enabling'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  manifest.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _zh
                              ? '本应用仅校验插件包格式和接口兼容性，不会对插件代码进行安全检测或审计。启用后，其声明的节点可在工作流中运行；请自行核对来源、功能和权限请求，并自行承担使用风险。因不当使用造成的任何后果，开发者不承担责任。'
                              : 'This app validates package format and API compatibility only; it does not security-test or audit plugin code. Enabled plugins can run their declared nodes in workflows. Review the source, behavior, and permissions yourself and accept the risk. Developers are not responsible for consequences of misuse.',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _zh
                        ? '我已核对插件来源，并确认仍要启用'
                        : 'I have reviewed the source and want to enable this plugin',
                  ),
                  value: trustAcknowledged,
                  onChanged: (value) =>
                      refresh(() => trustAcknowledged = value == true),
                ),
                if (manifest.isPreview)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _zh
                          ? '我了解：这是预览版，可能不稳定'
                          : 'I understand this preview may be unstable',
                    ),
                    value: previewAcknowledged,
                    onChanged: (value) =>
                        refresh(() => previewAcknowledged = value == true),
                  ),
                const Divider(height: 24),
                Text(
                  _zh
                      ? '可选权限（未选即拒绝）'
                      : 'Optional permissions (unchecked means denied)',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                if (requested.isEmpty)
                  Text(
                    _zh
                        ? '此插件未请求文件或网络权限。'
                        : 'No file or network permissions requested.',
                  ),
                for (final permission in requested)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_permissionLabel(permission)),
                    subtitle: Text(permission),
                    value: granted.contains(permission),
                    onChanged: (value) => refresh(() {
                      value == true
                          ? granted.add(permission)
                          : granted.remove(permission);
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_zh ? '取消' : 'Cancel'),
            ),
            FilledButton.icon(
              onPressed: trustAcknowledged && previewAcknowledged
                  ? () => Navigator.pop(ctx, true)
                  : null,
              icon: const Icon(Icons.verified_user_outlined),
              label: Text(_zh ? '确认并启用' : 'Confirm and enable'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    await _readyManager.setEnabled(
      manifest.id,
      true,
      previewAcknowledged: previewAcknowledged,
      grantedPermissions: granted,
    );
  });

  Set<String> _permissionKeys(PluginManifest manifest) =>
      manifest.permissions.grantKeys;

  String _permissionLabel(String key) => switch (key) {
    'files.read' => _zh ? '读取插件私有数据目录' : 'Read private plugin data',
    'files.write' => _zh ? '写入插件私有数据目录' : 'Write private plugin data',
    _ => _zh ? '访问 ${key.substring(8)}' : 'Access ${key.substring(8)}',
  };

  Future<void> _uninstall(InstalledPlugin plugin) => _run(() async {
    final accepted = await _confirm(
      _zh ? '卸载插件？' : 'Uninstall plugin?',
      Text(
        _zh
            ? '将删除 ${plugin.manifest.name}。现有图中的插件节点会保留，但无法执行。'
            : 'Remove ${plugin.manifest.name}? Existing plugin nodes are retained but cannot execute.',
      ),
      _zh ? '卸载' : 'Uninstall',
    );
    if (accepted && mounted) await _readyManager.uninstall(plugin.manifest.id);
  });

  Future<void> _rollback(InstalledPlugin plugin) => _run(() async {
    if (await _confirm(
          _zh ? '回滚插件？' : 'Roll back plugin?',
          Text(
            _zh
                ? '恢复上一版本并禁用插件；重新启用时会再次检查权限。'
                : 'Restore the previous version and disable this plugin; review permissions again before enabling.',
          ),
          _zh ? '回滚' : 'Roll back',
        ) &&
        mounted) {
      await _readyManager.rollback(plugin.manifest.id);
    }
  });

  Future<void> _selfCheck(InstalledPlugin plugin) => _run(() async {
    await _readyManager.selfCheck(plugin.manifest.id);
    if (mounted) {
      showToast(
        context,
        _zh ? '插件元数据自检通过' : 'Plugin metadata verified',
        type: ToastType.success,
      );
    }
  });

  void _assertActive(InstalledPlugin plugin) {
    final current = _readyManager.plugin(plugin.manifest.id);
    if (!_readyManager.featureEnabled ||
        current == null ||
        !current.enabled ||
        current.manifest.version != plugin.manifest.version) {
      throw FormatException(
        _zh ? '插件状态已变化，请重新预览' : 'Plugin state changed; preview again.',
      );
    }
  }

  Future<void> _importTheme(
    InstalledPlugin plugin,
    Map<String, dynamic> json,
  ) => _run(() async {
    _assertActive(plugin);
    final state = context.read<AppState>();
    final preset = PluginThemePreset.fromJson(json);
    final changes = preset.preview(state.config);
    final accepted = await _confirm(
      _zh ? '主题导入预览' : 'Preview theme import',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            preset.displayName(state.config.language),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (changes.isEmpty)
            Text(
              _zh ? '当前配置已与主题一致。' : 'The theme already matches your settings.',
            ),
          for (final change in changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${change.field}: ${change.before} → ${change.after}',
              ),
            ),
        ],
      ),
      _zh ? '应用主题配置' : 'Apply theme settings',
    );
    if (!accepted || !mounted) return;
    _assertActive(plugin);
    await state.updateConfigAndFlush(preset.applyTo);
    if (mounted) {
      showToast(
        context,
        _zh ? '主题配置已应用' : 'Theme settings applied',
        type: ToastType.success,
      );
    }
  });

  Future<void> _importAi(
    InstalledPlugin plugin,
    Map<String, dynamic> json,
  ) => _run(() async {
    _assertActive(plugin);
    final state = context.read<AppState>();
    final catalog = PluginAiCatalog.fromJson(json);
    final mergeTargets = <String, String>{};
    final selectedPlan = await showDialog<PluginAiImportPlan>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) {
          PluginAiImportPlan? plan;
          String? error;
          try {
            plan = catalog.preview(state.config, mergeTargets: mergeTargets);
          } on FormatException catch (problem) {
            error = problem.message;
          }
          return AppAlertDialog(
            scrollable: true,
            title: Text(_zh ? 'AI 配置导入预览' : 'Preview AI configuration import'),
            content: SizedBox(
              width: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _zh
                        ? '默认新增为禁用配置；不会导入密钥或切换当前供应商。选择现有配置时仅追加缺失模型。'
                        : 'New profiles start disabled. Keys and the active provider stay unchanged. Merging only adds missing models.',
                  ),
                  const SizedBox(height: 12),
                  for (final source in catalog.profiles) ...[
                    Text(source.name),
                    SelectableText(source.apiUrl),
                    const SizedBox(height: 6),
                    OptionMenuBar<String>(
                      key: ValueKey('ai_target_${source.sourceId}'),
                      label: _zh ? '导入方式' : 'Import target',
                      value: mergeTargets[source.sourceId] ?? '',
                      items: [
                        OptionItem(
                          '',
                          _zh ? '新增配置（禁用）' : 'New disabled profile',
                        ),
                        for (final target in state.config.aiProfiles)
                          OptionItem(
                            target.id,
                            '${_zh ? '合并到' : 'Merge into'} ${target.name}',
                          ),
                      ],
                      onChanged: (target) => refresh(() {
                        if (target.isEmpty) {
                          mergeTargets.remove(source.sourceId);
                        } else {
                          mergeTargets[source.sourceId] = target;
                        }
                      }),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (error != null)
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (plan != null) ...[
                    Text(
                      _zh
                          ? '新增 ${plan.newProfileCount} 个配置，合并 ${plan.mergedProfileCount} 个配置，追加 ${plan.addedModelCount} 个模型'
                          : '${plan.newProfileCount} new profiles, ${plan.mergedProfileCount} merged profiles, ${plan.addedModelCount} added models',
                    ),
                    for (final item in plan.items)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${item.name}: ${item.addedModelIds.take(20).join(', ')}${item.addedModelIds.length > 20 ? ' …' : ''}',
                        ),
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(_zh ? '取消' : 'Cancel'),
              ),
              FilledButton(
                onPressed: plan == null ? null : () => Navigator.pop(ctx, plan),
                child: Text(_zh ? '导入' : 'Import'),
              ),
            ],
          );
        },
      ),
    );
    if (selectedPlan == null || !mounted) return;
    _assertActive(plugin);
    await state.updateConfigAndFlush(selectedPlan.applyTo);
    if (mounted) {
      showToast(
        context,
        _zh ? 'AI 配置已导入' : 'AI configuration imported',
        type: ToastType.success,
      );
    }
  });

  String? _pluginAuthor(PluginManifest manifest) {
    final author = manifest.basicInfo.author?.trim();
    return author == null || author.isEmpty ? null : author;
  }

  String _formatNodeName(PluginNodeDefinition node) =>
      node.name.trim().isEmpty ? node.id : node.name;

  Widget _nodeCard(InstalledPlugin plugin, PluginNodeDefinition node) {
    final enabled = plugin.isNodeEnabled(node.id);
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(
            node.isLogic ? Icons.account_tree_outlined : Icons.hub_outlined,
            color: colors.primary,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatNodeName(node),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  node.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (node.fun.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      node.fun,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                enabled ? (_zh ? '启用' : 'On') : (_zh ? '禁用' : 'Off'),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Switch.adaptive(
                value: enabled,
                onChanged: _busy
                    ? null
                    : (value) => _setNodeEnabled(plugin, node, value),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _setNodeEnabled(
    InstalledPlugin plugin,
    PluginNodeDefinition node,
    bool enabled,
  ) => _run(
    () => _readyManager.setNodeEnabled(plugin.manifest.id, node.id, enabled),
  );

  String _contributionName(Map<String, dynamic> json, String fallback) {
    final name = json['name'];
    if (name is String) return name;
    if (name is Map) {
      return (name[_zh ? 'zh' : 'en'] ?? name['en'] ?? name['zh'] ?? fallback)
          .toString();
    }
    return fallback;
  }

  Widget _manifestDetails(
    PluginManifest manifest, {
    String? extra,
    bool includeIdentity = true,
  }) {
    final author = _pluginAuthor(manifest);
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (includeIdentity) ...[
          Text(manifest.name, style: Theme.of(context).textTheme.titleLarge),
          Text(manifest.version, style: Theme.of(context).textTheme.bodyMedium),
          if (author != null && author.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Flexible(child: Text(author)),
                ],
              ),
            ),
          const SizedBox(height: 10),
        ],
        if (manifest.summary.trim().isNotEmpty) Text(manifest.summary),
        const SizedBox(height: 10),
        SelectableText(
          manifest.id,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('API ${manifest.apiVersion}')),
            Chip(label: Text(manifest.appVersion)),
            Chip(
              label: Text('${manifest.nodes.length} ${_zh ? '个节点' : 'nodes'}'),
            ),
            if (manifest.isPreview)
              Chip(
                avatar: const Icon(Icons.science_outlined, size: 16),
                label: Text(_zh ? '预览版' : 'Preview'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _zh ? '资源限制' : 'Resource limits',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(
          '${manifest.limits.memoryMb} MiB · ${manifest.limits.timeMs} ms · ${manifest.limits.fuel} fuel',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (manifest.dependencies.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            _zh ? '依赖项' : 'Dependencies',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final dependency in manifest.dependencies)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${dependency.id} · ${dependency.version}'),
            ),
        ],
        if (_permissionKeys(manifest).isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            _zh ? '请求的权限' : 'Requested permissions',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final permission in _permissionKeys(manifest))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_permissionLabel(permission)),
            ),
        ],
        if (extra != null) ...[const SizedBox(height: 12), Text(extra)],
      ],
    );
  }

  void _details(InstalledPlugin selected, {bool configureNodes = false}) {
    final manager = _readyManager;
    final pluginId = selected.manifest.id;
    showDialog<void>(
      context: context,
      builder: (ctx) => AnimatedBuilder(
        animation: Listenable.merge([manager, _operationBusy]),
        builder: (ctx, _) {
          final plugin = manager.plugin(pluginId);
          if (plugin == null) {
            return AppAlertDialog(
              title: Text(_zh ? '插件已卸载' : 'Plugin is no longer installed'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(_zh ? '关闭' : 'Close'),
                ),
              ],
            );
          }
          final manifest = plugin.manifest;
          final author = _pluginAuthor(manifest);
          return AppAlertDialog(
            scrollable: true,
            title: Text(
              configureNodes
                  ? (_zh ? '节点配置' : 'Node configuration')
                  : (_zh ? '插件详情' : 'Plugin details'),
            ),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PluginIcon(
                        manager: _readyManager,
                        pluginId: manifest.id,
                        iconPath: manifest.basicInfo.iconPath,
                        version: manifest.version,
                        enabled: plugin.enabled,
                        size: 56,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              manifest.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text('v${manifest.version}'),
                            if (author != null && author.isNotEmpty)
                              Text(
                                '${_zh ? '作者' : 'By'} $author',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (!configureNodes)
                    _manifestDetails(manifest, includeIdentity: false),
                  if (manifest.nodes.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      _zh ? '声明的节点' : 'Declared nodes',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _zh
                          ? '可逐项控制节点是否可用。更改会保存到插件设置。'
                          : 'Choose which declared nodes are available. Changes are saved with the plugin settings.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    for (final node in manifest.nodes) _nodeCard(plugin, node),
                  ],
                  if (!configureNodes) ...[
                    const SizedBox(height: 18),
                    Text(
                      _zh ? '已授予的权限' : 'Granted permissions',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (plugin.grantedPermissions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_zh ? '无' : 'None'),
                      ),
                    for (final permission in plugin.grantedPermissions)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_permissionLabel(permission)),
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(_zh ? '关闭' : 'Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _actions() => [
    MobileGlassPillAction(
      color: Theme.of(context).colorScheme.onSurface,
      icon: Icons.file_download_outlined,
      tooltip: _zh ? '导入插件' : 'Import plugin',
      showDisk: false,
      onTap: _busy || _manager == null ? null : _install,
    ),
    MobileGlassPillAction(
      color: Theme.of(context).colorScheme.onSurface,
      icon: Icons.add,
      tooltip: _zh ? '新建插件 · 导出 SDK' : 'New plugin · Export SDK',
      showDisk: false,
      onTap: _busy ? null : _exportSdk,
    ),
  ];

  Widget _card(InstalledPlugin plugin, String style) {
    final manifest = plugin.manifest;
    final colors = Theme.of(context).colorScheme;
    final author = _pluginAuthor(manifest);
    final canEnable =
        context.read<AppState>().config.pluginsEnabled &&
        _readyManager.featureEnabled;
    return AppCard(
      key: ValueKey('plugin_${manifest.id}'),
      style: style,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PluginIcon(
                manager: _readyManager,
                pluginId: manifest.id,
                iconPath: manifest.basicInfo.iconPath,
                version: manifest.version,
                enabled: plugin.enabled,
                size: 56,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manifest.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 7,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('v${manifest.version}'),
                        if (manifest.isPreview)
                          _metadataBadge(
                            icon: Icons.science_outlined,
                            label: _zh ? '预览版' : 'Preview',
                          ),
                        _metadataBadge(
                          icon: plugin.enabled
                              ? Icons.check_circle_outline
                              : Icons.pause_circle_outline,
                          label: plugin.enabled
                              ? (_zh ? '已启用' : 'Enabled')
                              : (_zh ? '已禁用' : 'Disabled'),
                          color: plugin.enabled
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                    if (author != null && author.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          '${_zh ? '作者' : 'By'} $author',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
              IgnorePointer(
                ignoring: _busy,
                child: ScaleMenuButton<String>(
                  icon: Icons.more_horiz,
                  tooltip: _zh ? '插件操作' : 'Plugin actions',
                  items: [
                    OptionItem(
                      'details',
                      _zh ? '详情' : 'Details',
                      icon: Icons.info_outline,
                    ),
                    OptionItem(
                      'selfcheck',
                      _zh ? '元数据自检' : 'Verify metadata',
                      icon: Icons.fact_check_outlined,
                    ),
                    if (plugin.hasRollback)
                      OptionItem(
                        'rollback',
                        _zh ? '回滚上一版本' : 'Roll back',
                        icon: Icons.undo,
                      ),
                    OptionItem(
                      'uninstall',
                      _zh ? '卸载' : 'Uninstall',
                      icon: Icons.delete_outline,
                    ),
                  ],
                  onSelected: (action) {
                    switch (action) {
                      case 'details':
                        _details(plugin);
                      case 'selfcheck':
                        _selfCheck(plugin);
                      case 'rollback':
                        _rollback(plugin);
                      case 'uninstall':
                        _uninstall(plugin);
                    }
                  },
                ),
              ),
            ],
          ),
          if (manifest.summary.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(manifest.summary),
          ],
          if (plugin.lastError != null)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: colors.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      plugin.lastError!,
                      style: TextStyle(color: colors.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: ValueKey('plugin_toggle_${manifest.id}'),
                onPressed: _busy
                    ? null
                    : plugin.enabled
                    ? () => _run(
                        () => _readyManager.setEnabled(manifest.id, false),
                      )
                    : canEnable
                    ? () => _enable(plugin)
                    : null,
                icon: Icon(
                  plugin.enabled
                      ? Icons.pause_circle_outline
                      : Icons.play_arrow,
                ),
                label: Text(
                  plugin.enabled
                      ? (_zh ? '禁用插件' : 'Disable plugin')
                      : (_zh ? '启用插件' : 'Enable plugin'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _details(plugin),
                icon: const Icon(Icons.info_outline),
                label: Text(_zh ? '查看详情' : 'View details'),
              ),
              if (manifest.nodes.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _details(plugin, configureNodes: true),
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(_zh ? '节点配置' : 'Configure nodes'),
                ),
              for (final theme in manifest.themes)
                OutlinedButton.icon(
                  onPressed:
                      _busy || !plugin.enabled || !_readyManager.featureEnabled
                      ? null
                      : () => _importTheme(plugin, theme),
                  icon: const Icon(Icons.palette_outlined),
                  label: Text(
                    _contributionName(theme, _zh ? '主题预览' : 'Preview theme'),
                  ),
                ),
              for (final catalog in manifest.aiConfigs)
                OutlinedButton.icon(
                  onPressed:
                      _busy || !plugin.enabled || !_readyManager.featureEnabled
                      ? null
                      : () => _importAi(plugin, catalog),
                  icon: const Icon(Icons.smart_toy_outlined),
                  label: Text(
                    _contributionName(
                      catalog,
                      _zh ? 'AI 配置预览' : 'Preview AI configuration',
                    ),
                  ),
                ),
            ],
          ),
          if (manifest.nodes.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 6),
              leading: Icon(Icons.account_tree_outlined, color: colors.primary),
              title: Text(_zh ? '声明的节点' : 'Declared nodes'),
              subtitle: Text(
                _zh
                    ? '${manifest.nodes.length} 个节点 · 可逐项启用或禁用'
                    : '${manifest.nodes.length} nodes · manage individually',
              ),
              children: [
                for (final node in manifest.nodes) _nodeCard(plugin, node),
              ],
            ),
        ],
      ),
    );
  }

  Widget _metadataBadge({
    required IconData icon,
    required String label,
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: tint),
          ),
        ],
      ),
    );
  }

  Widget _systemNotice({
    required bool settingsEnabled,
    required bool runtimeReady,
  }) {
    if (settingsEnabled && runtimeReady) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final color = settingsEnabled
        ? colors.tertiaryContainer
        : colors.surfaceContainerHigh;
    final onColor = settingsEnabled
        ? colors.onTertiaryContainer
        : colors.onSurface;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            settingsEnabled
                ? Icons.hourglass_top_rounded
                : Icons.toggle_off_outlined,
            color: onColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  settingsEnabled
                      ? (_zh
                            ? '插件设置已开启，运行时尚未就绪'
                            : 'Plugin setting is on; runtime is not ready')
                      : (_zh
                            ? '插件系统在设置中处于关闭状态'
                            : 'Plugin system is turned off in Settings'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: onColor),
                ),
                const SizedBox(height: 3),
                Text(
                  settingsEnabled
                      ? (_zh
                            ? '当前已保存的设置允许使用插件，但插件运行时/平台能力尚未就绪；启用和执行操作暂不可用。'
                            : 'The saved setting allows plugins, but the plugin runtime or platform capability is not ready yet. Enabling and execution are temporarily unavailable.')
                      : (_zh
                            ? '如需使用插件，请前往 设置 → 实验性功能，开启“启用插件系统”。'
                            : 'To use plugins, go to Settings → Experimental features and turn on “Enable plugins”.'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: onColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statChip({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: colors.onSecondaryContainer),
          const SizedBox(width: 7),
          Text(label, style: TextStyle(color: colors.onSecondaryContainer)),
          const SizedBox(width: 7),
          Text(
            value,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: colors.onSecondaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppState, String>(
      (state) => state.config.language,
    );
    final style = context.select<AppState, String>(
      (state) => state.config.cardStyle,
    );
    final zh = language == 'zh';
    final settingsEnabled = context.select<AppState, bool>(
      (state) => state.config.pluginsEnabled,
    );
    final manager = context.select<AppState, PluginManager?>(
      (state) => state.plugins,
    );
    if (manager == null) {
      return Column(
        children: [
          AdaptiveTopBar(
            expandedBuilder: (_) => GlassTopBar(
              title: Text(zh ? '插件' : 'Plugins'),
              actions: _actions(),
            ),
            compactBuilder: (_) => MobilePillTopBar(
              title: Text(zh ? '插件' : 'Plugins'),
              actions: _actions(),
              collapseActions: false,
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                zh ? '插件管理器尚未初始化' : 'Plugin manager is not initialized.',
              ),
            ),
          ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) => Column(
        children: [
          AdaptiveTopBar(
            expandedBuilder: (_) => GlassTopBar(
              title: Text(zh ? '插件' : 'Plugins'),
              actions: _actions(),
            ),
            compactBuilder: (_) => MobilePillTopBar(
              title: Text(zh ? '插件' : 'Plugins'),
              actions: _actions(),
              collapseActions: false,
            ),
          ),
          if (_busy)
            LinearProgressIndicator(
              minHeight: 2,
              value: MediaQuery.disableAnimationsOf(context) ? 0.5 : null,
            ),
          Expanded(
            child: ListView(
              addRepaintBoundaries: false,
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                isMobilePlatform ? mobileNavClearanceOf(context) + 16 : 16,
              ),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1024),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!settingsEnabled)
                          _systemNotice(
                            settingsEnabled: false,
                            runtimeReady: manager.featureEnabled,
                          )
                        else if (!manager.featureEnabled)
                          _systemNotice(
                            settingsEnabled: true,
                            runtimeReady: false,
                          ),
                        AppCard(
                          style: style,
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(18),
                          child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            runSpacing: 14,
                            spacing: 24,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 520,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      zh ? '已安装插件' : 'Installed plugins',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      zh
                                          ? '仅启用你信任的插件，并按需管理每个声明节点。'
                                          : 'Enable only plugins you trust, and manage each declared node individually.',
                                    ),
                                  ],
                                ),
                              ),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  _statChip(
                                    icon: Icons.extension_outlined,
                                    label: zh ? '插件' : 'Plugins',
                                    value: '${manager.plugins.length}',
                                  ),
                                  _statChip(
                                    icon: Icons.check_circle_outline,
                                    label: zh ? '已启用' : 'Enabled',
                                    value:
                                        '${manager.plugins.where((plugin) => plugin.enabled).length}',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (manager.plugins.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 48),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.extension_outlined,
                                  size: 52,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  zh ? '尚未安装插件' : 'No plugins installed',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  zh
                                      ? '导入 .fppplugin，或点击新建按钮导出开发 SDK。'
                                      : 'Import a .fppplugin package, or export the development SDK to get started.',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        for (final plugin in manager.plugins)
                          _card(plugin, style),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
