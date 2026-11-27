import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart';
import 'package:ffmpegpp_gui/plugins/plugin_runtime.dart';
import 'package:ffmpegpp_gui/plugins/plugin_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Entry {
  final String name;
  final List<int> content;
  final String? localName;
  final int? declared;
  final int mode;
  final bool deflate;
  const _Entry(
    this.name,
    this.content, {
    this.localName,
    this.declared,
    this.mode = 0x8000,
    this.deflate = false,
  });
}

/// Minimal adversarial ZIP builder; unlike Archive.addFile it preserves duplicate
/// names and lets tests make local/central records consistently lie about sizes.
Uint8List _zip(List<_Entry> entries) {
  final locals = BytesBuilder();
  final central = BytesBuilder();
  for (final entry in entries) {
    final name = utf8.encode(entry.name);
    final localName = utf8.encode(entry.localName ?? entry.name);
    final bytes = entry.deflate
        ? ZLibEncoder(raw: true).convert(entry.content)
        : entry.content;
    final header = ByteData(30);
    header.setUint32(0, 0x04034b50, Endian.little);
    header.setUint16(4, 20, Endian.little);
    header.setUint16(8, entry.deflate ? 8 : 0, Endian.little);
    header.setUint32(14, getCrc32(entry.content), Endian.little);
    header.setUint32(18, bytes.length, Endian.little);
    header.setUint32(22, entry.declared ?? entry.content.length, Endian.little);
    header.setUint16(26, localName.length, Endian.little);
    final directory = ByteData(46);
    directory.setUint32(0, 0x02014b50, Endian.little);
    directory.setUint16(4, (3 << 8) | 20, Endian.little);
    directory.setUint16(6, 20, Endian.little);
    directory.setUint16(10, entry.deflate ? 8 : 0, Endian.little);
    directory.setUint32(16, getCrc32(entry.content), Endian.little);
    directory.setUint32(20, bytes.length, Endian.little);
    directory.setUint32(
      24,
      entry.declared ?? entry.content.length,
      Endian.little,
    );
    directory.setUint16(28, name.length, Endian.little);
    directory.setUint32(38, entry.mode << 16, Endian.little);
    directory.setUint32(42, locals.length, Endian.little);
    locals.add(header.buffer.asUint8List());
    locals.add(localName);
    locals.add(bytes);
    central.add(directory.buffer.asUint8List());
    central.add(name);
  }
  final end = ByteData(22);
  end.setUint32(0, 0x06054b50, Endian.little);
  end.setUint16(8, entries.length, Endian.little);
  end.setUint16(10, entries.length, Endian.little);
  end.setUint32(12, central.length, Endian.little);
  end.setUint32(16, locals.length, Endian.little);
  return (BytesBuilder()
        ..add(locals.takeBytes())
        ..add(central.takeBytes())
        ..add(end.buffer.asUint8List()))
      .takeBytes();
}

_Entry _manifest() =>
    _Entry('manifest.json', utf8.encode('{"id":"org.example.data"}'));

void main() {
  test(
    'safe portable stored and deflated packages decode with real size and CRC checks',
    () {
      final contents = decodePluginPackage(
        _zip([
          _manifest(),
          _Entry('assets/readme.txt', utf8.encode('hello'), deflate: true),
        ]),
      );
      expect(contents.manifest['id'], 'org.example.data');
      expect(utf8.decode(contents.files['assets/readme.txt']!), 'hello');
      expect(
        contents.expandedSize,
        contents.files.values.fold<int>(0, (sum, bytes) => sum + bytes.length),
      );
    },
  );
  for (final name in [
    '../escape',
    '/absolute',
    r'C:\escape',
    r'\\host\share',
    'a/../../escape',
    'a//b',
    'a/./b',
    'a/b.',
    'CON.txt',
    'aux',
    'lpt1.log',
    'percent%2fescape',
    'unicodé',
  ]) {
    test('rejects unsafe archive path $name before extraction', () {
      expect(
        () => decodePluginPackage(
          _zip([
            _manifest(),
            _Entry(name, [1]),
          ]),
        ),
        throwsA(isA<PluginException>()),
      );
    });
  }
  test('rejects duplicate, case-folded and file/directory collisions', () {
    for (final entries in [
      [
        _manifest(),
        const _Entry('x', [1]),
        const _Entry('x', [2]),
      ],
      [
        _manifest(),
        const _Entry('A', [1]),
        const _Entry('a', [2]),
      ],
      [
        _manifest(),
        const _Entry('parent', [1]),
        const _Entry('parent/child', [2]),
      ],
    ]) {
      expect(
        () => decodePluginPackage(_zip(entries)),
        throwsA(isA<PluginException>()),
      );
    }
  });
  test('rejects symbolic links, devices and directory mode mismatches', () {
    for (final mode in [0xa000, 0x6000, 0x2000, 0x4000]) {
      expect(
        () => decodePluginPackage(
          _zip([
            _manifest(),
            _Entry('link', [1], mode: mode),
          ]),
        ),
        throwsA(isA<PluginException>()),
      );
    }
  });
  test('checks both declared and actual expanded size', () {
    expect(
      () => decodePluginPackage(
        _zip([
          _manifest(),
          const _Entry('large', [0], declared: pluginMaxModuleBytes + 1),
        ]),
      ),
      throwsA(isA<PluginException>()),
    );
    expect(
      () => decodePluginPackage(
        _zip([
          _manifest(),
          _Entry(
            'lie',
            List.filled(1024 * 1024, 0),
            declared: 1,
            deflate: true,
          ),
        ]),
      ),
      throwsA(isA<PluginException>()),
    );
    expect(
      () => decodePluginPackage(
        _zip([
          _manifest(),
          const _Entry('lie', [1, 2, 3], declared: 1),
        ]),
      ),
      throwsA(isA<PluginException>()),
    );
    expect(
      () => decodePluginPackage(
        _zip([
          _manifest(),
          ...List.generate(
            5,
            (i) => _Entry('file$i', [0], declared: pluginMaxModuleBytes),
          ),
        ]),
      ),
      throwsA(isA<PluginException>()),
    );
  });
  test('rejects entry-count overflow, header mismatch and corrupt content', () {
    expect(
      () => decodePluginPackage(
        _zip([_manifest(), ...List.generate(256, (i) => _Entry('file$i', []))]),
      ),
      throwsA(isA<PluginException>()),
    );
    expect(
      () => decodePluginPackage(
        _zip([
          _manifest(),
          const _Entry('safe.txt', [1], localName: 'evil.txt'),
        ]),
      ),
      throwsA(isA<PluginException>()),
    );
    final damaged = _zip([_manifest()]);
    damaged[30 + 'manifest.json'.length] ^= 1;
    expect(() => decodePluginPackage(damaged), throwsA(isA<PluginException>()));
  });

  group('private filesystem', () {
    late Directory root;
    late Directory outside;
    late PluginStorage storage;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('fpp-plugin-storage-');
      outside = await Directory.systemTemp.createTemp('fpp-plugin-outside-');
      storage = PluginStorage(root);
      await storage.initialize();
    });
    tearDown(() async {
      await root.delete(recursive: true);
      await outside.delete(recursive: true);
    });

    test('rejects an absolute or traversing file path', () async {
      for (final path in [
        '../escape',
        'a/../../escape',
        outside.path,
        r'C:\escape',
      ]) {
        await expectLater(
          storage.writeData(
            'org.example.data',
            path,
            Uint8List.fromList([1]),
            checkActive: () {},
          ),
          throwsA(isA<PluginException>()),
        );
      }
      expect(await outside.list().toList(), isEmpty);
    });
    test('rejects symbolic-link plugin roots and data ancestors', () async {
      final linkedRoot = Link('${outside.path}/plugins');
      await linkedRoot.create(root.path);
      await expectLater(
        PluginStorage(Directory(linkedRoot.path)).initialize(),
        throwsA(isA<PluginException>()),
      );
      final hashed = sha256.convert(utf8.encode('org.example.data')).toString();
      final dataRoot = Directory('${root.path}/data/$hashed');
      await dataRoot.create();
      await Link('${dataRoot.path}/linked').create(outside.path);
      await expectLater(
        storage.writeData(
          'org.example.data',
          'linked/escape',
          Uint8List.fromList([1]),
          checkActive: () {},
        ),
        throwsA(isA<PluginException>()),
      );
      expect(
        await outside.list().toList(),
        hasLength(1),
      ); // The root link only.
    });
    test('failed atomic replacement restores prior content', () async {
      await storage.writeData(
        'org.example.data',
        'state',
        Uint8List.fromList([1]),
        checkActive: () {},
      );
      var checks = 0;
      await expectLater(
        storage.writeData(
          'org.example.data',
          'state',
          Uint8List.fromList([2]),
          checkActive: () {
            if (++checks == 3) {
              throw const PluginException(
                'Disabled during commit.',
                code: 'cancelled',
              );
            }
          },
        ),
        throwsA(isA<PluginException>()),
      );
      expect(await storage.readData('org.example.data', 'state'), [1]);
    });
    test(
      'private file read/write content limit applies independently',
      () async {
        await expectLater(
          storage.writeData(
            'org.example.data',
            'huge',
            Uint8List(pluginMaxHostBytes + 1),
            checkActive: () {},
          ),
          throwsA(isA<PluginException>()),
        );
      },
    );
    test(
      'uninstall cleanup never follows private links or deletes outside files',
      () async {
        await File('${outside.path}/keep').writeAsString('safe');
        await storage.writeData(
          'org.example.data',
          'state',
          Uint8List.fromList([1]),
          checkActive: () {},
        );
        final hashed = sha256
            .convert(utf8.encode('org.example.data'))
            .toString();
        await Link('${root.path}/data/$hashed/link').create(outside.path);
        await storage.removeData('org.example.data');
        expect(await File('${outside.path}/keep').readAsString(), 'safe');
        expect(await Directory('${root.path}/data/$hashed').exists(), isFalse);
      },
    );
    test('module SHA detects modification of a staged executable', () async {
      final raw = _zip([
        _manifest(),
        const _Entry('plugin.wasm', [0, 97, 115, 109, 1, 0, 0, 0]),
      ]);
      final version = await storage.stagePackage(
        decodePluginPackage(raw),
        'plugin.wasm',
      );
      final path = await storage.modulePath(version, 'plugin.wasm');
      await File(path).writeAsBytes([0, 97, 115, 109, 1, 0, 0, 1]);
      await expectLater(
        storage.modulePath(version, 'plugin.wasm'),
        throwsA(isA<PluginException>()),
      );
      final bad = PluginStoredVersion(
        directoryName: '../../outside',
        manifest: version.manifest,
      );
      await expectLater(
        storage.removeVersion(bad),
        throwsA(isA<PluginException>()),
      );
    });
  });
}
