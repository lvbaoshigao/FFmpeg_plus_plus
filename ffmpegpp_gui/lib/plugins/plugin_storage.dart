import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'plugin_runtime.dart';

const pluginMaxPackageBytes = 16 * 1024 * 1024;
const pluginMaxExpandedBytes = 32 * 1024 * 1024;
const pluginMaxModuleBytes = 8 * 1024 * 1024;
const pluginMaxIconBytes = 512 * 1024;
const pluginMaxJsonBytes = 256 * 1024;
const pluginMaxHostBytes = 128 * 1024;
const pluginMaxDataBytes = 16 * 1024 * 1024;
const _maxEntries = 256;
const _uuid = Uuid();

/// Never normalize an untrusted path into a different acceptable path. Reject
/// Windows drive/UNC paths, device aliases, POSIX traversal and Unicode aliases.
String validatePluginRelativePath(String path, {bool directory = false}) {
  final value = directory && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  if (value.isEmpty ||
      value.length > 240 ||
      !RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(value) ||
      value.startsWith('/')) {
    throw const PluginException(
      'Invalid plugin-relative path.',
      code: 'unsafe_path',
    );
  }
  for (final part in value.split('/')) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(part)) {
      throw const PluginException(
        'Unsafe or ambiguous plugin path.',
        code: 'unsafe_path',
      );
    }
  }
  return value;
}

bool pluginJsonEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (key) => b.containsKey(key) && pluginJsonEqual(a[key], b[key]),
        );
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!pluginJsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

class PluginPackageContents {
  final Map<String, dynamic> manifest;
  final Map<String, Uint8List> files;
  final int compressedSize;
  final int expandedSize;
  PluginPackageContents(
    this.manifest,
    this.files,
    this.compressedSize,
    this.expandedSize,
  );
}

/// Validate ZIP central and local records before inflating any content. Actual
/// output is bounded during decompression, independently of claimed ZIP sizes.
PluginPackageContents decodePluginPackage(Uint8List bytes) {
  if (bytes.length < 22 || bytes.length > pluginMaxPackageBytes) {
    throw const PluginException(
      'Plugin package size is invalid.',
      code: 'package_size',
    );
  }
  try {
    final data = ByteData.sublistView(bytes);
    int u16(int at) => data.getUint16(at, Endian.little);
    int u32(int at) => data.getUint32(at, Endian.little);
    var eocd = -1;
    final start = (bytes.length - 65557).clamp(0, bytes.length);
    for (var at = bytes.length - 22; at >= start; at--) {
      if (u32(at) == 0x06054b50 && at + 22 + u16(at + 20) == bytes.length) {
        eocd = at;
        break;
      }
    }
    if (eocd < 0 ||
        u16(eocd + 4) != 0 ||
        u16(eocd + 6) != 0 ||
        u16(eocd + 8) != u16(eocd + 10)) {
      throw const FormatException(
        'Missing ZIP directory or unsupported multi-disk ZIP.',
      );
    }
    final count = u16(eocd + 10);
    final centralSize = u32(eocd + 12);
    final centralAt = u32(eocd + 16);
    if (count == 0 ||
        count > _maxEntries ||
        centralAt + centralSize != eocd ||
        centralSize == 0xffffffff ||
        centralAt == 0xffffffff) {
      throw const FormatException('Unsupported ZIP directory or ZIP64.');
    }
    final entries = <_ZipEntry>[];
    final paths = <String, bool>{};
    var cursor = centralAt;
    var expanded = 0;
    for (var i = 0; i < count; i++) {
      if (cursor + 46 > eocd || u32(cursor) != 0x02014b50) {
        throw const FormatException('Truncated ZIP directory.');
      }
      final flags = u16(cursor + 8);
      final method = u16(cursor + 10);
      final crc = u32(cursor + 16);
      final compressed = u32(cursor + 20);
      final size = u32(cursor + 24);
      final nameLength = u16(cursor + 28);
      final extraLength = u16(cursor + 30);
      final commentLength = u16(cursor + 32);
      final external = u32(cursor + 38);
      final localAt = u32(cursor + 42);
      final end = cursor + 46 + nameLength + extraLength + commentLength;
      if (end > eocd ||
          nameLength == 0 ||
          u16(cursor + 34) != 0 ||
          (flags & ~0x080e) != 0 ||
          (flags & 1) != 0 ||
          (method != 0 && method != 8) ||
          size > pluginMaxModuleBytes ||
          compressed > pluginMaxPackageBytes ||
          localAt == 0xffffffff) {
        throw const FormatException('Unsupported or oversized ZIP entry.');
      }
      final nameBytes = Uint8List.sublistView(
        bytes,
        cursor + 46,
        cursor + 46 + nameLength,
      );
      if (nameBytes.any((value) => value > 127)) {
        throw const FormatException('Package paths must use portable ASCII.');
      }
      final name = ascii.decode(nameBytes);
      final isDirectory = name.endsWith('/');
      final path = validatePluginRelativePath(name, directory: isDirectory);
      final mode = (external >> 16) & 0xf000;
      if ((mode != 0 && mode != 0x8000 && mode != 0x4000) ||
          (mode == 0x4000 && !isDirectory) ||
          (mode == 0x8000 && isDirectory) ||
          ((external & 0x10) != 0 && !isDirectory) ||
          (isDirectory && (size != 0 || compressed != 0))) {
        throw const FormatException(
          'Links and non-regular ZIP entries are forbidden.',
        );
      }
      final key = path.toLowerCase();
      if (paths.containsKey(key)) {
        throw const FormatException('Duplicate or case-aliased ZIP path.');
      }
      paths[key] = isDirectory;
      expanded += size;
      if (expanded > pluginMaxExpandedBytes) {
        throw const FormatException('ZIP exceeds the expanded package budget.');
      }
      if (localAt + 30 > centralAt ||
          u32(localAt) != 0x04034b50 ||
          u16(localAt + 6) != flags ||
          u16(localAt + 8) != method) {
        throw const FormatException('Inconsistent ZIP local header.');
      }
      final localNameLength = u16(localAt + 26);
      final localExtraLength = u16(localAt + 28);
      final payloadAt = localAt + 30 + localNameLength + localExtraLength;
      if (localNameLength != nameLength ||
          payloadAt + compressed > centralAt ||
          !pluginJsonEqual(
            nameBytes,
            Uint8List.sublistView(
              bytes,
              localAt + 30,
              localAt + 30 + localNameLength,
            ),
          )) {
        throw const FormatException(
          'ZIP local name or payload does not match.',
        );
      }
      if ((flags & 8) == 0 &&
          (u32(localAt + 14) != crc ||
              u32(localAt + 18) != compressed ||
              u32(localAt + 22) != size)) {
        throw const FormatException('ZIP declared sizes do not agree.');
      }
      entries.add(
        _ZipEntry(
          path,
          isDirectory,
          method,
          crc,
          compressed,
          size,
          localAt,
          payloadAt,
        ),
      );
      cursor = end;
    }
    if (cursor != eocd) {
      throw const FormatException('Unexpected ZIP directory bytes.');
    }
    for (final entry in entries) {
      final parts = entry.path.toLowerCase().split('/');
      for (var i = 1; i < parts.length; i++) {
        if (paths[parts.take(i).join('/')] == false) {
          throw const FormatException('ZIP file used as parent directory.');
        }
      }
    }
    entries.sort((a, b) => a.localAt.compareTo(b.localAt));
    var previousEnd = 0;
    for (final entry in entries) {
      if (entry.localAt < previousEnd) {
        throw const FormatException('Overlapping ZIP payloads.');
      }
      previousEnd = entry.payloadAt + entry.compressed;
    }
    final files = <String, Uint8List>{};
    var actualTotal = 0;
    for (final entry in entries) {
      if (entry.directory) continue;
      final compressed = Uint8List.sublistView(
        bytes,
        entry.payloadAt,
        entry.payloadAt + entry.compressed,
      );
      final sink = _BoundedByteSink(entry.size);
      if (entry.method == 0) {
        sink.add(compressed);
      } else {
        final decoder = ZLibDecoder(raw: true).startChunkedConversion(sink);
        for (var at = 0; at < compressed.length; at += 1024) {
          decoder.add(
            Uint8List.sublistView(
              compressed,
              at,
              (at + 1024).clamp(0, compressed.length),
            ),
          );
        }
        decoder.close();
      }
      final content = sink.takeBytes();
      actualTotal += content.length;
      if (content.length != entry.size ||
          getCrc32(content) != entry.crc ||
          actualTotal > pluginMaxExpandedBytes) {
        throw const FormatException('ZIP size or CRC check failed.');
      }
      files[entry.path] = content;
    }
    final manifestBytes = files['manifest.json'];
    if (manifestBytes == null || manifestBytes.length > pluginMaxJsonBytes) {
      throw const FormatException('Root manifest.json is required.');
    }
    final manifest = jsonDecode(utf8.decode(manifestBytes));
    if (manifest is! Map<String, dynamic>) {
      throw const FormatException('The manifest must be an object.');
    }
    return PluginPackageContents(manifest, files, bytes.length, actualTotal);
  } on PluginException {
    rethrow;
  } catch (error) {
    throw PluginException(
      'Invalid plugin package: $error',
      code: 'invalid_package',
    );
  }
}

class _ZipEntry {
  final String path;
  final bool directory;
  final int method, crc, compressed, size, localAt, payloadAt;
  _ZipEntry(
    this.path,
    this.directory,
    this.method,
    this.crc,
    this.compressed,
    this.size,
    this.localAt,
    this.payloadAt,
  );
}

class _BoundedByteSink implements Sink<List<int>> {
  final int limit;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int _length = 0;
  _BoundedByteSink(this.limit);
  @override
  void add(List<int> data) {
    if (_length + data.length > limit) {
      throw const PluginException(
        'Expanded content exceeds its declared size.',
        code: 'expanded_size',
      );
    }
    _length += data.length;
    _bytes.add(data);
  }

  @override
  void close() {}
  Uint8List takeBytes() => _bytes.takeBytes();
}

class PluginStoredVersion {
  final String directoryName;
  final Map<String, dynamic> manifest;
  final String? moduleSha256;
  PluginStoredVersion({
    required this.directoryName,
    required this.manifest,
    this.moduleSha256,
  });
  Map<String, dynamic> toJson() => {
    'directory': directoryName,
    'manifest': manifest,
    if (moduleSha256 != null) 'module_sha256': moduleSha256,
  };
  factory PluginStoredVersion.fromJson(Map<String, dynamic> value) {
    final directory = value['directory'];
    final manifest = value['manifest'];
    final hash = value['module_sha256'];
    if (directory is! String ||
        !RegExp(r'^v_[a-f0-9-]{36}$').hasMatch(directory) ||
        manifest is! Map<String, dynamic> ||
        (hash != null &&
            (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)))) {
      throw const PluginException(
        'Invalid stored plugin version.',
        code: 'invalid_storage',
      );
    }
    return PluginStoredVersion(
      directoryName: directory,
      manifest: manifest,
      moduleSha256: hash as String?,
    );
  }
}

class PluginStoredRecord {
  final PluginStoredVersion version;
  final PluginStoredVersion? previousVersion;
  final bool enabled;
  final Set<String> grantedPermissions;
  final String? lastError;
  String get id => version.manifest['id'] as String;
  PluginStoredRecord({
    required this.version,
    this.previousVersion,
    this.enabled = false,
    Set<String> grantedPermissions = const {},
    Set<String> disabledNodeIds = const {},
    this.lastError,
  }) : grantedPermissions = Set.unmodifiable(grantedPermissions),
       disabledNodeIds = Set.unmodifiable(disabledNodeIds);
  final Set<String> disabledNodeIds;
  Map<String, dynamic> toJson() => {
    'version': version.toJson(),
    if (previousVersion != null) 'previous': previousVersion!.toJson(),
    'enabled': enabled,
    'granted_permissions': grantedPermissions.toList()..sort(),
    if (disabledNodeIds.isNotEmpty)
      'disabled_nodes': disabledNodeIds.toList()..sort(),
    if (lastError != null) 'last_error': lastError,
  };
  factory PluginStoredRecord.fromJson(Map<String, dynamic> value) {
    final grants = value['granted_permissions'];
    final disabledNodes = value['disabled_nodes'] ?? const <dynamic>[];
    if (value['version'] is! Map<String, dynamic> ||
        (value['previous'] != null &&
            value['previous'] is! Map<String, dynamic>) ||
        value['enabled'] is! bool ||
        grants is! List ||
        grants.length > 64 ||
        grants.any((key) => key is! String || key.length > 2048) ||
        disabledNodes is! List ||
        disabledNodes.length > 128 ||
        disabledNodes.any(
          (id) =>
              id is! String ||
              !RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,127}$').hasMatch(id),
        ) ||
        disabledNodes.toSet().length != disabledNodes.length ||
        (value['last_error'] != null && value['last_error'] is! String)) {
      throw const PluginException(
        'Invalid stored plugin record.',
        code: 'invalid_storage',
      );
    }
    return PluginStoredRecord(
      version: PluginStoredVersion.fromJson(
        value['version'] as Map<String, dynamic>,
      ),
      previousVersion: value['previous'] == null
          ? null
          : PluginStoredVersion.fromJson(
              value['previous'] as Map<String, dynamic>,
            ),
      enabled: value['enabled'] as bool,
      grantedPermissions: grants.cast<String>().toSet(),
      disabledNodeIds: disabledNodes.cast<String>().toSet(),
      lastError: value['last_error'] as String?,
    );
  }
}

/// Immutable private package directories plus an atomically replaced registry.
/// No active version is deleted before its replacement registry is committed.
class PluginStorage {
  final Directory root;
  Directory? _canonicalRoot;
  PluginStorage(this.root);

  Future<void> initialize() async {
    // A trailing separator makes lstat-style checks follow a directory link.
    // Inspect the original directory entry before canonicalizing the root.
    var absolutePath = root.absolute.path;
    while (absolutePath.length > 1 &&
        (absolutePath.endsWith('/') || absolutePath.endsWith(r'\'))) {
      absolutePath = absolutePath.substring(0, absolutePath.length - 1);
    }
    final absolute = Directory(absolutePath);
    if (await FileSystemEntity.type(absolute.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const PluginException(
        'Plugin root cannot be a symbolic link.',
        code: 'unsafe_storage',
      );
    }
    await absolute.create(recursive: true);
    _canonicalRoot = Directory(await absolute.resolveSymbolicLinks());
    await _assertRoot();
    await _directory('packages', create: true);
    await _directory('staging', create: true);
    await _directory('data', create: true);
    final registry = await _file('registry.json');
    final backup = await _file('registry.previous.json');
    if (!await registry.exists() && await backup.exists()) {
      await backup.rename(registry.path);
    }
  }

  Future<List<PluginStoredRecord>> load() async {
    final registry = await _file('registry.json');
    if (!await registry.exists()) return [];
    final json = jsonDecode(
      utf8.decode(await _readBounded(registry, 8 * 1024 * 1024)),
    );
    if (json is! Map ||
        json['format_version'] != 1 ||
        json['plugins'] is! List ||
        (json['plugins'] as List).length > 256) {
      throw const PluginException(
        'Invalid plugin registry.',
        code: 'invalid_storage',
      );
    }
    final records = <PluginStoredRecord>[];
    final ids = <String>{};
    final directories = <String>{};
    for (final raw in json['plugins'] as List) {
      if (raw is! Map<String, dynamic>) {
        throw const PluginException('Invalid plugin registry item.');
      }
      final record = PluginStoredRecord.fromJson(raw);
      if (!ids.add(record.id) ||
          !directories.add(record.version.directoryName) ||
          (record.previousVersion != null &&
              !directories.add(record.previousVersion!.directoryName))) {
        throw const PluginException(
          'Duplicate plugin registry identity.',
          code: 'invalid_storage',
        );
      }
      records.add(record);
    }
    return records;
  }

  Future<void> save(Iterable<PluginStoredRecord> records) async {
    final bytes = utf8.encode(
      jsonEncode({
        'format_version': 1,
        'plugins': records.map((record) => record.toJson()).toList(),
      }),
    );
    if (bytes.length > 8 * 1024 * 1024) {
      throw const PluginException('Plugin registry is full.');
    }
    await _atomicWrite(
      'registry.json',
      bytes,
      backupName: 'registry.previous.json',
    );
  }

  Future<PluginStoredVersion> stagePackage(
    PluginPackageContents package,
    String? modulePath,
  ) async {
    final token = _uuid.v4();
    final staging = 'staging/s_$token';
    final destination = 'packages/v_$token';
    await _directory(staging, create: true);
    try {
      for (final entry in package.files.entries) {
        final path = validatePluginRelativePath(entry.key);
        final split = path.lastIndexOf('/');
        if (split >= 0) {
          await _directory(
            '$staging/${path.substring(0, split)}',
            create: true,
          );
        }
        final file = await _file('$staging/$path');
        await file.writeAsBytes(entry.value, flush: true);
      }
      final source = await _directory(staging);
      await _checkPath(destination);
      await source.rename(_path(destination));
      return PluginStoredVersion(
        directoryName: 'v_$token',
        manifest: package.manifest,
        moduleSha256: modulePath == null
            ? null
            : sha256.convert(package.files[modulePath]!).toString(),
      );
    } catch (_) {
      await discardStaging(staging);
      rethrow;
    }
  }

  Future<void> validateVersion(PluginStoredVersion version) async {
    final directory = _versionDirectory(version);
    await _directory(directory);
    final file = await _file('$directory/manifest.json');
    final parsed = jsonDecode(
      utf8.decode(await _readBounded(file, pluginMaxJsonBytes)),
    );
    if (!pluginJsonEqual(parsed, version.manifest)) {
      throw const PluginException(
        'Installed manifest differs from the registry.',
        code: 'package_changed',
      );
    }
  }

  Future<String> modulePath(
    PluginStoredVersion version,
    String relativePath,
  ) async {
    await validateVersion(version);
    final relative = validatePluginRelativePath(relativePath);
    final file = await _file('${_versionDirectory(version)}/$relative');
    final bytes = await _readBounded(file, pluginMaxModuleBytes);
    if (version.moduleSha256 == null ||
        sha256.convert(bytes).toString() != version.moduleSha256) {
      throw const PluginException(
        'Installed WebAssembly module has changed.',
        code: 'package_changed',
      );
    }
    return file.path;
  }

  Future<Uint8List> readPackageFile(
    PluginStoredVersion version,
    String relativePath, {
    int maxBytes = 512 * 1024,
  }) async {
    await validateVersion(version);
    final relative = validatePluginRelativePath(relativePath);
    final file = await _file('${_versionDirectory(version)}/$relative');
    return _readBounded(file, maxBytes);
  }

  Future<void> removeVersion(PluginStoredVersion version) async =>
      _deleteTree(_versionDirectory(version));
  Future<void> removeData(String pluginId) =>
      _deleteTree(_dataDirectory(pluginId));

  Future<void> discardStaging(String relative) async {
    if (!RegExp(r'^staging/s_[a-f0-9-]{36}$').hasMatch(relative)) {
      throw const PluginException(
        'Invalid staging directory.',
        code: 'unsafe_storage',
      );
    }
    await _deleteTree(relative);
  }

  Future<Uint8List> readData(String pluginId, String path) async {
    final relative = validatePluginRelativePath(path);
    final file = await _file('${_dataDirectory(pluginId)}/$relative');
    return _readBounded(file, pluginMaxHostBytes);
  }

  Future<void> writeData(
    String pluginId,
    String path,
    Uint8List bytes, {
    required void Function() checkActive,
  }) async {
    final relative = validatePluginRelativePath(path);
    if (bytes.length > pluginMaxHostBytes) {
      throw const PluginException('Host write exceeds the content budget.');
    }
    final base = _dataDirectory(pluginId);
    await _directory(base, create: true);
    final usage = await _dataUsage(base);
    final target = await _file('$base/$relative');
    final oldLength = await target.exists() ? await target.length() : 0;
    if (usage.$1 - oldLength + bytes.length > pluginMaxDataBytes ||
        (oldLength == 0 && usage.$2 >= _maxEntries)) {
      throw const PluginException(
        'Plugin private storage quota exceeded.',
        code: 'storage_quota',
      );
    }
    final split = relative.lastIndexOf('/');
    if (split >= 0) {
      await _directory('$base/${relative.substring(0, split)}', create: true);
    }
    checkActive();
    await _atomicWrite('$base/$relative', bytes, beforeCommit: checkActive);
  }

  Future<(int, int)> _dataUsage(String relative) async {
    final base = await _directory(relative);
    var size = 0;
    var files = 0;
    await for (final entry in base.list(recursive: true, followLinks: false)) {
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const PluginException('Links in plugin data are forbidden.');
      }
      if (type == FileSystemEntityType.file) {
        size += await File(entry.path).length();
        files++;
        if (size > pluginMaxDataBytes || files > _maxEntries) break;
      }
    }
    return (size, files);
  }

  String _versionDirectory(PluginStoredVersion version) {
    if (!RegExp(r'^v_[a-f0-9-]{36}$').hasMatch(version.directoryName)) {
      throw const PluginException(
        'Invalid stored package directory.',
        code: 'unsafe_storage',
      );
    }
    return 'packages/${version.directoryName}';
  }

  String _dataDirectory(String pluginId) =>
      'data/${sha256.convert(utf8.encode(pluginId))}';
  String _path(String relative) =>
      File.fromUri(_canonicalRoot!.uri.resolve(relative)).path;

  Future<void> _assertRoot() async {
    final canonical = _canonicalRoot;
    if (canonical == null ||
        await FileSystemEntity.type(canonical.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await canonical.resolveSymbolicLinks() != canonical.path) {
      throw const PluginException(
        'Plugin private root is unavailable or linked.',
        code: 'unsafe_storage',
      );
    }
  }

  Future<void> _checkPath(String relative) async {
    await _assertRoot();
    validatePluginRelativePath(relative);
    final parts = relative.split('/');
    for (var i = 1; i <= parts.length; i++) {
      final type = await FileSystemEntity.type(
        _path(parts.take(i).join('/')),
        followLinks: false,
      );
      if (type == FileSystemEntityType.link ||
          (i < parts.length &&
              type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory)) {
        throw const PluginException(
          'Plugin storage contains a link or non-directory ancestor.',
          code: 'unsafe_storage',
        );
      }
    }
  }

  Future<Directory> _directory(String relative, {bool create = false}) async {
    await _checkPath(relative);
    final directory = Directory(_path(relative));
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound && create) {
      await directory.create(recursive: true);
      await _checkPath(relative);
    } else if (type != FileSystemEntityType.directory &&
        !(type == FileSystemEntityType.notFound && !create)) {
      throw const PluginException(
        'Plugin storage directory is invalid.',
        code: 'unsafe_storage',
      );
    }
    return directory;
  }

  Future<File> _file(String relative) async {
    await _checkPath(relative);
    final path = _path(relative);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const PluginException(
        'Plugin file is not regular.',
        code: 'unsafe_storage',
      );
    }
    return File(path);
  }

  Future<Uint8List> _readBounded(File file, int limit) async {
    if (await file.length() > limit) {
      throw const PluginException('Plugin file exceeds its size limit.');
    }
    final sink = _BoundedByteSink(limit);
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    return sink.takeBytes();
  }

  Future<void> _atomicWrite(
    String relative,
    List<int> bytes, {
    String? backupName,
    void Function()? beforeCommit,
  }) async {
    final slash = relative.lastIndexOf('/');
    final parent = slash < 0 ? '' : relative.substring(0, slash + 1);
    final target = await _file(relative);
    final temporaryName = '$parent.tx_${_uuid.v4()}.tmp';
    final backupRelative = backupName ?? '$parent.tx_${_uuid.v4()}.bak';
    final temporary = await _file(temporaryName);
    var movedOld = false;
    var committed = false;
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await _checkPath(relative);
      beforeCommit?.call();
      if (await target.exists()) {
        final backup = await _file(backupRelative);
        if (await backup.exists()) await backup.delete();
        await target.rename(backup.path);
        movedOld = true;
      }
      beforeCommit?.call();
      await temporary.rename(target.path);
      committed = true;
    } catch (_) {
      if (movedOld && !await target.exists()) {
        final backup = await _file(backupRelative);
        if (await backup.exists()) await backup.rename(target.path);
      }
      rethrow;
    } finally {
      // Cleanup cannot turn an already committed registry into a failed commit.
      // Inert private files are preferable to removing its referenced version.
      try {
        final temp = await _file(temporaryName);
        if (await temp.exists()) await temp.delete();
        if (committed && movedOld) {
          final backup = await _file(backupRelative);
          if (await backup.exists()) await backup.delete();
        }
      } catch (_) {}
    }
  }

  Future<void> _deleteTree(String relative) async {
    await _checkPath(relative);
    final directory = Directory(_path(relative));
    if (!await directory.exists()) return;
    final entries = await directory.list(followLinks: false).toList();
    for (final entry in entries) {
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      final childRelative = '$relative/$name';
      validatePluginRelativePath(childRelative);
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await _deleteTree(childRelative);
      } else if (type == FileSystemEntityType.link) {
        await Link(
          entry.path,
        ).delete(); // Never follow a link when removing data.
      } else if (type == FileSystemEntityType.file) {
        await File(entry.path).delete();
      } else {
        throw const PluginException(
          'Unsafe entry in plugin storage.',
          code: 'unsafe_storage',
        );
      }
    }
    await _checkPath(relative);
    await directory.delete();
  }
}
