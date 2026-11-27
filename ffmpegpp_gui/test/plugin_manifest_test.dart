import 'package:ffmpegpp_gui/plugins/plugin_manifest.dart';
import 'package:ffmpegpp_gui/plugins/plugin_node_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> nodeJson() => {
  'id': 'volume',
  'name': 'Volume',
  'fun': 'Change audio level',
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
      'min': -60,
      'max': 24,
    },
    {
      'key': 'count',
      'label': 'Count',
      'type': 'integer',
      'default': 2,
      'min': 1,
      'max': 8,
    },
    {'key': 'enabled', 'label': 'Enabled', 'type': 'boolean', 'default': true},
    {'key': 'title', 'label': 'Title', 'type': 'string', 'default': ''},
    {
      'key': 'mode',
      'label': 'Mode',
      'type': 'select',
      'default': 'soft',
      'options': ['soft', 'hard'],
    },
  ],
};

Map<String, dynamic> manifestJson({String id = 'org.example.volume'}) => {
  'format_version': 1,
  'id': id,
  'api_version': 1,
  'app_version': '>=6.0.0-beta2 <7.0.0',
  'Basic_info': {
    'Name': 'Volume',
    'Version': '1.2.0-beta.2+test',
    'IsPreview': true,
    'Summary': 'Example plugin',
  },
  'module': 'plugin.wasm',
  'Node_info': [nodeJson()],
};

void main() {
  group('manifest v1 contract', () {
    test('round trips declarations and defaults to denied capabilities', () {
      final manifest = PluginManifest.fromJson(manifestJson());
      expect(manifest.name, 'Volume');
      expect(manifest.version, '1.2.0-beta.2+test');
      expect(manifest.isPreview, isTrue);
      expect(manifest.modulePath, 'plugin.wasm');
      expect(manifest.nodes.single.isLogic, isTrue);
      expect(manifest.permissions.grantKeys, isEmpty);
      expect(manifest.limits.toJson(), {
        'memory_mb': 16,
        'time_ms': 1000,
        'fuel': 1000000,
      });
      expect(manifest.dependencies, isEmpty);
      expect(
        PluginManifest.fromJson(manifest.toJson()).toJson(),
        manifest.toJson(),
      );
      expect(manifest.supportsAppVersion('6.0.0-beta1'), isFalse);
      expect(manifest.supportsAppVersion('6.0.0-beta2'), isTrue);
      expect(manifest.supportsAppVersion('6.2.1'), isTrue);
      expect(manifest.supportsAppVersion('7.0.0'), isFalse);
      expect(
        () => manifest.validateCompatibility('7.0.0'),
        throwsFormatException,
      );
      expect(
        () => manifest.validateCompatibility('6.0.0', supportedApiVersion: 2),
        throwsFormatException,
      );
    });

    test('data-only manifests do not invent undeclared nodes', () {
      final json = manifestJson()
        ..remove('module')
        ..remove('Node_info');
      final manifest = PluginManifest.fromJson(json);
      expect(manifest.nodes, isEmpty);
      expect(manifest.module, isNull);
      expect(
        () => PluginManifest.fromJson(manifestJson()..remove('module')),
        throwsFormatException,
      );
    });

    test('requires correctly typed Basic_info fields and semver', () {
      for (final key in ['Name', 'Version', 'IsPreview', 'Summary']) {
        final json = manifestJson();
        (json['Basic_info'] as Map).remove(key);
        expect(
          () => PluginManifest.fromJson(json),
          throwsFormatException,
          reason: key,
        );
      }
      final json = manifestJson();
      (json['Basic_info'] as Map)['IsPreview'] = 'false';
      expect(() => PluginManifest.fromJson(json), throwsFormatException);
      (json['Basic_info'] as Map)['IsPreview'] = false;
      (json['Basic_info'] as Map)['Version'] = 'v1';
      expect(() => PluginManifest.fromJson(json), throwsFormatException);
    });

    test(
      'rejects unsupported API/format versions and unknown executable fields',
      () {
        for (final key in ['api_version', 'format_version']) {
          for (final value in [0, 2, 1.0, '1']) {
            expect(
              () => PluginManifest.fromJson(manifestJson()..[key] = value),
              throwsFormatException,
            );
          }
        }
        expect(
          () => PluginManifest.fromJson(manifestJson()..['action'] = 'shell'),
          throwsFormatException,
        );
        for (final id in [
          '../escape',
          'volume',
          'org.example/volume',
          'ORG.Example.Volume',
          'org.example\u0000evil',
        ]) {
          expect(
            () => PluginManifest.fromJson(manifestJson(id: id)),
            throwsFormatException,
          );
        }
      },
    );

    test('rejects module traversal and platform absolute paths', () {
      for (final path in [
        '/plugin.wasm',
        '../plugin.wasm',
        'x/../plugin.wasm',
        './plugin.wasm',
        'x//plugin.wasm',
        r'x\plugin.wasm',
        r'C:\plugin.wasm',
        'plugin.wasm\u0000',
        'plugin.exe',
      ]) {
        expect(
          () => PluginManifest.fromJson(manifestJson()..['module'] = path),
          throwsFormatException,
          reason: path,
        );
      }
      expect(
        PluginManifest.fromJson(
          manifestJson()..['module'] = 'wasm/main.wasm',
        ).modulePath,
        'wasm/main.wasm',
      );
    });

    test(
      'rejects hard resource limit overflows instead of silently clamping',
      () {
        for (final entry in {
          'memory_mb': 65,
          'time_ms': 5001,
          'fuel': 10000001,
        }.entries) {
          expect(
            () => PluginLimits.fromJson({entry.key: entry.value}),
            throwsFormatException,
          );
          expect(
            () => PluginLimits.fromJson({entry.key: 0}),
            throwsFormatException,
          );
          expect(
            () => PluginLimits.fromJson({entry.key: 1.0}),
            throwsFormatException,
          );
        }
        expect(
          () => const PluginLimits(memoryMb: 100).validate(),
          throwsFormatException,
        );
        expect(
          PluginLimits.fromJson({
            'memory_mb': 64,
            'time_ms': 5000,
            'fuel': 10000000,
          }).memoryBytes,
          64 * 1024 * 1024,
        );
      },
    );

    test(
      'canonicalizes exact HTTPS origins and retains separate capability grants',
      () {
        final permissions = PluginPermissions.fromJson({
          'files': {'read': true},
          'network': ['https://EXAMPLE.org:443/'],
        });
        expect(permissions.filesWrite, isFalse);
        expect(permissions.network, ['https://example.org']);
        expect(permissions.grantKeys, {
          'files.read',
          'network:https://example.org',
        });
        for (final origin in [
          'http://example.org',
          'https://u:p@example.org',
          'https://example.org/path',
          'https://example.org?q=1',
          'https://example.org#fragment',
          'https://example.org:0',
          'https://example.org:65536',
          'https://*.example.org',
          r'https://example.org\evil',
        ]) {
          expect(
            () => PluginPermissions.fromJson({
              'network': [origin],
            }),
            throwsFormatException,
            reason: origin,
          );
        }
        expect(
          () => PluginPermissions.fromJson({
            'network': ['https://example.org', 'https://example.org/'],
          }),
          throwsFormatException,
        );
        expect(
          () => PluginPermissions.fromJson({
            'files': {'read': 'true'},
          }),
          throwsFormatException,
        );
        expect(
          () => PluginPermissions.fromJson({'shell': true}),
          throwsFormatException,
        );
      },
    );

    test(
      'validates dependency comparator and rejects self/duplicate dependencies',
      () {
        final json = manifestJson()
          ..['dependencies'] = [
            {'id': 'org.example.base', 'version': '>=1.0.0-beta.2 <2.0.0'},
          ];
        final dependency = PluginManifest.fromJson(json).dependencies.single;
        expect(dependency.matches('1.0.0-beta.11'), isTrue);
        expect(dependency.matches('1.0.0-alpha'), isFalse);
        json['dependencies'] = [
          {'id': json['id'], 'version': '*'},
        ];
        expect(() => PluginManifest.fromJson(json), throwsFormatException);
        json['dependencies'] = [
          {'id': 'org.example.base', 'version': '1.0.0'},
          {'id': 'org.example.base', 'version': '>=1.0.0'},
        ];
        expect(() => PluginManifest.fromJson(json), throwsFormatException);
      },
    );

    test('copies contribution JSON without authorizing application fields', () {
      final theme = <String, dynamic>{
        'id': 'glass',
        'tokens': {'card_style': 'liquid'},
      };
      final ai = <String, dynamic>{
        'providers': [
          {'id': 'example'},
        ],
      };
      final manifest = PluginManifest.fromJson(
        manifestJson()
          ..['themes'] = [theme]
          ..['ai_configs'] = [ai],
      );
      (theme['tokens'] as Map)['card_style'] = 'changed';
      expect((manifest.themes.single['tokens'] as Map)['card_style'], 'liquid');
      expect(
        () => manifest.themes.single['id'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => PluginManifest.fromJson(
          manifestJson()
            ..['themes'] = [
              {'invalid': double.nan},
            ],
        ),
        throwsFormatException,
      );
      Object? nested;
      for (var i = 0; i < 40; i++) {
        nested = [nested];
      }
      expect(
        () => PluginManifest.fromJson(
          manifestJson()
            ..['themes'] = [
              {'deep': nested},
            ],
        ),
        throwsFormatException,
      );
    });
  });

  group('host node field schema and values', () {
    test('validates all field kinds and only applies declared defaults', () {
      final node = PluginNodeDefinition.fromJson(nodeJson());
      expect(node.validateValues({}), {
        'gain': 0,
        'count': 2,
        'enabled': true,
        'title': '',
        'mode': 'soft',
      });
      expect(
        node.validateValues({
          'count': 3.0,
          'enabled': false,
          'title': 'label',
          'mode': 'hard',
        }, fillDefaults: false),
        {'count': 3, 'enabled': false, 'title': 'label', 'mode': 'hard'},
      );
      expect(
        PluginNodeDefinition.fromJson(node.toJson()).toJson(),
        node.toJson(),
      );
      for (final values in [
        <String, dynamic>{'gain': double.infinity},
        {'gain': 25},
        {'gain': '1'},
        {'count': 1.5},
        {'count': 0},
        {'enabled': 1},
        {'title': null},
        {'mode': 'other'},
        {'action': 'shell'},
      ]) {
        expect(
          () => node.validateValues(values),
          throwsFormatException,
          reason: '$values',
        );
      }
    });

    test(
      'does not clamp or lose precision when normalizing integer fields',
      () {
        final field = PluginFieldDefinition.fromJson({
          'key': 'integer',
          'label': 'Integer',
          'type': 'integer',
          'default': 0,
        });
        expect(field.validateValue(9007199254740993), 9007199254740993);
        expect(field.validateValue(3.0), 3);
        expect(() => field.validateValue(1e100), throwsFormatException);
        expect(
          () => PluginFieldDefinition.fromJson({
            'key': 'integer',
            'label': 'Integer',
            'type': 'integer',
            'default': 0,
            'max': 1e100,
          }),
          throwsFormatException,
        );
      },
    );

    test('rejects duplicate nodes, fields, malformed IO and media', () {
      expect(
        () => PluginManifest.fromJson(
          manifestJson()..['Node_info'] = [nodeJson(), nodeJson()],
        ),
        throwsFormatException,
      );
      final node = nodeJson();
      node['fields'] = [node['fields'][0], node['fields'][0]];
      expect(() => PluginNodeDefinition.fromJson(node), throwsFormatException);
      for (final inputs in [0, 2, '1']) {
        expect(
          () => PluginNodeDefinition.fromJson(
            nodeJson()..['IO'] = {'inputs': inputs, 'outputs': 1},
          ),
          throwsFormatException,
        );
      }
      expect(
        () => PluginNodeDefinition.fromJson(
          nodeJson()..['input_types'] = ['audio', 'audio'],
        ),
        throwsFormatException,
      );
      expect(
        () => PluginNodeDefinition.fromJson(
          nodeJson()..['output_type'] = 'shell',
        ),
        throwsFormatException,
      );
      expect(
        () => PluginNodeDefinition.fromJson(nodeJson()..['schema_version'] = 2),
        throwsFormatException,
      );
    });

    test('rejects malformed schemas before the host renders them', () {
      final base = {
        'key': 'n',
        'label': 'Number',
        'type': 'number',
        'default': 0,
      };
      for (final bad in [
        base..['unknown'] = true,
        {
          'key': 'n',
          'label': 'Number',
          'type': 'number',
          'default': 10,
          'max': 2,
        },
        {
          'key': 'n',
          'label': 'Number',
          'type': 'number',
          'default': 0,
          'min': 2,
          'max': 1,
        },
        {
          'key': 'n',
          'label': 'Number',
          'type': 'integer',
          'default': 1,
          'min': 0.5,
        },
        {'key': 'x', 'label': 'X', 'type': 'string', 'default': '', 'min': 0},
        {
          'key': 'x',
          'label': 'X',
          'type': 'select',
          'default': 'a',
          'options': ['a', 'a'],
        },
        {'key': 'x', 'label': 'X', 'type': 'select', 'default': 'a'},
        {'key': 'x', 'label': 'X', 'type': 'widget', 'default': ''},
      ]) {
        expect(
          () => PluginFieldDefinition.fromJson(bad),
          throwsFormatException,
        );
      }
    });
  });

  group('semver precedence and comparator ranges', () {
    test('uses SemVer prerelease precedence and ignores build metadata', () {
      final versions = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      for (var i = 1; i < versions.length; i++) {
        expect(
          PluginVersion.parse(
            versions[i - 1],
          ).compareTo(PluginVersion.parse(versions[i])),
          lessThan(0),
        );
      }
      expect(
        PluginVersion.parse(
          '1.0.0+a',
        ).compareTo(PluginVersion.parse('1.0.0+b')),
        0,
      );
      expect(
        PluginVersion.parse(
          '999999999999999999999.0.0',
        ).compareTo(PluginVersion.parse('999999999999999999998.0.0')),
        greaterThan(0),
      );
      expect(
        PluginVersionConstraint.parse(
          '>=1.0.0-beta.2 <1.0.0',
        ).matches('1.0.0-beta.11'),
        isTrue,
      );
      expect(
        PluginVersionConstraint.parse('>=1.0.0-beta.2 <1.0.0').matches('1.0.0'),
        isFalse,
      );
      expect(
        PluginVersionConstraint.parse('1.0.0').matches('1.0.0+build'),
        isTrue,
      );
      expect(
        PluginVersionConstraint.parse('*').matches('0.0.0-preview'),
        isTrue,
      );
    });

    test('rejects malformed semver and comparator syntax', () {
      for (final value in [
        '1',
        '1.0',
        'v1.0.0',
        '01.0.0',
        '1.01.0',
        '1.0.0-01',
        '1.0.0-',
        '1.0.0+',
      ]) {
        expect(
          () => PluginVersion.parse(value),
          throwsFormatException,
          reason: value,
        );
      }
      for (final value in [
        '',
        '^1.0.0',
        '>= 1.0.0',
        '>=1.0.0 || <2.0.0',
        '=>1.0.0',
        '**',
      ]) {
        expect(
          () => PluginVersionConstraint.parse(value),
          throwsFormatException,
          reason: value,
        );
      }
    });
  });

  group('enabled node catalog', () {
    test(
      'publishes only live declarations, matching plugin and schema versions',
      () {
        final catalog = PluginNodeCatalog();
        final source = manifestJson();
        final manifest = PluginManifest.fromJson(source);
        catalog.replaceAll([manifest]);
        final entry = catalog.entries.single;
        expect(entry.pluginId, manifest.id);
        expect(entry.pluginVersion, manifest.version);
        expect(entry.definition.id, 'volume');
        expect(
          catalog.isAvailable(
            manifest.id,
            'volume',
            version: manifest.version,
            schemaVersion: 1,
          ),
          isTrue,
        );
        expect(
          catalog.isAvailable(manifest.id, 'volume', version: 'old'),
          isFalse,
        );
        expect(
          catalog.isAvailable(manifest.id, 'volume', schemaVersion: 2),
          isFalse,
        );
        expect(catalog.lookup(manifest.id, 'undeclared'), isNull);
        catalog.clear();
        expect(catalog.lookup(manifest.id, 'volume'), isNull);
        expect(catalog.entries, isEmpty);
        // A stored snapshot remains available to graph code, never to execution.
        expect((source['Node_info'] as List).single['name'], 'Volume');
        expect(catalog.isAvailable(manifest.id, 'volume'), isFalse);
      },
    );

    test(
      'rejects malformed publication atomically and protects live snapshots',
      () {
        final catalog = PluginNodeCatalog();
        final manifest = PluginManifest.fromJson(manifestJson());
        catalog.publish([manifest]);
        final revision = catalog.revision;
        expect(
          () => catalog.replaceAll([manifest, manifest]),
          throwsFormatException,
        );
        expect(catalog.revision, revision);
        expect(catalog.plugin(manifest.id)?.version, manifest.version);
        expect(
          () => catalog.replaceAll([
            PluginManifest(
              id: manifest.id,
              appVersion: '*',
              basicInfo: manifest.basicInfo,
              limits: const PluginLimits(memoryMb: 100),
            ),
          ]),
          throwsFormatException,
        );
        expect(catalog.revision, revision);
        expect(() => catalog.entries.clear(), throwsUnsupportedError);
        expect(
          () => catalog.lookup(manifest.id, 'volume')!.fields.clear(),
          throwsUnsupportedError,
        );
      },
    );
  });
}
