import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// 图编辑器的自动保存草稿服务。
///
/// 在用户编辑 pipeline 时防抖地把图 JSON 存到本地草稿文件（按容器/视频 key 命名），
/// 应用崩溃或被误关后，下次打开对应编辑器时可检测到草稿并恢复。成功保存（onSave）
/// 后会清除草稿。草稿不会覆盖正式版本，仅作为恢复兜底。
class PipelineAutosave {
  PipelineAutosave._();

  static final String _sep = Platform.pathSeparator;

  static Future<String> _autosaveDir() async {
    final base = await _baseDir();
    return '$base${_sep}pipeline_autosave';
  }

  /// 用户数据目录。Android 无 HOME/APPDATA：用应用支持目录（持久、无需权限），
  /// 否则草稿在 Android 上会落到不可写的 /tmp 而静默保存失败。
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

  static Future<File> _draftFile(String key) async {
    final dir = Directory(await _autosaveDir());
    if (!await dir.exists()) {
      try { await dir.create(recursive: true); } catch (_) {}
    }
    // key 可能含路径分隔符等字符，统一转成安全的文件名
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${dir.path}${_sep}draft_$safe.json');
  }

  /// 保存一份草稿。任何异常都静默吞掉（草稿只是兜底，失败不应打扰编辑）。
  static Future<void> save(String key, Map<String, dynamic> graphJson) async {
    try {
      final f = await _draftFile(key);
      final data = {
        'key': key,
        'saved_at': DateTime.now().toIso8601String(),
        'graph': graphJson,
      };
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    } catch (_) {}
  }

  /// 读取草稿。不存在返回 null，解析失败返回 null。
  static Future<Map<String, dynamic>?> load(String key) async {
    try {
      final f = await _draftFile(key);
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (json['graph'] as Map<String, dynamic>?);
    } catch (_) {
      return null;
    }
  }

  /// 判断是否存在草稿（比"有无文件"更精确：存在且可正常解析才算有草稿）。
  static Future<bool> hasDraft(String key) async => (await load(key)) != null;

  /// 清除（成功保存后调用）草稿。
  static Future<void> clear(String key) async {
    try {
      final f = await _draftFile(key);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
