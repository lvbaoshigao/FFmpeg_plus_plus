import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../models/models.dart';

const _magic = [0x46, 0x50, 0x50, 0x58]; // "FPPX"
const _configMajor = 1;
const _configMinor = 0;
const _minSoftwareMajor = 3;
const _compatMajorCount = 1;
const _currentSoftwareMajor = 3;

const modeNodeEditor = 0x01;
const modeLegacy = 0x02;

class FppxFile {
  final int configMajor, configMinor;
  final int minSoftwareMajor, compatMajorCount;
  final int mode;
  final String description;
  final PipelineGraph? graph;
  final Map<String, dynamic>? legacyConfig;
  final List<String> errors;

  FppxFile({
    required this.configMajor, required this.configMinor,
    required this.minSoftwareMajor, required this.compatMajorCount,
    required this.mode, required this.description,
    this.graph, this.legacyConfig, this.errors = const [],
  });

  String get configVersionStr => 'v$configMajor.$configMinor';
  String get softwareRangeStr => 'v$minSoftwareMajor.x ~ v${minSoftwareMajor + compatMajorCount}.x';
  bool get isNodeEditor => mode == modeNodeEditor;

  bool get isCompatible {
    return _currentSoftwareMajor >= minSoftwareMajor &&
        _currentSoftwareMajor <= minSoftwareMajor + compatMajorCount &&
        errors.isEmpty;
  }
}

class FppxExporter {
  static Uint8List exportGraph(PipelineGraph graph, String description) {
    final jsonStr = jsonEncode(graph.toJson());
    final compressed = gzip.encode(utf8.encode(jsonStr));
    return _buildFile(modeNodeEditor, description, Uint8List.fromList(compressed));
  }

  static Uint8List exportLegacy(TranscodeConfig config, String description) {
    final jsonStr = jsonEncode(config.toBackendOptions());
    final compressed = gzip.encode(utf8.encode(jsonStr));
    return _buildFile(modeLegacy, description, Uint8List.fromList(compressed));
  }

  static Uint8List _buildFile(int mode, String description, Uint8List data) {
    final descBytes = utf8.encode(description);
    final descLen = descBytes.length;
    final dataLen = data.length;
    final totalLen = 8 + 1 + 2 + descLen + 4 + dataLen;

    final buf = ByteData(totalLen);
    var offset = 0;

    // Magic (4B)
    for (final b in _magic) { buf.setUint8(offset++, b); }
    // Config version (2B)
    buf.setUint8(offset++, _configMajor);
    buf.setUint8(offset++, _configMinor);
    // Software compat (2B)
    buf.setUint8(offset++, _minSoftwareMajor);
    buf.setUint8(offset++, _compatMajorCount);
    // Mode (1B)
    buf.setUint8(offset++, mode);
    // Description length (2B big-endian)
    buf.setUint16(offset, descLen, Endian.big); offset += 2;
    // Description (N bytes)
    final bytes = buf.buffer.asUint8List();
    bytes.setRange(offset, offset + descLen, descBytes); offset += descLen;
    // Data length (4B big-endian)
    buf.setUint32(offset, dataLen, Endian.big); offset += 4;
    // Data (M bytes)
    bytes.setRange(offset, offset + dataLen, data);

    return bytes;
  }

  static FppxFile? import(Uint8List bytes) {
    if (bytes.length < 11) return null;
    final buf = ByteData.sublistView(bytes);

    // Verify magic
    for (var i = 0; i < 4; i++) {
      if (buf.getUint8(i) != _magic[i]) return null;
    }

    final configMajor = buf.getUint8(4);
    final configMinor = buf.getUint8(5);
    final minSw = buf.getUint8(6);
    final compatCount = buf.getUint8(7);
    final mode = buf.getUint8(8);
    final descLen = buf.getUint16(9, Endian.big);

    if (bytes.length < 11 + descLen + 4) return null;

    final description = utf8.decode(bytes.sublist(11, 11 + descLen));
    final dataLenOffset = 11 + descLen;
    final dataLen = buf.getUint32(dataLenOffset, Endian.big);

    if (bytes.length < dataLenOffset + 4 + dataLen) return null;

    final compressedData = bytes.sublist(dataLenOffset + 4, dataLenOffset + 4 + dataLen);

    try {
      final jsonStr = utf8.decode(gzip.decode(compressedData));
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      PipelineGraph? graph;
      Map<String, dynamic>? legacyConfig;
      final errors = <String>[];

      final versionOk = _currentSoftwareMajor >= minSw &&
          _currentSoftwareMajor <= minSw + compatCount;
      if (!versionOk) {
        errors.add('软件版本不兼容: 配置要求 v$minSw.x~v${minSw + compatCount}.x，当前 v$_currentSoftwareMajor.0');
      }

      if (mode == modeNodeEditor) {
        final knownTypes = PipelineStepType.values.map((t) => t.name).toSet();
        final nodeList = json['nodes'] as List? ?? [];
        for (final n in nodeList) {
          final typeName = (n as Map<String, dynamic>)['type'] as String? ?? '';
          if (!knownTypes.contains(typeName)) {
            errors.add('不支持的节点类型: "$typeName"（可能来自更高版本的软件）');
          }
        }
        if (errors.isEmpty) {
          graph = PipelineGraph.fromJson(json);
        }
      } else {
        legacyConfig = json;
      }

      return FppxFile(
        configMajor: configMajor, configMinor: configMinor,
        minSoftwareMajor: minSw, compatMajorCount: compatCount,
        mode: mode, description: description,
        graph: graph, legacyConfig: legacyConfig,
        errors: errors,
      );
    } catch (_) {
      return null;
    }
  }
}
