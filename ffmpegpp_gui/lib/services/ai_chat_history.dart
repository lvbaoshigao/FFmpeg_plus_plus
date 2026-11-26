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
          '$_sep'
          'FFmpeg++';
    }
    if (Platform.isMacOS) {
      return '$home$_sep'
          'Library$_sep'
          'Application Support$_sep'
          'FFmpeg++';
    }
    final base =
        Platform.environment['XDG_DATA_HOME'] ??
        '$home$_sep'
            '.local$_sep'
            'share';
    return '$base$_sep'
        'FFmpeg++';
  }

  /// 确保历史目录存在。
  static Future<void> _ensureDir() async {
    final dir = Directory(await _historyDir());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 保存一次会话。返回保存的文件路径，失败返回 null。
  ///
  /// 原子写（不再直接覆盖目标文件）：先序列化到内存，再写同目录的
  /// `<目标>.tmp`，写完 flush 后用 rename 替换目标。
  /// - 进程在写入中途被杀：旧会话文件保持完整，最多留下一个 .tmp；
  ///   listSessions 只认 .json（.tmp / .bak 不匹配），不会去解析半截内容。
  /// - 序列化失败（循环引用等）：连 .tmp 都不会创建，旧文件不受影响。
  /// - 失败（含 rename 失败）仍返回 null，且 finally 会清掉残留 .tmp。
  static Future<String?> saveSession({
    required String title,
    required String provider,
    required String model,
    required List<Map<String, dynamic>> messages,
    String? filePath,
    // 会话级累计用量。消息里只存「最后一段流式回复」的用量，多轮工具调用 /
    // 续写轮的消耗在重载后会丢；把累计值一起存下来，重开会话统计才和关掉前
    // 一致（旧文件没有这两个字段时读取侧回退为按消息求和）。
    int? totalInputTokens,
    int? totalOutputTokens,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    File? tmp;
    try {
      await _ensureDir();
      final dir = await _historyDir();
      final file = filePath != null && filePath.isNotEmpty
          ? File(filePath)
          : File('$dir${_sep}session_$ts.json');
      final data = {
        'title': title,
        'provider': provider,
        'model': model,
        'saved_at': DateTime.now().toIso8601String(),
        'total_in': ?totalInputTokens,
        'total_out': ?totalOutputTokens,
        'messages': messages,
      };
      final text = const JsonEncoder.withIndent('  ').convert(data);
      tmp = File('${file.path}.tmp');
      // flush: true 让内容真正落到磁盘再 rename，避免「rename 成功但数据还在页面缓存」
      await tmp.writeAsString(text, flush: true);
      await _replaceAtomically(tmp: tmp, target: file);
      // rename 已消费 tmp（路径不存在了），置空避免 finally 再去删
      tmp = null;
      return file.path;
    } catch (_) {
      return null;
    } finally {
      // 任何失败路径都不留 .tmp 垃圾
      if (tmp != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    }
  }

  /// 用 [tmp] 原子替换 [target]。
  ///
  /// POSIX（Linux / macOS / Android）：rename 覆盖已存在文件是原子操作，
  /// 读者要么读到旧文件、要么读到新文件，不存在「半截 JSON」的中间态。
  ///
  /// Windows：`File.rename` 在目标已存在时抛 FileSystemException
  /// （底层 RenameFile/MoveFile 不覆盖），因此退化为三步：
  ///   1) 旧文件改名为 `<目标>.bak`（为 rename 让路）
  ///   2) `.tmp` rename 到目标（仍是 rename，原子）
  ///   3) 删除 `.bak`
  /// 第 2 步失败时把 `.bak` 改回原名，旧会话不丢；第 3 步失败只会留下
  /// 一个 .bak，listSessions 只认 .json，不会把它当成会话。
  /// 代价：Windows 上 1↔2 之间有一个极短的「目标不存在」窗口，
  /// 但旧内容始终在 .bak 里，不会像原来那样被截断成半截文件。
  static Future<void> _replaceAtomically({
    required File tmp,
    required File target,
  }) async {
    if (!Platform.isWindows) {
      await tmp.rename(target.path);
      return;
    }
    final bak = File('${target.path}.bak');
    var movedOldAside = false;
    try {
      if (await target.exists()) {
        if (await bak.exists()) {
          try {
            await bak.delete();
          } catch (_) {}
        }
        await target.rename(bak.path);
        movedOldAside = true;
      }
      await tmp.rename(target.path);
    } catch (_) {
      // 回滚：新文件没 rename 成功，把旧文件改回原名
      if (movedOldAside && !await target.exists()) {
        try {
          await bak.rename(target.path);
        } catch (_) {}
      }
      rethrow;
    }
    if (movedOldAside) {
      try {
        await bak.delete();
      } catch (_) {}
    }
  }

  /// 列出轻量会话摘要（按文件名中的保存时间倒序），不保留 messages。
  /// 旧历史无需迁移：逐块扫描顶层元数据，跳过消息正文，避免整文件解码峰值。
  static Future<List<Map<String, dynamic>>> listSessions({
    Directory? directory,
    bool Function()? isCancelled,
  }) async {
    try {
      final dir = directory ?? Directory(await _historyDir());
      if (!await dir.exists()) return [];
      // 异步遍历，避免历史目录较大时阻塞 UI
      final files = <File>[];
      await for (final e in dir.list()) {
        if (isCancelled?.call() ?? false) return [];
        if (e is File && e.path.endsWith('.json')) files.add(e);
      }
      files.sort((a, b) => b.path.compareTo(a.path));
      final result = <Map<String, dynamic>>[];
      for (final f in files) {
        if (isCancelled?.call() ?? false) return [];
        try {
          final parser = _SessionSummaryParser();
          await for (final chunk in f.openRead().transform(utf8.decoder)) {
            if (isCancelled?.call() ?? false) return [];
            parser.add(chunk);
          }
          final summary = parser.finish();
          summary['_file'] = f.path;
          result.add(summary);
        } catch (_) {}
      }
      return (isCancelled?.call() ?? false) ? [] : result;
    } catch (_) {
      return [];
    }
  }

  /// 仅在选择 / 重命名时读取完整会话；列表摘要不能用于回写 messages。
  static Future<Map<String, dynamic>?> loadSession(String filePath) async {
    try {
      final data =
          jsonDecode(await File(filePath).readAsString())
              as Map<String, dynamic>;
      data['_file'] = filePath;
      return data;
    } catch (_) {
      return null;
    }
  }

  /// 删除一条历史会话。
  static Future<void> deleteSession(String filePath) async {
    try {
      // 路径遍历防护：仅允许删除历史目录内的文件
      final base = Directory(await _historyDir());
      final f = File(filePath);
      if (!f.path.startsWith(base.path)) return;
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
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}

/// Projects top-level scalar metadata without buffering nested message values.
/// String/escape and container state survive chunk boundaries, including old
/// files whose messages precede the title/model. Only the projection is decoded.
class _SessionSummaryParser {
  // Bound damaged/hand-edited keys and metadata independently of body size.
  static const _maxFieldChars = 8 * 1024;
  static const _keys = {
    'title', 'provider', 'model', 'saved_at', 'total_in', 'total_out',
  };
  final _summary = <String, dynamic>{};
  final _containers = <int>[];
  final _field = StringBuffer();
  bool _started = false;
  bool _complete = false;
  bool _inString = false;
  bool _escaped = false;
  bool _readingKey = true;
  bool _keepValue = false;
  bool _hasValue = false;
  bool _afterComma = false;

  static bool _isSpace(int c) => c == 32 || c == 9 || c == 10 || c == 13;

  void add(String chunk) {
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk.codeUnitAt(i);
      if (!_started) {
        if (_isSpace(c)) continue;
        if (c != 123) throw const FormatException('Expected history object');
        _started = true;
        _containers.add(125);
        continue;
      }
      if (_complete) {
        if (!_isSpace(c)) throw const FormatException('Trailing history data');
        continue;
      }
      if (!_inString && _containers.length == 1) {
        if (c == 44 || c == 125) {
          _finishField(allowEmpty: c == 125 && !_afterComma);
          if (c == 125) {
            _containers.removeLast();
            _complete = true;
          } else {
            _afterComma = true;
          }
          continue;
        }
        if (c == 58 && _readingKey) {
          final key = jsonDecode(_field.toString());
          if (key is! String) throw const FormatException('Invalid history key');
          _readingKey = false;
          _keepValue = _keys.contains(key);
          if (_keepValue) {
            _field.writeCharCode(c);
          } else {
            _field.clear();
          }
          continue;
        }
        // Metadata is scalar. Do not accidentally retain an unexpected large
        // object/array under a known metadata key either.
        if (!_readingKey && (c == 123 || c == 91)) {
          _keepValue = false;
          _field.clear();
        }
      }
      if (!_readingKey && !_isSpace(c)) _hasValue = true;
      if (_readingKey || _keepValue) {
        if (_field.length >= _maxFieldChars) {
          throw const FormatException('History metadata exceeds limit');
        }
        _field.writeCharCode(c);
      }
      if (_inString) {
        if (_escaped) {
          _escaped = false;
        } else if (c == 92) {
          _escaped = true;
        } else if (c == 34) {
          _inString = false;
        }
      } else if (c == 34) {
        _inString = true;
      } else if (c == 123 || c == 91) {
        _containers.add(c == 123 ? 125 : 93);
      } else if (c == 125 || c == 93) {
        if (_containers.isEmpty || _containers.removeLast() != c) {
          throw const FormatException('Mismatched history container');
        }
      }
    }
  }

  void _finishField({required bool allowEmpty}) {
    if (_readingKey) {
      if (!allowEmpty || _field.toString().trim().isNotEmpty) {
        throw const FormatException('Incomplete history field');
      }
    } else {
      if (!_hasValue) throw const FormatException('Missing history value');
      if (_keepValue) {
        final value = jsonDecode('{${_field.toString()}}')
            as Map<String, dynamic>;
        for (final entry in value.entries) {
          final numeric = entry.key == 'total_in' || entry.key == 'total_out';
          if (numeric ? entry.value is num : entry.value is String) {
            _summary[entry.key] = entry.value;
          }
        }
      }
    }
    _field.clear();
    _readingKey = true;
    _keepValue = false;
    _hasValue = false;
  }

  Map<String, dynamic> finish() {
    if (!_complete) throw const FormatException('Incomplete history object');
    return _summary;
  }
}
