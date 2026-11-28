import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manager.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manifest.dart';
import 'package:ffmpegpp_gui/plugins/plugin_node_catalog.dart';
import 'package:ffmpegpp_gui/plugins/plugin_permissions.dart';
import 'package:ffmpegpp_gui/plugins/plugin_storage.dart'
    hide validatePluginRelativePath;
import 'package:ffmpegpp_gui/services/native_process.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'org.example.volume';

Map<String, dynamic> _manifest({
  String id = _id,
  String version = '1.0.0',
  bool module = true,
  bool preview = false,
  List<Map<String, dynamic>> dependencies = const [],
  Map<String, dynamic>? permissions,
  int timeMs = 1000,
  String appVersion = '>=6.0.0-beta2 <7.0.0',
}) => {
  'format_version': 1,
  'id': id,
  'api_version': 1,
  'app_version': appVersion,
  'Basic_info': {
    'Name': 'Volume demo',
    'Version': version,
    'IsPreview': preview,
    'Summary': 'A test plugin',
  },
  if (module) 'module': 'plugin.wasm',
  if (module)
    'Node_info': [
      {
        'id': 'volume',
        'name': 'Volume',
        'fun': 'Adjust volume',
        'IsLogic': true,
        'IO': {'inputs': 1, 'outputs': 1},
        'input_types': ['audio'],
        'output_type': 'audio',
        'schema_version': 1,
        'fields': [
          {
            'key': 'gain',
            'label': 'Gain',
            'type': 'number',
            'default': 0,
            'min': -20,
            'max': 20,
          },
        ],
      },
    ],
  'dependencies': dependencies,
  'permissions': ?permissions,
  'limits': {'memory_mb': 16, 'time_ms': timeMs, 'fuel': 1000000},
};
Uint8List _package(Map<String, dynamic> manifest) {
  final archive = Archive();
  final bytes = utf8.encode(jsonEncode(manifest));
  archive.addFile(ArchiveFile('manifest.json', bytes.length, bytes));
  if (manifest.containsKey('module')) {
    archive.addFile(
      ArchiveFile('plugin.wasm', 8, [0, 97, 115, 109, 1, 0, 0, 0]),
    );
  }
  final icon = (manifest['Basic_info'] as Map)['Icon'];
  if (icon is String) {
    const pngHeader = [137, 80, 78, 71, 13, 10, 26, 10];
    archive.addFile(ArchiveFile(icon, pngHeader.length, pngHeader));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Matcher _code(String value) =>
    isA<PluginException>().having((error) => error.code, 'code', value);
Map<String, dynamic> _request() => {
  'node_id': 'volume',
  'params': {'gain': 2},
  'media_type': 'audio',
};

class _Runtime implements PluginRuntime {
  Map<String, dynamic> metadata;
  final List<String> entries = [];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? callback;
  _Runtime(this.metadata);
  @override
  Future<Map<String, dynamic>> invoke(
    String path,
    String entry,
    Map<String, dynamic> request,
    PluginLimits limits,
  ) async {
    entries.add(entry);
    if (callback != null) return callback!(entry, request);
    if (entry == 'Basic_info') {
      return Map<String, dynamic>.from(metadata['Basic_info'] as Map);
    }
    if (entry == 'Node_info') return {'nodes': metadata['Node_info'] ?? []};
    return {'operation': 'audio.volume', 'decibels': request['params']['gain']};
  }
}

class _FailingStorage extends PluginStorage {
  bool failSave = false;
  _FailingStorage(super.root);
  @override
  Future<void> save(Iterable<PluginStoredRecord> records) async {
    if (failSave) throw const FileSystemException('Simulated registry failure');
    await super.save(records);
  }
}

void main() {
  late Directory root;
  late _Runtime runtime;
  late PluginNodeCatalog catalog;
  late PluginManager manager;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fpp-plugin-manager-');
    runtime = _Runtime(_manifest());
    catalog = PluginNodeCatalog();
    manager = PluginManager(
      root: root,
      runtime: runtime,
      appVersion: '6.0.0-beta2',
      catalog: catalog,
    );
    await manager.initialize();
  });
  tearDown(() async {
    manager.dispose();
    await root.delete(recursive: true);
  });

  test(
    'installation is disabled, inspection never executes and data packages work without WASM',
    () async {
      final data = _package(_manifest(module: false));
      final inspected = await manager.inspectPackage(data);
      expect(inspected.hasModule, isFalse);
      expect(inspected.filePaths, ['manifest.json']);
      expect((await manager.installPackage(data)).enabled, isFalse);
      expect(runtime.entries, isEmpty);
      await expectLater(
        manager.setEnabled(_id, true),
        throwsA(_code('feature_disabled')),
      );
      await manager.setFeatureEnabled(true);
      await manager.setEnabled(_id, true);
      await manager.selfCheck(_id);
      expect(manager.plugin(_id)!.enabled, isTrue);
      expect(catalog.plugin(_id), isNotNull);
      expect(runtime.entries, isEmpty);
      await expectLater(
        manager.invoke(_id, 'Basic_info', {}),
        throwsA(_code('data_only')),
      );
    },
  );

  test('enable checks both metadata exports before publishing nodes', () async {
    await manager.installPackage(_package(_manifest()));
    await manager.setFeatureEnabled(true);
    await manager.setEnabled(_id, true);
    expect(runtime.entries, ['Basic_info', 'Node_info']);
    expect(catalog.lookup(_id, 'volume'), isNotNull);
    expect(await manager.invoke(_id, 'Node_execute', _request()), {
      'operation': 'audio.volume',
      'decibels': 2,
    });
    final wrong = _request()..['node_id'] = 'undeclared';
    await expectLater(
      manager.invoke(_id, 'Node_execute', wrong),
      throwsA(_code('undeclared_node')),
    );
    final unknown = _request()..['params'] = {'arbitrary': 'value'};
    await expectLater(
      manager.invoke(_id, 'Node_execute', unknown),
      throwsFormatException,
    );
  });

  test('optional author and package icon are validated and exposed', () async {
    final manifest = _manifest();
    final basic = Map<String, dynamic>.from(manifest['Basic_info'] as Map)
      ..['Author'] = 'Example Studio'
      ..['Icon'] = 'assets/icon.png';
    manifest['Basic_info'] = basic;
    runtime.metadata = manifest;
    await manager.installPackage(_package(manifest));
    await manager.setFeatureEnabled(true);
    await manager.setEnabled(_id, true);

    expect(manager.plugin(_id)!.manifest.basicInfo.author, 'Example Studio');
    expect(manager.plugin(_id)!.manifest.basicInfo.iconPath, 'assets/icon.png');
    expect(await manager.iconBytes(_id), [137, 80, 78, 71, 13, 10, 26, 10]);
  });

  test('node toggles persist and gate catalog and execution', () async {
    await manager.installPackage(_package(_manifest()));
    await manager.setFeatureEnabled(true);
    await manager.setEnabled(_id, true);

    await manager.setNodeEnabled(_id, 'volume', false);
    expect(manager.plugin(_id)!.isNodeEnabled('volume'), isFalse);
    expect(catalog.lookup(_id, 'volume'), isNull);
    await expectLater(
      manager.invoke(_id, 'Node_execute', _request()),
      throwsA(_code('node_disabled')),
    );

    manager.dispose();
    manager = PluginManager(
      root: root,
      runtime: runtime,
      appVersion: '6.0.0-beta2',
      catalog: catalog,
    );
    await manager.initialize();
    expect(manager.plugin(_id)!.isNodeEnabled('volume'), isFalse);
    await manager.setFeatureEnabled(true);
    expect(catalog.lookup(_id, 'volume'), isNull);

    await manager.setNodeEnabled(_id, 'volume', true);
    expect(manager.plugin(_id)!.isNodeEnabled('volume'), isTrue);
    expect(catalog.lookup(_id, 'volume'), isNotNull);
  });

  test(
    'mismatching Basic_info and undeclared Node_info are rejected',
    () async {
      await manager.installPackage(_package(_manifest()));
      await manager.setFeatureEnabled(true);
      runtime.metadata = _manifest(version: '2.0.0');
      await expectLater(
        manager.setEnabled(_id, true),
        throwsA(_code('metadata_mismatch')),
      );
      expect(manager.plugin(_id)!.enabled, isFalse);
      expect(catalog.entries, isEmpty);
      runtime.metadata =
          jsonDecode(jsonEncode(_manifest())) as Map<String, dynamic>;
      (runtime.metadata['Node_info'] as List).add(
        Map.of((runtime.metadata['Node_info'] as List).first as Map)
          ..['id'] = 'extra',
      );
      await expectLater(
        manager.setEnabled(_id, true),
        throwsA(_code('metadata_mismatch')),
      );
    },
  );

  test(
    'preview requires acknowledgement and app compatibility is checked',
    () async {
      final preview = _manifest(preview: true);
      runtime.metadata = preview;
      await manager.installPackage(_package(preview));
      await manager.setFeatureEnabled(true);
      await expectLater(
        manager.setEnabled(_id, true),
        throwsA(_code('preview_acknowledgement')),
      );
      await manager.setEnabled(_id, true, previewAcknowledged: true);
      await manager.installPackage(
        _package(
          _manifest(version: '2.0.0', module: false, appVersion: '>=7.0.0'),
        ),
      );
      await expectLater(
        manager.setEnabled(_id, true),
        throwsA(_code('app_incompatible')),
      );
    },
  );

  test(
    'dependencies need an enabled compatible version and disable cascades',
    () async {
      await manager.setFeatureEnabled(true);
      final dependant = _manifest(
        id: 'org.example.dependant',
        module: false,
        dependencies: [
          {'id': _id, 'version': '>=1.0.0 <2.0.0'},
        ],
      );
      await manager.installPackage(_package(dependant));
      await expectLater(
        manager.setEnabled('org.example.dependant', true),
        throwsA(_code('dependency_missing')),
      );
      await manager.installPackage(_package(_manifest(module: false)));
      await manager.setEnabled(_id, true);
      await manager.setEnabled('org.example.dependant', true);
      await manager.setEnabled(_id, false);
      expect(manager.plugins.every((plugin) => !plugin.enabled), isTrue);
      expect(catalog.entries, isEmpty);
      await manager.installPackage(
        _package(_manifest(module: false, version: '2.0.0')),
      );
      await manager.setEnabled(_id, true);
      await expectLater(
        manager.setEnabled('org.example.dependant', true),
        throwsA(_code('dependency_version')),
      );
    },
  );

  test(
    'upgrade and rollback keep packages disabled and reset grants',
    () async {
      final permissions = {
        'files': {'read': true, 'write': true},
      };
      await manager.installPackage(
        _package(_manifest(module: false, permissions: permissions)),
      );
      await manager.setFeatureEnabled(true);
      await manager.setEnabled(_id, true, grantedPermissions: {'files.read'});
      final upgraded = await manager.installPackage(
        _package(
          _manifest(module: false, version: '2.0.0', permissions: permissions),
        ),
      );
      expect(upgraded.enabled, isFalse);
      expect(upgraded.hasRollback, isTrue);
      expect(upgraded.grantedPermissions, isEmpty);
      await manager.rollback(_id);
      expect(manager.plugin(_id)!.manifest.version, '1.0.0');
      expect(manager.plugin(_id)!.enabled, isFalse);
      await expectLater(
        manager.installPackage(_package(_manifest(module: false))),
        throwsA(_code('version_not_newer')),
      );
    },
  );

  test(
    'failed upgrade registry save preserves the old package and catalog',
    () async {
      manager.dispose();
      final storage = _FailingStorage(root);
      manager = PluginManager(
        root: root,
        runtime: runtime,
        appVersion: '6.0.0-beta2',
        storage: storage,
        catalog: catalog,
      );
      await manager.initialize();
      await manager.installPackage(_package(_manifest(module: false)));
      await manager.setFeatureEnabled(true);
      await manager.setEnabled(_id, true);
      storage.failSave = true;
      await expectLater(
        manager.installPackage(
          _package(_manifest(module: false, version: '2.0.0')),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(manager.plugin(_id)!.manifest.version, '1.0.0');
      expect(manager.plugin(_id)!.enabled, isTrue);
      expect(catalog.plugin(_id)!.version, '1.0.0');
      expect(
        (await Directory('${root.path}/packages').list().toList()).length,
        1,
      );
      storage.failSave = false;
      final loaded = await storage.load();
      expect(loaded.single.version.manifest['Basic_info']['Version'], '1.0.0');
    },
  );

  for (final action in ['disable', 'uninstall', 'feature']) {
    test(
      '$action while runtime waits discards the returned operation',
      () async {
        await manager.installPackage(_package(_manifest()));
        await manager.setFeatureEnabled(true);
        await manager.setEnabled(_id, true);
        final started = Completer<void>();
        final result = Completer<Map<String, dynamic>>();
        runtime.callback = (entry, request) {
          started.complete();
          return result.future;
        };
        final invocation = manager.invoke(_id, 'Node_execute', _request());
        final failed = expectLater(
          invocation,
          throwsA(anyOf(_code('cancelled'), _code('feature_disabled'))),
        );
        await started.future;
        if (action == 'disable') await manager.setEnabled(_id, false);
        if (action == 'uninstall') await manager.uninstall(_id);
        if (action == 'feature') await manager.setFeatureEnabled(false);
        result.complete({'operation': 'media.copy'});
        await failed;
        expect(catalog.entries, isEmpty);
      },
    );
  }

  test('a later disable cancels an enable waiting for metadata', () async {
    await manager.installPackage(_package(_manifest()));
    await manager.setFeatureEnabled(true);
    final started = Completer<void>();
    final returned = Completer<Map<String, dynamic>>();
    runtime.callback = (entry, request) {
      started.complete();
      return returned.future;
    };
    final enabling = manager.setEnabled(_id, true);
    final rejected = expectLater(enabling, throwsA(_code('cancelled')));
    await started.future;
    final disabling = manager.setEnabled(_id, false);
    returned.complete(
      Map<String, dynamic>.from(_manifest()['Basic_info'] as Map),
    );
    await rejected;
    await disabling;
    expect(manager.plugin(_id)!.enabled, isFalse);
    expect(catalog.entries, isEmpty);
  });

  test(
    'startup only reads declarations and rechecks saved enabled metadata on opt-in',
    () async {
      await manager.installPackage(_package(_manifest()));
      await manager.setFeatureEnabled(true);
      await manager.setEnabled(_id, true);
      manager.dispose();
      runtime.entries.clear();
      runtime.metadata = _manifest(version: '2.0.0');
      manager = PluginManager(
        root: root,
        runtime: runtime,
        appVersion: '6.0.0-beta2',
        catalog: catalog,
      );
      await manager.initialize();
      expect(runtime.entries, isEmpty);
      expect(catalog.entries, isEmpty);
      await manager.setFeatureEnabled(true);
      expect(manager.plugin(_id)!.enabled, isFalse);
      expect(manager.plugin(_id)!.lastError, isNotEmpty);
    },
  );

  test(
    'file continuations require explicit grants and preserve the base request',
    () async {
      final manifest = _manifest(
        permissions: {
          'files': {'read': true, 'write': true},
        },
      );
      runtime.metadata = manifest;
      await manager.installPackage(_package(manifest));
      await manager.setFeatureEnabled(true);
      await manager.setEnabled(
        _id,
        true,
        grantedPermissions: {'files.read', 'files.write'},
      );
      final expected = base64.encode(utf8.encode('hello'));
      var calls = 0;
      runtime.callback = (entry, request) async {
        calls++;
        expect(request['node_id'], 'volume');
        expect(request['params'], {'gain': 2});
        if (calls == 1) {
          return {
            'host_request': {
              'id': 'write',
              'method': 'file.write',
              'path': 'state.txt',
              'content_base64': expected,
            },
            'continuation': {'stage': 1},
          };
        }
        expect(request['host_response']['ok'], isTrue);
        if (calls == 2) {
          expect(request['continuation'], {'stage': 1});
          return {
            'host_request': {
              'id': 'read',
              'method': 'file.read',
              'path': 'state.txt',
            },
            'continuation': 2,
          };
        }
        expect(request['host_response']['result']['content_base64'], expected);
        return {'operation': 'media.copy'};
      };
      expect(await manager.invoke(_id, 'Node_execute', _request()), {
        'operation': 'media.copy',
      });
      expect(calls, 3);
    },
  );

  test('default-denied file write has no side effect', () async {
    final manifest = _manifest(
      permissions: {
        'files': {'write': true},
      },
    );
    runtime.metadata = manifest;
    await manager.installPackage(_package(manifest));
    await manager.setFeatureEnabled(true);
    await manager.setEnabled(_id, true);
    runtime.callback = (entry, request) async {
      if (request.containsKey('host_response')) {
        expect(request['host_response']['ok'], isFalse);
        return {'operation': 'media.copy'};
      }
      return {
        'host_request': {
          'id': 'write',
          'method': 'file.write',
          'path': 'state.txt',
          'content_base64': 'YQ==',
        },
        'continuation': null,
      };
    };
    await manager.invoke(_id, 'Node_execute', _request());
    expect(await Directory('${root.path}/data').list().toList(), isEmpty);
    await expectLater(
      manager.setEnabled(_id, true, grantedPermissions: {'files.read'}),
      throwsA(_code('permission_denied')),
    );
  });

  test(
    'cyclic saved dependencies are disabled before catalog publication',
    () async {
      final first = _manifest(
        id: 'org.example.first',
        module: false,
        dependencies: [
          {'id': 'org.example.second', 'version': '>=1.0.0'},
        ],
      );
      final second = _manifest(
        id: 'org.example.second',
        module: false,
        dependencies: [
          {'id': 'org.example.first', 'version': '>=1.0.0'},
        ],
      );
      await manager.installPackage(_package(first));
      await manager.installPackage(_package(second));
      manager.dispose();
      final storage = PluginStorage(root);
      await storage.initialize();
      await storage.save(
        (await storage.load()).map(
          (record) =>
              PluginStoredRecord(version: record.version, enabled: true),
        ),
      );
      manager = PluginManager(
        root: root,
        runtime: runtime,
        appVersion: '6.0.0-beta2',
        catalog: catalog,
      );
      await manager.initialize();
      await manager.setFeatureEnabled(true);
      expect(
        manager.plugins.every(
          (item) => !item.enabled && item.lastError!.contains('Cyclic'),
        ),
        isTrue,
      );
      expect(catalog.entries, isEmpty);
      expect(runtime.entries, isEmpty);
    },
  );

  test(
    'generation guard remains invalid after disable followed by re-enable',
    () async {
      await manager.installPackage(_package(_manifest()));
      await manager.setFeatureEnabled(true);
      await manager.setEnabled(_id, true);
      final generation = manager.generation(_id);
      expect(manager.isActive(_id, generation: generation), isTrue);
      await manager.setEnabled(_id, false);
      await manager.setEnabled(_id, true);
      expect(manager.isActive(_id), isTrue);
      expect(manager.isActive(_id, generation: generation), isFalse);
    },
  );

  final nativeLibrary = Platform.environment['FFMPEGPP_PLUGIN_NATIVE_LIBRARY'];
  test(
    'compiled SDK package installs, self-checks and executes through native WAMR',
    () async {
      manager.dispose();
      final transport = NativeProcessManager();
      try {
        await transport.start(nativeLibrary!);
        expect((await transport.waitForReady())['type'], 'ready');
        final configured = await transport.requestWithTimeout(
          'plugin_set_root',
          5,
          {'root': root.absolute.path},
        );
        expect(
          configured['success'],
          isTrue,
          reason: configured['error']?.toString(),
        );
        final capabilities = await transport.requestWithTimeout(
          'plugin_capabilities',
          5,
        );
        expect(capabilities['success'], isTrue);
        expect(capabilities['data']['available'], isTrue);
        final nativeRuntime = CallbackPluginRuntime((
          module,
          entry,
          request,
          limits,
        ) async {
          final response = await transport
              .requestWithTimeout('plugin_invoke', 5, {
                'module_path': module,
                'entry': entry,
                'request': request,
                'limits': limits.toJson(),
              });
          if (response['success'] != true) {
            throw PluginException(
              response['error']?.toString() ?? 'Native invocation failed.',
            );
          }
          return Map<String, dynamic>.from(response['data'] as Map);
        });
        manager = PluginManager(
          root: root,
          runtime: nativeRuntime,
          appVersion: '6.0.0-beta2',
          catalog: catalog,
        );
        await manager.initialize();
        final package = await File(
          '../docs/public/examples/plugin-demo.fppplugin',
        ).readAsBytes();
        final inspected = await manager.inspectPackage(package);
        final id = inspected.manifest.id;
        expect(inspected.hasModule, isTrue);
        expect((await manager.installPackage(package)).enabled, isFalse);
        await manager.setFeatureEnabled(true);
        await manager.setEnabled(id, true, previewAcknowledged: true);
        expect(catalog.lookup(id, 'audio_gain'), isNotNull);
        final result = await manager.invoke(id, 'Node_execute', {
          'node_id': 'audio_gain',
          'params': {'decibels': -6},
          'media_type': 'audio',
        });
        expect(result, {'operation': 'audio.volume', 'decibels': -6});
        final editor = await manager.invoke(id, 'Node_editor_add', {
          'node_id': 'audio_gain',
        });
        expect(editor['fields'], hasLength(1));
        await manager.uninstall(id);
        expect(manager.plugins, isEmpty);
      } finally {
        await transport.shutdown();
        transport.dispose();
      }
    },
    skip: nativeLibrary == null
        ? 'Set FFMPEGPP_PLUGIN_NATIVE_LIBRARY to a WAMR-enabled backend library.'
        : false,
  );

  test('continuation loop has a single request-count budget', () async {
    await manager.installPackage(_package(_manifest()));
    await manager.setFeatureEnabled(true);
    await manager.setEnabled(_id, true);
    var calls = 0;
    runtime.callback = (entry, request) async => {
      'host_request': {'id': 'r${++calls}', 'method': 'file.read', 'path': 'x'},
      'continuation': calls,
    };
    await expectLater(
      manager.invoke(_id, 'Node_execute', _request()),
      throwsA(_code('host_budget')),
    );
    expect(calls, 17);
  });

  test(
    'network and all restarts share the invocation wall-clock budget',
    () async {
      manager.dispose();
      final storage = PluginStorage(root);
      var requests = 0;
      final host = PluginPermissionHost(
        storage,
        httpGet: (uri, timeout) async {
          requests++;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return PluginHttpResult(200, Uint8List(0));
        },
      );
      manager = PluginManager(
        root: root,
        runtime: runtime,
        appVersion: '6.0.0-beta2',
        storage: storage,
        permissionHost: host,
        catalog: catalog,
      );
      await manager.initialize();
      final manifest = _manifest(
        timeMs: 100,
        permissions: {
          'network': ['https://example.org'],
        },
      );
      runtime.metadata = manifest;
      await manager.installPackage(_package(manifest));
      await manager.setFeatureEnabled(true);
      await manager.setEnabled(
        _id,
        true,
        grantedPermissions: {'network:https://example.org'},
      );
      runtime.callback = (entry, request) async => {
        'host_request': {
          'id': 'fetch',
          'method': 'http.get',
          'url': 'https://example.org/models',
        },
        'continuation': 1,
      };
      await expectLater(
        manager.invoke(_id, 'Node_execute', _request()),
        throwsA(_code('timeout')),
      );
      expect(requests, 1);
    },
  );
}
