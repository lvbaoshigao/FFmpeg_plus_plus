import '../models/models.dart';
import 'backend_client.dart';

/// FPPX 配置文件的统一导入/导出入口。
///
/// 导入路由完全由 C++ 端完成（`fppx_import` action 按文件头判别新旧格式后分发），
/// Dart 不读配置文件的任何字节；导出时 Dart 只传目标路径与图 JSON，
/// 格式编解码、校验、写盘全部在 C++。
class FppxService {
  final BackendClient backend;
  FppxService(this.backend);

  // ── 导入结果 ──

  static const int modeNodeEditor = 0x01;
  static const int modeQuick = 0x02;

  // ── 加密算法族（与 C++ fppx2_format.h 的 FPPX2_ALGO_* 一一对应）──
  static const int algoAes128Cbc = 0x01; // AES-128-CBC + PKCS#7 + HMAC-SHA256
  static const int algoAes256Cbc = 0x02; // AES-256-CBC + PKCS#7 + HMAC-SHA256（默认）

  /// 旧版格式结构上没有任何位置放加密字段，故永远不支持加密。
  static bool supportsEncryption({required bool newFormat}) => newFormat;

  /// 导入 .fppx（新旧格式由 C++ 自动路由）。
  ///
  /// 当 [FppxImportResult.unknownTypeIds] 非空且 [FppxImportResult.graph] 为 null 时，
  /// 表示存在未知节点类型 ID 且用户尚未确认强制导入——GUI 应弹确认框后带
  /// force=true 重新调用。
  /// [password] 仅在文件已加密时需要。首次调用不传口令时，C++ 端若检测到
  /// 文件已加密会返回 [FppxImportResult.needPassword]=true（不是错误），
  /// GUI 据此弹出「输入口令」框，用户提交后带 [password] 重新调用本方法。
  /// 口令错误时 success=false 且 error 为统一文案，可保持对话框打开重试。
  Future<FppxImportResult> importFile(String path,
      {bool force = false, String password = ''}) async {
    final resp =
        await backend.fppxImport(path, force: force, password: password);

    final respData = resp['data'] as Map<String, dynamic>?;

    // 需要口令：不是错误，交由 GUI 弹框（规范 §6.9）
    if (resp['success'] != true && respData?['need_password'] == true) {
      return FppxImportResult(
        success: false,
        needPassword: true,
        encrypted: true,
        errors: _strList(respData?['errors']),
        warnings: _strList(respData?['warnings']),
      );
    }

    if (resp['success'] != true) {
      final dataErrors = _strList(respData?['errors']);
      return FppxImportResult(
        success: false,
        error: (resp['error'] as String?) ?? dataErrors.firstOrNull ?? '导入失败',
        errors: dataErrors,
        warnings: _strList(respData?['warnings']),
      );
    }

    final data = (resp['data'] as Map<String, dynamic>?) ?? const {};
    final graphJson = data['graph'];
    PipelineGraph? graph;
    if (graphJson is Map<String, dynamic>) {
      try {
        graph = PipelineGraph.fromJson(graphJson);
      } catch (_) {
        return const FppxImportResult(
          success: false,
          error: '节点图数据解析失败',
        );
      }
    }
    final quickItems = (data['quick_items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const <Map<String, dynamic>>[];

    return FppxImportResult(
      success: true,
      isNewFormat: data['is_new_format'] == true,
      mode: (data['mode'] as num?)?.toInt() ?? 0,
      description: (data['description'] as String?) ?? '',
      encrypted: data['encrypted'] == true,
      graph: graph,
      quickItems: quickItems,
      errors: _strList(data['errors']),
      warnings: _strList(data['warnings']),
      unknownTypeIds: _strList(data['unknown_type_ids']),
      forced: data['forced'] == true,
    );
  }

  // ── 导出 ──

  /// 导出节点图为 .fppx。[newFormat]=true 走新版 v2 二进制，false 走旧版。
  /// C++ 端写盘前完整校验（张冠李戴/连线/环/媒体类型等），失败不落盘。
  ///
  /// [encrypted] 仅对 [newFormat]=true 有效；旧版会直接拒收（结构上无位置放）。
  /// 加密范围只有数据区（模块 0x03），介绍文本与各类元数据保持明文。
  Future<FppxExportResult> exportGraph(
    PipelineGraph graph,
    String path, {
    required String description,
    required bool newFormat,
    bool encrypted = false,
    String password = '',
    int encryptAlgo = algoAes256Cbc,
  }) async {
    final graphJson = graph.toJson();
    final resp = newFormat
        ? await backend.fppx2Export(path,
            mode: modeNodeEditor,
            description: description,
            graph: graphJson,
            encrypted: encrypted,
            password: password,
            encryptAlgo: encryptAlgo)
        : await backend.fppxLegacyExport(path, graph: graphJson, description: description);

    return _toExportResult(resp);
  }

  /// 导出快速模式参数项为新版 .fppx（0x02，逻辑块无节点 ID，只存命令参数）。
  Future<FppxExportResult> exportQuickItems(
    String path, {
    required String description,
    required List<Map<String, dynamic>> items,
    bool encrypted = false,
    String password = '',
    int encryptAlgo = algoAes256Cbc,
  }) async {
    final resp = await backend.fppx2Export(path,
        mode: modeQuick,
        description: description,
        quickItems: items,
        encrypted: encrypted,
        password: password,
        encryptAlgo: encryptAlgo);
    return _toExportResult(resp);
  }

  FppxExportResult _toExportResult(Map<String, dynamic> resp) {
    final data = (resp['data'] as Map<String, dynamic>?) ?? const {};
    return FppxExportResult(
      success: resp['success'] == true,
      error: (resp['error'] as String?) ?? _strList(data['errors']).firstOrNull,
      errors: _strList(data['errors']),
      warnings: _strList(data['warnings']),
    );
  }

  static List<String> _strList(dynamic v) =>
      (v as List?)?.whereType<String>().toList() ?? const <String>[];
}

/// [FppxService.importFile] 的返回。
class FppxImportResult {
  final bool success;
  final String? error;
  /// C++ 端检测到文件已加密且本次未提供口令：GUI 应弹口令框后带口令重调，
  /// 这不是错误（[error] 为空、[errors] 为空）。
  final bool needPassword;
  final bool isNewFormat;
  final int mode;
  final String description;
  final bool encrypted;
  final PipelineGraph? graph;
  final List<Map<String, dynamic>> quickItems;
  final List<String> errors;
  final List<String> warnings;
  final List<String> unknownTypeIds;
  final bool forced;

  const FppxImportResult({
    required this.success,
    this.error,
    this.needPassword = false,
    this.isNewFormat = false,
    this.mode = 0,
    this.description = '',
    this.encrypted = false,
    this.graph,
    this.quickItems = const [],
    this.errors = const [],
    this.warnings = const [],
    this.unknownTypeIds = const [],
    this.forced = false,
  });

  /// 是否需要弹"强制导入"确认框（存在未知节点类型且尚未确认）。
  bool get needsForceConfirm => success && graph == null && unknownTypeIds.isNotEmpty;

  /// 是否需要弹「输入口令」框（文件已加密，尚未提供口令）。
  bool get needsPassword => !success && needPassword;
}

/// [FppxService.exportGraph] / [FppxService.exportQuickItems] 的返回。
class FppxExportResult {
  final bool success;
  final String? error;
  final List<String> errors;
  final List<String> warnings;

  const FppxExportResult({
    required this.success,
    this.error,
    this.errors = const [],
    this.warnings = const [],
  });
}
