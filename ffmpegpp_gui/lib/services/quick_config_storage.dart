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
  static Future<void> _pending = Future<void>.value();

  // Test seams: tests must restore these after awaiting all operations.
  static Directory? directoryOverride;
  static Future<void> Function(File file, String contents)? writeOverride;

  static Future<void> _serialize(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

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
    final dir = directoryOverride ??
        Directory('${await _baseDir()}$_sep' 'quick_configs');
    await dir.create(recursive: true);
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
          // [FIX L-8] 以文件名为权威 id 来源：文件名去掉扩展名即 id。
          // 文件内容里的 id 若被篡改，统一以文件名为准，避免 save 写到别的文件
          // 产生孤儿文件 + 列表重复项；保证「加载 → 再保存」写回同一文件。
          final name = entity.path.split(_sep).last;
          final fileNameId = name.substring(0, name.length - '.fppq.json'.length);
          if (json['id'] != fileNameId) {
            // 内容 id 与文件名不一致：以文件名为准（调试期可观察该告警）。
            json['id'] = fileNameId;
          }
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

  /// 保存调用时的快照。写入或替换失败会向调用方抛出，旧文件不预先删除。
  static Future<void> save(QuickConfig cfg) async {
    final id = cfg.id;
    final contents = const JsonEncoder.withIndent('  ').convert(cfg.toJson());
    await _serialize(() async {
      final target = await _fileFor(id);
      final staging = await target.parent.createTemp('.quick-config-');
      final temporary = File('${staging.path}${_sep}config.tmp');
      try {
        final writer = writeOverride;
        if (writer != null) {
          await writer(temporary, contents);
        } else {
          await temporary.writeAsString(contents, flush: true);
        }
        // Never replace the destination with a truncated or altered write.
        if (await temporary.readAsString() != contents) {
          throw const FileSystemException('Incomplete quick configuration write');
        }
        await temporary.rename(target.path);
      } finally {
        // Cleanup must not turn a committed save into a reported failure.
        try { await staging.delete(recursive: true); } catch (_) {}
      }
    });
  }

  /// 删除与保存使用同一队列；失败向调用方抛出。
  static Future<void> delete(String id) => _serialize(() async {
    final file = await _fileFor(id);
    if (await file.exists()) await file.delete();
  });
}
