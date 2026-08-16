import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// AI 聊天历史记录持久化服务。
///
/// 每条会话记录包含：标题（首条用户消息截断）、时间戳、供应商/模型快照、
/// 完整消息列表（含 token 统计）。存到用户数据目录 ai_history/ 下，按时间命名。
class AiChatHistory {
  AiChatHistory._();

  static final String _sep = Platform.pathSeparator;

  static Future<String> _historyDir() async {
    final base = await _baseDir();
    return '$base${_sep}ai_history';
  }

  /// 用户数据目录。Android 无 HOME/APPDATA：用应用支持目录（持久、无需权限），
  /// 否则 AI 历史在 Android 上会落到不可写的 /tmp 而静默保存失败。
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

  /// 确保历史目录存在。
  static Future<void> _ensureDir() async {
    final dir = Directory(await _historyDir());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 保存一次会话。返回保存的文件路径，失败返回 null。
  static Future<String?> saveSession({
    required String title,
    required String provider,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    try {
      await _ensureDir();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final dir = await _historyDir();
      final file = File('$dir${_sep}session_$ts.json');
      final data = {
        'title': title,
        'provider': provider,
        'model': model,
        'saved_at': DateTime.now().toIso8601String(),
        'messages': messages,
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 列出全部历史会话（按保存时间倒序）。
  static Future<List<Map<String, dynamic>>> listSessions() async {
    try {
      final dir = Directory(await _historyDir());
      if (!await dir.exists()) return [];
      // 异步遍历，避免历史目录较大时阻塞 UI
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.json')) files.add(e);
      }
      files.sort((a, b) => b.path.compareTo(a.path));
      final result = <Map<String, dynamic>>[];
      for (final f in files) {
        try {
          final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          json['_file'] = f.path;
          result.add(json);
        } catch (_) {}
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  /// 删除一条历史会话。
  static Future<void> deleteSession(String filePath) async {
    try {
      final f = File(filePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 清空全部历史会话。
  static Future<void> clearAll() async {
    try {
      final dir = Directory(await _historyDir());
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is File) {
          try { await e.delete(); } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
