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

class _PluginsPageState extends State<PluginsPage> {
  bool _busy = false;
  bool get _zh => context.read<AppState>().config.language == 'zh';
  PluginManager? get _manager => context.read<AppState>().plugins;
  PluginManager get _readyManager =>
      _manager ??
      (throw const PluginException('Plugin manager is not initialized.'));

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) showToast(context, '$error', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
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
    var acknowledged = !manifest.isPreview;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => AppAlertDialog(
          scrollable: true,
          title: Text(_zh ? '启用插件' : 'Enable plugin'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${manifest.name} ${manifest.version}'),
                if (manifest.isPreview)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _zh
                          ? '我了解：这是预览版，可能不稳定'
                          : 'I understand this preview may be unstable',
                    ),
                    value: acknowledged,
                    onChanged: (value) =>
                        refresh(() => acknowledged = value == true),
                  ),
                const SizedBox(height: 12),
                Text(
                  _zh
                      ? '可选权限（未选即拒绝）'
                      : 'Optional permissions (unchecked means denied)',
                ),
                if (requested.isEmpty)
                  Text(
                    _zh
                        ? '此插件未请求文件或网络权限'
                        : 'No file or network permissions requested',
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
            FilledButton(
              onPressed: acknowledged ? () => Navigator.pop(ctx, true) : null,
              child: Text(_zh ? '启用并校验元数据' : 'Enable and verify metadata'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    await _readyManager.setEnabled(
      manifest.id,
      true,
      previewAcknowledged: acknowledged,
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

  String _contributionName(Map<String, dynamic> json, String fallback) {
    final name = json['name'];
    if (name is String) return name;
    if (name is Map) {
      return (name[_zh ? 'zh' : 'en'] ?? name['en'] ?? name['zh'] ?? fallback)
          .toString();
    }
    return fallback;
  }

  Widget _manifestDetails(PluginManifest manifest, {String? extra}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '${manifest.name} · ${manifest.version}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      SelectableText(manifest.id),
      const SizedBox(height: 8),
      Text(manifest.summary),
      const SizedBox(height: 8),
      Text('API ${manifest.apiVersion} · ${manifest.appVersion}'),
      Text(
        '${manifest.limits.memoryMb} MiB · ${manifest.limits.timeMs} ms · ${manifest.limits.fuel} fuel',
      ),
      for (final dependency in manifest.dependencies)
        Text(
          '${_zh ? '依赖' : 'Requires'} ${dependency.id} ${dependency.version}',
        ),
      Text(
        _zh ? '${manifest.nodes.length} 个节点' : '${manifest.nodes.length} nodes',
      ),
      if (manifest.isPreview)
        Text(_zh ? '预览版：可能不稳定' : 'Preview: may be unstable'),
      for (final permission in _permissionKeys(manifest))
        Text(_permissionLabel(permission)),
      if (extra != null) Text(extra),
    ],
  );

  void _details(InstalledPlugin plugin) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        scrollable: true,
        title: Text(_zh ? '插件详情' : 'Plugin details'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _manifestDetails(plugin.manifest),
              const SizedBox(height: 12),
              Text(
                _zh ? '已授予的权限' : 'Granted permissions',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (plugin.grantedPermissions.isEmpty) Text(_zh ? '无' : 'None'),
              for (final permission in plugin.grantedPermissions)
                Text(_permissionLabel(permission)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_zh ? '关闭' : 'Close'),
          ),
        ],
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
    return AppCard(
      key: ValueKey('plugin_${manifest.id}'),
      style: style,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.extension_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manifest.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${manifest.version}${manifest.isPreview ? ' · Preview' : ''} · ${plugin.enabled ? (_zh ? '已启用' : 'Enabled') : (_zh ? '已禁用' : 'Disabled')}',
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
          const SizedBox(height: 8),
          Text(manifest.summary),
          if (plugin.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                plugin.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: ValueKey('plugin_toggle_${manifest.id}'),
                onPressed: _busy
                    ? null
                    : plugin.enabled
                    ? () => _run(
                        () => _readyManager.setEnabled(manifest.id, false),
                      )
                    : () => _enable(plugin),
                icon: Icon(plugin.enabled ? Icons.pause : Icons.play_arrow),
                label: Text(
                  plugin.enabled
                      ? (_zh ? '禁用' : 'Disable')
                      : (_zh ? '启用' : 'Enable'),
                ),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _details(plugin),
                child: Text(_zh ? '详情' : 'Details'),
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
                if (!_readyManager.featureEnabled)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      zh
                          ? '请在设置 → 实验性功能中启用插件系统。'
                          : 'Enable plugins in Settings → Experimental features.',
                    ),
                  ),
                if (_readyManager.plugins.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      children: [
                        const Icon(Icons.extension_outlined, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          zh ? '尚未安装插件' : 'No plugins installed',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          zh
                              ? '导入 .fppplugin，或点击新建按钮导出开发 SDK。'
                              : 'Import a .fppplugin or use New to export the development SDK.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                for (final plugin in _readyManager.plugins)
                  _card(plugin, style),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
