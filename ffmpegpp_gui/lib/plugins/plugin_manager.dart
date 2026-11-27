import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'plugin_contributions.dart';
import 'plugin_manifest.dart';
import 'plugin_node_catalog.dart';
import 'plugin_permissions.dart';
import 'plugin_runtime.dart';
import 'plugin_storage.dart' hide validatePluginRelativePath;
import 'plugin_storage.dart' as storage_paths show validatePluginRelativePath;

export 'plugin_runtime.dart';

class InstalledPlugin {
  final PluginManifest manifest;
  final bool enabled;
  final Set<String> grantedPermissions;
  final bool hasRollback;
  final String? lastError;
  InstalledPlugin({
    required this.manifest,
    this.enabled = false,
    Set<String> grantedPermissions = const {},
    this.hasRollback = false,
    this.lastError,
  }) : grantedPermissions = Set.unmodifiable(grantedPermissions);
}

class PluginPackageInspection {
  final PluginManifest manifest;
  final List<String> filePaths;
  final bool hasModule;
  final int compressedSize;
  final int expandedSize;
  PluginPackageInspection({
    required this.manifest,
    required List<String> filePaths,
    required this.hasModule,
    required this.compressedSize,
    required this.expandedSize,
  }) : filePaths = List.unmodifiable(filePaths);
}

/// Lifecycle owner: initialization reads declarations only. Executable metadata
/// is rechecked before a saved enabled selection becomes available for execution.
class PluginManager extends ChangeNotifier {
  final Directory root;
  final PluginRuntime runtime;
  final String appVersion;
  final PluginStorage _storage;
  late final PluginPermissionHost _host;
  final PluginNodeCatalog _catalog;
  final Map<String, PluginStoredRecord> _records = {};
  final Map<String, int> _epochs = {};
  final Set<String> _verified = {};
  List<InstalledPlugin> _snapshot = const [];
  Future<void> _mutationTail = Future.value();
  bool _initialized = false;
  bool _featureEnabled = false;
  bool _disposed = false;
  int _featureRequest = 0;

  PluginManager({
    required this.root,
    required this.runtime,
    required this.appVersion,
    PluginStorage? storage,
    PluginPermissionHost? permissionHost,
    PluginNodeCatalog? catalog,
  }) : _storage = storage ?? PluginStorage(root),
       _catalog = catalog ?? PluginNodeCatalog.instance {
    _host = permissionHost ?? PluginPermissionHost(_storage);
    PluginVersion.parse(appVersion);
  }

  bool get featureEnabled => _featureEnabled;
  List<InstalledPlugin> get plugins => _snapshot;

  /// Capture before invoking, then check again immediately before applying a
  /// returned operation in an asynchronous application task.
  int generation(String id) => _epochs[id] ?? 0;
  bool isActive(String id, {int? generation}) {
    if (!_featureEnabled ||
        _disposed ||
        _records[id]?.enabled != true ||
        !_verified.contains(id) ||
        (generation != null && generation != (_epochs[id] ?? 0))) {
      return false;
    }
    try {
      _validateDependencies(id, _records, requireVerified: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  InstalledPlugin? plugin(String id) {
    for (final item in _snapshot) {
      if (item.manifest.id == id) return item;
    }
    return null;
  }

  Future<void> initialize() => _mutate(() async {
    if (_initialized) return;
    await _storage.initialize();
    final records = await _storage.load();
    final loaded = <String, PluginStoredRecord>{};
    for (final record in records) {
      final manifest = _manifest(record);
      _validateContributions(manifest);
      await _storage.validateVersion(record.version);
      if (record.previousVersion != null) {
        final previous = PluginManifest.fromJson(
          record.previousVersion!.manifest,
        );
        if (previous.id != manifest.id) {
          throw const PluginException(
            'Rollback plugin identity does not match.',
          );
        }
      }
      PluginPermissionHost.validateGrants(
        manifest.permissions,
        record.grantedPermissions,
      );
      loaded[manifest.id] = record;
    }
    _records.addAll(loaded);
    _initialized = true;
    _publish();
  });

  Future<void> setFeatureEnabled(bool enabled) {
    final request = ++_featureRequest;
    if (!enabled) {
      _featureEnabled = false;
      _suspend(_records.keys);
      _publish();
    }
    return _mutate(() async {
      _requireInitialized();
      if (request != _featureRequest || !enabled) return;
      _featureEnabled = true;
      _verified.clear();
      final next = Map<String, PluginStoredRecord>.of(_records);
      final pending = next.values
          .where((record) => record.enabled)
          .map((record) => record.id)
          .toSet();
      while (pending.isNotEmpty) {
        var progress = false;
        for (final id in pending.toList()) {
          final manifest = _manifest(next[id]!);
          if (manifest.dependencies.any(
            (dependency) => pending.contains(dependency.id),
          )) {
            continue;
          }
          try {
            _checkFeatureRequest(request);
            _validateDependencies(id, next, requireVerified: true);
            final epoch = _epochs[id] ?? 0;
            await _checkMetadata(next[id]!, () {
              _checkFeatureRequest(request);
              _checkEpoch(id, epoch);
            });
            _verified.add(id);
          } catch (error) {
            _checkFeatureRequest(request);
            next[id] = _copy(
              next[id]!,
              enabled: false,
              clearGrants: true,
              lastError: _safeError(error),
            );
          }
          pending.remove(id);
          progress = true;
        }
        if (!progress) {
          for (final id in pending) {
            next[id] = _copy(
              next[id]!,
              enabled: false,
              clearGrants: true,
              lastError: 'Cyclic plugin dependencies.',
            );
          }
          pending.clear();
        }
      }
      _checkFeatureRequest(request);
      try {
        await _commit(next);
      } catch (_) {
        _verified.clear();
        _publish();
        rethrow;
      }
    });
  }

  Future<PluginPackageInspection> inspectPackage(Uint8List bytes) async {
    final contents = decodePluginPackage(Uint8List.fromList(bytes));
    final manifest = _validatePackage(contents);
    return PluginPackageInspection(
      manifest: manifest,
      filePaths: contents.files.keys.toList()..sort(),
      hasModule: manifest.modulePath != null,
      compressedSize: contents.compressedSize,
      expandedSize: contents.expandedSize,
    );
  }

  Future<InstalledPlugin> installPackage(Uint8List bytes) {
    final input = Uint8List.fromList(bytes);
    return _mutate(() async {
      _requireInitialized();
      final contents = decodePluginPackage(input);
      final manifest = _validatePackage(contents);
      final old = _records[manifest.id];
      if (old == null && _records.length >= 256) {
        throw const PluginException('Plugin installation limit reached.');
      }
      if (old != null &&
          PluginVersion.parse(
                manifest.version,
              ).compareTo(PluginVersion.parse(_manifest(old).version)) <=
              0) {
        throw const PluginException(
          'Only a newer plugin version can replace an installation; use rollback to restore a version.',
          code: 'version_not_newer',
        );
      }
      final suspended = _suspend(_affected(manifest.id));
      _publish();
      PluginStoredVersion? staged;
      try {
        staged = await _storage.stagePackage(contents, manifest.modulePath);
        final next = Map<String, PluginStoredRecord>.of(_records);
        next[manifest.id] = PluginStoredRecord(
          version: staged,
          previousVersion: old?.version,
        );
        _disableDependents(
          next,
          manifest.id,
          'Dependency was upgraded; review and re-enable this plugin.',
        );
        await _commit(next);
      } catch (_) {
        _resume(suspended);
        if (staged != null) {
          await _bestEffort(() => _storage.removeVersion(staged!));
        }
        rethrow;
      }
      if (old?.previousVersion != null) {
        await _bestEffort(() => _storage.removeVersion(old!.previousVersion!));
      }
      return plugin(manifest.id)!;
    });
  }

  Future<void> setEnabled(
    String id,
    bool enabled, {
    bool previewAcknowledged = false,
    Set<String> grantedPermissions = const {},
  }) {
    final grants = Set<String>.of(grantedPermissions);
    final suspended = _suspend(_affected(id));
    final epoch = _epochs[id] ?? 0;
    _publish();
    return _mutate(() async {
      _requireInitialized();
      final record = _record(id);
      final next = Map<String, PluginStoredRecord>.of(_records);
      try {
        if (!enabled) {
          next[id] = _copy(record, enabled: false, clearGrants: true);
          _disableDependents(next, id, 'A required plugin was disabled.');
        } else {
          _requireFeature();
          final manifest = _manifest(record);
          if (manifest.isPreview && !previewAcknowledged) {
            throw const PluginException(
              'Preview plugins require an explicit stability warning acknowledgement.',
              code: 'preview_acknowledgement',
            );
          }
          PluginPermissionHost.validateGrants(manifest.permissions, grants);
          next[id] = _copy(record, enabled: true, grantedPermissions: grants);
          _validateDependencies(id, next, requireVerified: true);
          _checkEpoch(id, epoch);
          await _checkMetadata(record, () {
            _requireFeature();
            _checkEpoch(id, epoch);
          });
          _checkEpoch(id, epoch);
          _requireFeature();
          await _commit(next);
          _checkEpoch(id, epoch);
          _requireFeature();
          _verified.add(id);
          _resume(suspended);
          return;
        }
        await _commit(next);
      } catch (_) {
        _resume(suspended);
        rethrow;
      }
    });
  }

  /// Metadata inspection grants no capabilities and cannot issue continuations.
  Future<void> selfCheck(String id) async {
    _requireInitialized();
    _requireFeature();
    final record = _record(id);
    final epoch = _epochs[id] ?? 0;
    await _checkMetadata(record, () {
      _requireFeature();
      _checkEpoch(id, epoch);
    });
  }

  Future<void> uninstall(String id) {
    final suspended = _suspend(_affected(id));
    _publish();
    return _mutate(() async {
      _requireInitialized();
      final record = _record(id);
      final next = Map<String, PluginStoredRecord>.of(_records)..remove(id);
      _disableDependents(next, id, 'A required plugin was uninstalled.');
      try {
        await _commit(next);
      } catch (_) {
        _resume(suspended);
        rethrow;
      }
      await _bestEffort(() => _storage.removeVersion(record.version));
      if (record.previousVersion != null) {
        await _bestEffort(
          () => _storage.removeVersion(record.previousVersion!),
        );
      }
      await _bestEffort(() => _storage.removeData(id));
    });
  }

  Future<void> rollback(String id) {
    final suspended = _suspend(_affected(id));
    _publish();
    return _mutate(() async {
      _requireInitialized();
      final record = _record(id);
      final previous = record.previousVersion;
      if (previous == null) {
        _resume(suspended);
        throw const PluginException('No previous plugin version is available.');
      }
      try {
        await _storage.validateVersion(previous);
        final manifest = PluginManifest.fromJson(previous.manifest);
        if (manifest.id != id) {
          throw const PluginException(
            'Rollback plugin identity does not match.',
          );
        }
        final next = Map<String, PluginStoredRecord>.of(_records);
        next[id] = PluginStoredRecord(
          version: previous,
          previousVersion: record.version,
        );
        _disableDependents(
          next,
          id,
          'Dependency was rolled back; review and re-enable this plugin.',
        );
        await _commit(next);
      } catch (_) {
        _resume(suspended);
        rethrow;
      }
    });
  }

  Future<Map<String, dynamic>> invoke(
    String pluginId,
    String entry,
    Map<String, dynamic> request, {
    bool Function()? isCancelled,
  }) async {
    _requireInitialized();
    _requireFeature();
    final record = _record(pluginId);
    if (!record.enabled || !_verified.contains(pluginId)) {
      throw const PluginException(
        'Plugin is disabled or has not passed metadata checks.',
        code: 'plugin_disabled',
      );
    }
    _validateDependencies(pluginId, _records, requireVerified: true);
    if (!const {
      'Basic_info',
      'Node_info',
      'Node_editor_add',
      'Node_execute',
    }.contains(entry)) {
      throw const PluginException(
        'Unsupported plugin entry point.',
        code: 'invalid_entry',
      );
    }
    final manifest = _manifest(record);
    if (manifest.modulePath == null) {
      throw const PluginException(
        'This package contains data only.',
        code: 'data_only',
      );
    }
    final epoch = _epochs[pluginId] ?? 0;
    void checkActive() {
      _requireFeature();
      _checkEpoch(pluginId, epoch);
      if (_disposed ||
          isCancelled?.call() == true ||
          _records[pluginId]?.enabled != true ||
          !_verified.contains(pluginId)) {
        throw const PluginException(
          'Plugin invocation was cancelled.',
          code: 'cancelled',
        );
      }
      _validateDependencies(pluginId, _records, requireVerified: true);
    }

    final baseRequest = _copyJson(request)
      ..remove('continuation')
      ..remove('host_response');
    baseRequest['api_version'] = 1;
    baseRequest['plugin_id'] = pluginId;
    if (entry == 'Node_execute' || entry == 'Node_editor_add') {
      final nodeId = baseRequest['node_id'];
      final definition = manifest.nodes
          .where((node) => node.id == nodeId)
          .firstOrNull;
      if (definition == null) {
        throw const PluginException(
          'The plugin node was not declared.',
          code: 'undeclared_node',
        );
      }
      if (entry == 'Node_execute') {
        final params = baseRequest['params'];
        if (params is! Map<String, dynamic>) {
          throw const PluginException('Node params must be an object.');
        }
        baseRequest['params'] = definition.validateValues(params);
        if (!definition.inputTypes.contains(baseRequest['media_type'])) {
          throw const PluginException(
            'The plugin node does not accept this media type.',
          );
        }
      }
    }
    final budget = PluginInvocationBudget(manifest.limits.timeMs);
    final modulePath = await budget.wait(
      _storage.modulePath(record.version, manifest.modulePath!),
      checkActive,
    );
    var currentRequest = baseRequest;
    while (true) {
      budget.check(checkActive);
      final response = await _invokeBounded(
        modulePath,
        entry,
        currentRequest,
        manifest.limits,
        budget,
        checkActive,
      );
      final hostRequest = response['host_request'];
      if (hostRequest == null) {
        if (entry == 'Node_editor_add') {
          _validateEditorResponse(manifest, baseRequest['node_id'], response);
        }
        budget.check(checkActive);
        return response;
      }
      if (entry != 'Node_execute' ||
          hostRequest is! Map<String, dynamic> ||
          !response.containsKey('continuation') ||
          response.keys.any(
            (key) => key != 'host_request' && key != 'continuation',
          )) {
        throw const PluginException(
          'Invalid or disallowed host continuation.',
          code: 'invalid_host_request',
        );
      }
      final hostResponse = await _host.execute(
        pluginId,
        hostRequest,
        manifest.permissions,
        record.grantedPermissions,
        budget,
        checkActive,
      );
      budget.check(checkActive);
      currentRequest = {
        ...baseRequest,
        'continuation': response['continuation'],
        'host_response': hostResponse,
      };
    }
  }

  PluginManifest _validatePackage(PluginPackageContents contents) {
    final manifest = PluginManifest.fromJson(contents.manifest);
    _validateContributions(manifest);
    final module = manifest.modulePath;
    if (module != null) {
      storage_paths.validatePluginRelativePath(module);
      final bytes = contents.files[module];
      if (bytes == null ||
          bytes.length < 8 ||
          bytes.length > pluginMaxModuleBytes ||
          !pluginJsonEqual(bytes.sublist(0, 8), [
            0,
            97,
            115,
            109,
            1,
            0,
            0,
            0,
          ])) {
        throw const PluginException(
          'The declared module is missing or is not a WASM32 binary.',
          code: 'invalid_module',
        );
      }
    }
    return manifest;
  }

  void _validateContributions(PluginManifest manifest) {
    for (final theme in manifest.themes) {
      PluginThemePreset.fromJson(theme);
    }
    for (final catalog in manifest.aiConfigs) {
      PluginAiCatalog.fromJson(catalog);
    }
  }

  Future<void> _checkMetadata(
    PluginStoredRecord record,
    void Function() checkActive,
  ) async {
    final manifest = _manifest(record);
    _validateContributions(manifest);
    if (!manifest.supportsAppVersion(appVersion)) {
      throw PluginException(
        'Plugin requires application version ${manifest.appVersion}.',
        code: 'app_incompatible',
      );
    }
    await _storage.validateVersion(record.version);
    checkActive();
    if (manifest.modulePath == null) return;
    final budget = PluginInvocationBudget(manifest.limits.timeMs);
    final module = await budget.wait(
      _storage.modulePath(record.version, manifest.modulePath!),
      checkActive,
    );
    final basic = await _invokeBounded(
      module,
      'Basic_info',
      {'api_version': 1, 'plugin_id': manifest.id},
      manifest.limits,
      budget,
      checkActive,
    );
    if (!pluginJsonEqual(
      PluginBasicInfo.fromJson(basic).toJson(),
      manifest.basicInfo.toJson(),
    )) {
      throw const PluginException(
        'Basic_info does not match the installed manifest.',
        code: 'metadata_mismatch',
      );
    }
    if (manifest.nodes.isNotEmpty) {
      final response = await _invokeBounded(
        module,
        'Node_info',
        {'api_version': 1, 'plugin_id': manifest.id},
        manifest.limits,
        budget,
        checkActive,
      );
      if (response.length != 1 ||
          response['nodes'] is! List ||
          (response['nodes'] as List).length != manifest.nodes.length) {
        throw const PluginException(
          'Node_info must declare exactly the manifest nodes.',
          code: 'metadata_mismatch',
        );
      }
      final nodes = <String, Map<String, dynamic>>{};
      for (final raw in response['nodes'] as List) {
        if (raw is! Map<String, dynamic>) {
          throw const PluginException('Invalid Node_info response.');
        }
        final node = PluginNodeDefinition.fromJson(raw);
        if (nodes.containsKey(node.id)) {
          throw const PluginException('Duplicate Node_info node.');
        }
        nodes[node.id] = node.toJson();
      }
      if (!pluginJsonEqual(nodes, {
        for (final node in manifest.nodes) node.id: node.toJson(),
      })) {
        throw const PluginException(
          'Node_info does not match the installed manifest.',
          code: 'metadata_mismatch',
        );
      }
    }
    checkActive();
  }

  Future<Map<String, dynamic>> _invokeBounded(
    String path,
    String entry,
    Map<String, dynamic> request,
    PluginLimits limits,
    PluginInvocationBudget budget,
    void Function() checkActive,
  ) async {
    _checkJsonSize(request);
    final remaining = PluginLimits(
      memoryMb: limits.memoryMb,
      timeMs: budget.remainingMs,
      fuel: limits.fuel,
    );
    final response = await budget.wait(
      runtime.invoke(path, entry, _copyJson(request), remaining),
      checkActive,
    );
    _checkJsonSize(response);
    return _copyJson(response);
  }

  void _validateEditorResponse(
    PluginManifest manifest,
    Object? nodeId,
    Map<String, dynamic> response,
  ) {
    final fields = response['fields'];
    if (response.length != 1 || fields is! List || fields.length > 64) {
      throw const PluginException('Invalid Node_editor_add response.');
    }
    final declared = manifest.nodes
        .firstWhere((node) => node.id == nodeId)
        .fields;
    final parsed = fields.map((raw) {
      if (raw is! Map<String, dynamic>) {
        throw const PluginException('Invalid plugin editor field.');
      }
      return PluginFieldDefinition.fromJson(raw);
    }).toList();
    final expected = {for (final field in declared) field.key: field.toJson()};
    final actual = {for (final field in parsed) field.key: field.toJson()};
    if (actual.length != parsed.length || !pluginJsonEqual(expected, actual)) {
      throw const PluginException(
        'Plugin editor fields differ from the declared schema.',
        code: 'metadata_mismatch',
      );
    }
  }

  void _validateDependencies(
    String id,
    Map<String, PluginStoredRecord> records, {
    required bool requireVerified,
  }) {
    final visiting = <String>{};
    final visited = <String>{};
    void visit(String current) {
      if (visiting.contains(current)) {
        throw const PluginException(
          'Cyclic plugin dependencies.',
          code: 'dependency_cycle',
        );
      }
      if (visited.contains(current)) return;
      final record = records[current];
      if (record == null || !record.enabled) {
        throw PluginException(
          'Required plugin $current is missing or disabled.',
          code: 'dependency_missing',
        );
      }
      final manifest = _manifest(record);
      if (!manifest.supportsAppVersion(appVersion)) {
        throw PluginException(
          'Plugin $current is incompatible with this application.',
          code: 'app_incompatible',
        );
      }
      visiting.add(current);
      for (final dependency in manifest.dependencies) {
        final candidate = records[dependency.id];
        if (candidate == null ||
            !candidate.enabled ||
            (requireVerified && !_verified.contains(dependency.id))) {
          throw PluginException(
            'Required plugin ${dependency.id} is missing, disabled or unverified.',
            code: 'dependency_missing',
          );
        }
        if (!dependency.matches(_manifest(candidate).version)) {
          throw PluginException(
            'Plugin dependency ${dependency.id} requires ${dependency.version}.',
            code: 'dependency_version',
          );
        }
        visit(dependency.id);
      }
      visiting.remove(current);
      visited.add(current);
    }

    visit(id);
  }

  Set<String> _affected(String id) {
    final affected = <String>{id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final record in _records.values) {
        if (!affected.contains(record.id) &&
            _manifest(record).dependencies.any(
              (dependency) => affected.contains(dependency.id),
            )) {
          affected.add(record.id);
          changed = true;
        }
      }
    }
    return affected;
  }

  void _disableDependents(
    Map<String, PluginStoredRecord> records,
    String id,
    String reason,
  ) {
    for (final affected in _affected(id)..remove(id)) {
      final record = records[affected];
      if (record != null) {
        records[affected] = _copy(
          record,
          enabled: false,
          clearGrants: true,
          lastError: reason,
        );
      }
    }
  }

  Map<String, (int, bool, String?)> _suspend(Iterable<String> ids) {
    final previous = <String, (int, bool, String?)>{};
    for (final id in ids.toList()) {
      final epoch = (_epochs[id] ?? 0) + 1;
      previous[id] = (
        epoch,
        _verified.remove(id),
        _records[id]?.version.directoryName,
      );
      _epochs[id] = epoch;
    }
    return previous;
  }

  void _resume(Map<String, (int, bool, String?)> previous) {
    for (final entry in previous.entries) {
      if (entry.value.$2 &&
          _epochs[entry.key] == entry.value.$1 &&
          _records[entry.key]?.version.directoryName == entry.value.$3 &&
          _records[entry.key]?.enabled == true) {
        _verified.add(entry.key);
      }
    }
    _publish();
  }

  Future<void> _commit(Map<String, PluginStoredRecord> next) async {
    await _storage.save(next.values);
    _records
      ..clear()
      ..addAll(next);
    _verified.removeWhere((id) => next[id]?.enabled != true);
    _publish();
  }

  void _publish() {
    _snapshot = List.unmodifiable(
      _records.values.map(
        (record) => InstalledPlugin(
          manifest: _manifest(record),
          enabled: record.enabled,
          grantedPermissions: record.grantedPermissions,
          hasRollback: record.previousVersion != null,
          lastError: record.lastError,
        ),
      ),
    );
    final available = <PluginManifest>[];
    if (_featureEnabled && !_disposed) {
      for (final record in _records.values) {
        if (!record.enabled || !_verified.contains(record.id)) continue;
        try {
          _validateDependencies(record.id, _records, requireVerified: true);
          available.add(_manifest(record));
        } catch (_) {
          /* unavailable dependency */
        }
      }
    }
    _catalog.replaceAll(available);
    if (!_disposed) notifyListeners();
  }

  Future<T> _mutate<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        if (_disposed) {
          throw const PluginException('Plugin manager is disposed.');
        }
        completer.complete(await body());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  PluginStoredRecord _record(String id) =>
      _records[id] ??
      (throw PluginException(
        'Plugin $id is not installed.',
        code: 'not_installed',
      ));
  PluginManifest _manifest(PluginStoredRecord record) =>
      PluginManifest.fromJson(record.version.manifest);
  PluginStoredRecord _copy(
    PluginStoredRecord record, {
    required bool enabled,
    Set<String>? grantedPermissions,
    bool clearGrants = false,
    String? lastError,
  }) => PluginStoredRecord(
    version: record.version,
    previousVersion: record.previousVersion,
    enabled: enabled,
    grantedPermissions: clearGrants
        ? const {}
        : grantedPermissions ?? record.grantedPermissions,
    lastError: lastError,
  );
  void _requireInitialized() {
    if (!_initialized || _disposed) {
      throw const PluginException('Plugin manager is not initialized.');
    }
  }

  void _requireFeature() {
    if (!_featureEnabled || _disposed) {
      throw const PluginException(
        'Experimental plugins are disabled.',
        code: 'feature_disabled',
      );
    }
  }

  void _checkEpoch(String id, int epoch) {
    if ((_epochs[id] ?? 0) != epoch) {
      throw const PluginException(
        'Plugin invocation was cancelled.',
        code: 'cancelled',
      );
    }
  }

  void _checkFeatureRequest(int request) {
    _requireFeature();
    if (request != _featureRequest) {
      throw const PluginException(
        'Plugin activation was cancelled.',
        code: 'cancelled',
      );
    }
  }

  String _safeError(Object error) =>
      error is PluginException ? error.message : 'Plugin validation failed.';
  static void _checkJsonSize(Map<String, dynamic> value) {
    if (utf8.encode(jsonEncode(value)).length > pluginMaxJsonBytes) {
      throw const PluginException(
        'Plugin request or response exceeds the JSON limit.',
        code: 'json_size',
      );
    }
  }

  static Map<String, dynamic> _copyJson(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  static Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      /* Keep inert private files rather than undo a committed registry. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _featureEnabled = false;
    _suspend(_records.keys);
    _catalog.clear();
    super.dispose();
  }
}
