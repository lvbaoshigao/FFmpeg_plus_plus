import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'fppx2_service.dart';

class QuickConfigJsonPasswordRequired extends FormatException {
  const QuickConfigJsonPasswordRequired() : super('Password required');
}

class QuickConfigJsonPasswordException extends FormatException {
  const QuickConfigJsonPasswordException()
    : super('Wrong password, or the file is corrupted');
}

/// Complete editable quick presets, including disabled legacy items. Encryption
/// wraps the existing authenticated FPPX2/AES format; no Dart cipher is added.
class QuickConfigJsonCodec {
  QuickConfigJsonCodec(
    this._fppx, {
    Future<Directory> Function()? temporaryDirectory,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static const format = 'ffmpegpp.quick-config';
  static const _payloadKey = 'quick_config_json_v1';
  final FppxService _fppx;
  final Future<Directory> Function() _temporaryDirectory;

  Future<String> encode(
    QuickConfig config, {
    bool encrypted = false,
    String password = '',
    int encryptAlgo = FppxService.algoAes256Cbc,
  }) async {
    // Freeze the caller's complete state before the first asynchronous operation.
    final snapshot = config.deepCopy().toJson();
    _parseConfig(snapshot);
    final envelope = <String, dynamic>{
      'format': format,
      'version': 1,
      'encrypted': encrypted,
    };
    if (!encrypted) {
      envelope['config'] = snapshot;
    } else {
      if (password.isEmpty) {
        throw const FormatException('Password cannot be empty');
      }
      envelope['description'] = config.description;
      envelope['encoding'] = 'fppx2-base64';
      envelope['payload'] = await _withTemporaryFile((file) async {
        final result = await _fppx.exportQuickItems(
          file.path,
          description: snapshot['description'] as String,
          items: [
            {'key': _payloadKey, 'params': snapshot, 'enabled': true},
          ],
          encrypted: true,
          password: password,
          encryptAlgo: encryptAlgo,
        );
        if (!result.success) {
          throw FormatException(
            result.errors.isNotEmpty
                ? result.errors.join('; ')
                : result.error ?? 'Could not encrypt quick configuration',
          );
        }
        return base64Encode(await file.readAsBytes());
      });
    }
    return const JsonEncoder.withIndent('  ').convert(envelope);
  }

  Future<QuickConfig> decode(
    String source, {
    String password = '',
    String? id,
  }) async {
    final decoded = jsonDecode(
      source.startsWith('\uFEFF') ? source.substring(1) : source,
    );
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Quick configuration must be a JSON object');
    }
    // Also accept the existing local .fppq.json representation.
    if (!decoded.containsKey('format')) return _parseConfig(decoded, id: id);
    if (decoded['format'] != format ||
        decoded['version'] != 1 ||
        decoded['encrypted'] is! bool) {
      throw const FormatException(
        'Unsupported quick configuration JSON format',
      );
    }
    if (decoded['encrypted'] == false) {
      final config = decoded['config'];
      if (config is! Map<String, dynamic>) {
        throw const FormatException('Missing quick configuration data');
      }
      return _parseConfig(config, id: id);
    }
    if (decoded['encoding'] != 'fppx2-base64' ||
        decoded['payload'] is! String) {
      throw const FormatException(
        'Invalid encrypted quick configuration payload',
      );
    }
    // Validate base64 even before asking for a password; malformed JSON is not
    // a password challenge. The native reader authenticates the actual payload.
    final payload = base64Decode(decoded['payload'] as String);
    return _withTemporaryFile((file) async {
      await file.writeAsBytes(payload, flush: true);
      final result = await _fppx.importFile(file.path, password: password);
      if (result.needsPassword) throw const QuickConfigJsonPasswordRequired();
      if (!result.success) throw const QuickConfigJsonPasswordException();
      if (!result.encrypted ||
          result.mode != FppxService.modeQuick ||
          result.quickItems.length != 1 ||
          result.quickItems.single['key'] != _payloadKey ||
          result.quickItems.single['enabled'] != true ||
          result.quickItems.single['params'] is! Map<String, dynamic>) {
        throw const FormatException(
          'Invalid encrypted quick configuration data',
        );
      }
      return _parseConfig(
        result.quickItems.single['params'] as Map<String, dynamic>,
        id: id,
      );
    });
  }

  QuickConfig _parseConfig(Map<String, dynamic> data, {String? id}) {
    // QuickConfig.fromJson tolerates broken legacy storage entries. Exchange
    // files must fail instead of silently dropping an item and changing a preset.
    // Historical local JSON can omit file_type; let the model infer it from
    // item signatures. An explicit unsupported type must never be guessed.
    if ((data.containsKey('file_type') &&
            QuickFileType.fromJson(data['file_type']) == null) ||
        (data['items'] is! List && data['nodes'] is! List)) {
      throw const FormatException('Not a quick configuration JSON file');
    }
    final items = data['items'];
    if (items != null) {
      if (items is! List) throw const FormatException('Invalid quick items');
      for (final item in items) {
        if (item is! Map<String, dynamic> ||
            item['key'] is! String ||
            (item['key'] as String).isEmpty ||
            (item['params'] != null &&
                item['params'] is! Map<String, dynamic>) ||
            (item['enabled'] != null && item['enabled'] is! bool)) {
          throw const FormatException('Invalid quick configuration item');
        }
        for (final key in ['title', 'title_zh', 'title_en']) {
          if (item[key] != null && item[key] is! String) {
            throw const FormatException('Invalid quick item title');
          }
        }
      }
    }
    final nodes = data['nodes'];
    if (nodes != null) {
      if (nodes is! List) throw const FormatException('Invalid quick nodes');
      for (final node in nodes) {
        if (node is! Map<String, dynamic> ||
            node['id'] is! String ||
            (node['id'] as String).isEmpty ||
            !PipelineStepType.values.any((type) => type.name == node['type']) ||
            (node['params'] != null &&
                node['params'] is! Map<String, dynamic>)) {
          throw const FormatException('Invalid quick configuration node');
        }
      }
    }
    try {
      final json = Map<String, dynamic>.from(data);
      if (id != null) json['id'] = id;
      return QuickConfig.fromJson(json);
    } on TypeError {
      throw const FormatException('Invalid quick configuration fields');
    }
  }

  Future<T> _withTemporaryFile<T>(
    Future<T> Function(File file) operation,
  ) async {
    final root = await _temporaryDirectory();
    final directory = await root.createTemp('quick-config-json-');
    try {
      return await operation(
        File('${directory.path}${Platform.pathSeparator}config.fppx'),
      );
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Cleanup must not hide a successful export or the actual codec error.
      }
    }
  }
}
