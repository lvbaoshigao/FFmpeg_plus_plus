import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/quick_config.dart';

/// 快捷配置 (Quick Config) 的本地存储服务。
///
/// 目录策略与 [PipelineAutosave] 保持一致：Android 用应用支持目录（持久、无需权限），
/// 桌面端用用户数据目录。每份配置单独存为一个 JSON 文件：
///   `<dir>/quick_configs/<id>.fppq.json`
class QuickConfigStorage {
  QuickConfigStorage._();

  static final String _sep = Platform.pathSeparator;

  /// 用户数据目录（与 pipeline_autosave.dart 的 _baseDir 一致）。
  static Future<String> _baseDir() async {
    if (Platform.isAndroid) {
      final dir = await getApplicationSupportDirectory();
      return dir.path;
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    if (Platform.isWindows) {
      return '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
          '$_sep' 'FFmpeg++';
    }
    if (Platform.isMacOS) {
      return '$home$_sep' 'Library$_sep' 'Application Support$_sep' 'FFmpeg++';
    }
    final base = Platform.environment['XDG_DATA_HOME'] ?? '$home$_sep'
        '.local$_sep' 'share';
    return '$base$_sep' 'FFmpeg++';
  }

  static Future<Directory> _configsDir() async {
    final dir = Directory('${await _baseDir()}$_sep' 'quick_configs');
    if (!await dir.exists()) {
      try { await dir.create(recursive: true); } catch (_) {}
    }
    return dir;
  }

  static Future<File> _fileFor(String id) async {
    // id 可能含路径分隔符等字符，统一转成安全的文件名
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${(await _configsDir()).path}$_sep$safe.fppq.json');
  }

  /// 读取全部快捷配置；可选按文件类型过滤。解析失败的文件会被跳过。
  static Future<List<QuickConfig>> loadAll(QuickFileType? type) async {
    final result = <QuickConfig>[];
    try {
      final dir = await _configsDir();
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.fppq.json')) continue;
        try {
          final json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          final cfg = QuickConfig.fromJson(json);
          if (type == null || cfg.fileType == type) result.add(cfg);
        } catch (_) {}
      }
    } catch (_) {}
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  /// 读取单个配置；不存在或解析失败返回 null。
  static Future<QuickConfig?> load(String id) async {
    try {
      final f = await _fileFor(id);
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return QuickConfig.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// 保存一份配置（覆盖同名文件）。
  static Future<void> save(QuickConfig cfg) async {
    try {
      final f = await _fileFor(cfg.id);
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(cfg.toJson()));
    } catch (_) {}
  }

  /// 删除指定配置。
  static Future<void> delete(String id) async {
    try {
      final f = await _fileFor(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
