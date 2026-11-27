import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import 'ai_credential_store.dart';
import 'diagnostic_trace.dart';

final _s = Platform.pathSeparator;

class ConfigService {
  ConfigService({
    AiCredentialStore? credentialStore,
    this._trace,
    Future<Directory> Function()? supportDirectory,
  }) : _credentialStore = credentialStore ?? AiCredentialStore(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final AiCredentialStore _credentialStore;
  final DiagnosticTrace? _trace;
  final Future<Directory> Function() _supportDirectory;

  AppConfig? _pendingMigration;
  bool _settingsLoadFailed = false;

  String? _persistenceError;

  static const _filename = 'settings.json';
  static const _libraryFilename = 'config_library.json';
  static const _taskHistoryFilename = 'task_history.json';

  /// 连续修改（拖动滑块、输入框逐字输入）时的落盘防抖间隔。
  static const _saveDebounce = Duration(milliseconds: 400);

  AppConfig _config = AppConfig();
  AppConfig get config => _config;

  /// Non-null only when the most recent settings persistence attempt failed.
  String? get persistenceError => _persistenceError;

  Timer? _saveTimer;
  Future<void>? _saveInFlight;
  bool _dirty = false;

  /// 每次 [update] 自增，用于判断“本次写盘完成时是否又有新改动”，
  /// 避免旧写盘把新改动误标成已保存。
  int _editGeneration = 0;

  Future<void> load() async {
    var span = _trace?.begin('storage.settings_load');
    var fileExists = false;
    Map<String, dynamic> json = {};
    _settingsLoadFailed = true;
    _pendingMigration = null;
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_filename');
      fileExists = await file.exists();
      if (fileExists) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException(
            'Settings file must contain a JSON object.',
          );
        }
        json = decoded;
      }
      _config = AppConfig.fromJson(json);
      _settingsLoadFailed = false;
      _persistenceError = null;
    } catch (error) {
      _persistenceError =
          'Settings could not be loaded; original file preserved.';
      debugPrint('[ConfigService] $_persistenceError');
      _config = AppConfig();
      span?.finish(
        success: false,
        error: error,
        details: {'reason': 'load_failed', 'responseFields': json.length},
      );
      return;
    }

    // The persisted setting controls diagnostics too. Do not activate it until
    // the settings object has been parsed and accepted.
    if (span != null && !_config.veryVerboseLogs) {
      span.finish(
        success: true,
        details: {
          'reason': fileExists ? 'loaded' : 'missing',
          'responseFields': json.length,
        },
      );
      span = null;
    }
    _trace?.setEnabled(_config.veryVerboseLogs);
    span ??= _trace?.begin('storage.settings_load', details: {
      'reason': fileExists ? 'loaded' : 'missing',
    });

    try {
      if (!json.containsKey('use_dynamic_color') && Platform.isAndroid) {
        _config.useDynamicColor = true;
      }
      final restoreSpan = _trace?.begin(
        'storage.credential_restore',
        details: {'profileCount': _config.aiProfiles.length},
      );
      try {
        await _credentialStore.restore(_config);
        restoreSpan?.finish(success: true);
      } catch (error) {
        restoreSpan?.finish(success: false, error: error);
        rethrow;
      }

      final hasLegacyKeys = _containsLegacyAiKeys(json);
      var migrationFailed = false;
      if (hasLegacyKeys) {
        final migrationSpan = _trace?.begin(
          'storage.settings_migration',
          details: {'reason': 'legacy_keys'},
        );
        // Keep a separate snapshot: later UI edits must not discard a credential
        // whose only persisted copy is still in the legacy settings file.
        _pendingMigration = _snapshot(_config);
        try {
          await save();
          migrationFailed = _persistenceError != null;
          migrationSpan?.finish(
            success: !migrationFailed,
            details: {
              'reason': migrationFailed ? 'migration_failed' : 'migrated',
            },
          );
        } catch (error) {
          migrationSpan?.finish(
            success: false,
            error: error,
            details: {'reason': 'migration_failed'},
          );
          rethrow;
        }
      }
      span?.finish(
        success: !migrationFailed,
        details: {
          'reason': migrationFailed
              ? 'migration_failed'
              : (fileExists ? 'loaded' : 'missing'),
          'responseFields': json.length,
          'migrated': hasLegacyKeys && !migrationFailed,
        },
      );
    } catch (error) {
      span?.finish(success: false, error: error);
      rethrow;
    }
  }

  Future<void> save() async {
    final span = _trace?.begin('storage.settings_save');
    var completed = false;
    var reason = 'saved';
    Object? thrownError;
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = true;
    // 串行化写入，避免两次保存交错写同一个文件产生半截 JSON
    final prev = _saveInFlight;
    final next = () async {
      if (prev != null) {
        // 上一次写盘失败不能让后续所有写盘都失败：这里只记录，继续本次写。
        // （原实现直接 await，一次失败即永久断掉写盘链。）
        try {
          await prev;
        } catch (error, stack) {
          debugPrint('[ConfigService] previous save failed: $error\n$stack');
        }
      }
      // The preceding queued save may have cleared the shared dirty flag.
      _dirty = true;
      if (_settingsLoadFailed) {
        _persistenceError =
            'Settings could not be loaded; original file preserved.';
        debugPrint('[ConfigService] $_persistenceError');
        reason = 'settings_load_failed';
        return;
      }
      final generation = _editGeneration;
      final snapshot = _snapshot(_config);
      final migration = _pendingMigration;
      if (migration != null) {
        if (!await _credentialStore.save(migration, migrationOnly: true)) {
          _persistenceError =
              'Credentials were not saved; settings file preserved.';
          debugPrint('[ConfigService] $_persistenceError');
          reason = 'migration_failed';
          return;
        }
        // Never replay an older credential after its migration succeeded.
        _pendingMigration = null;
      }
      if (!await _credentialStore.save(snapshot)) {
        _persistenceError =
            'Credentials were not saved; settings file preserved.';
        debugPrint('[ConfigService] $_persistenceError');
        reason = 'credential_save_failed';
        return;
      }
      final dir = await _configDir();
      final file = File('$dir$_s$_filename');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
      );
      _persistenceError = null;
      // 只有真正写成功、且期间没有新的修改，才清除脏标记。
      if (generation == _editGeneration) {
        _dirty = false;
      }
    }();
    _saveInFlight = next;
    try {
      await next;
      completed = true;
    } catch (error) {
      thrownError = error;
      reason = 'write_failed';
      rethrow;
    } finally {
      span?.finish(
        success: completed && _persistenceError == null,
        error: thrownError,
        details: {'reason': reason},
      );
      // 按引用清空，避免把后来者的 in-flight 引用抹掉。
      if (identical(_saveInFlight, next)) {
        _saveInFlight = null;
      }
    }
  }

  // Detach nested settings without decoding credentials a second time.
  AppConfig _snapshot(AppConfig source) {
    final copy = AppConfig.fromJson(
      jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
    );
    copy.aiApiKey = source.aiApiKey;
    for (var index = 0; index < source.aiProfiles.length; index++) {
      copy.aiProfiles[index]
        ..apiKey = source.aiProfiles[index].apiKey
        ..apiKeys = List<String>.of(source.aiProfiles[index].apiKeys);
    }
    return copy;
  }

  /// 修改配置。落盘是防抖的：滑块拖动等高频调用只会在停止后写一次磁盘，
  /// 内存中的 [config] 立即生效。需要立刻持久化时调用 [flush]。
  Future<void> update(AppConfig Function(AppConfig) transform) async {
    _config = transform(_config);
    _dirty = true;
    _editGeneration++;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () {
      if (_dirty) save();
    });
  }

  /// 立即写入尚未落盘的修改（退出应用前调用）。
  Future<void> flush() async {
    if (_dirty) {
      await save();
    } else {
      final inFlight = _saveInFlight;
      if (inFlight != null) {
        try {
          await inFlight;
        } catch (_) {}
      }
    }
  }

  void dispose() {
    _saveTimer?.cancel();
    _saveTimer = null;
    // [FIX L-6] 退出时确保最后一次落盘不被取消：若仍有未落盘的修改（防抖尚未
    // 触发的 save），先触发一次 save() 产生写盘 Future；再保留正在进行的写盘
    // Future（不主动取消），并在协程中吞掉异常。dispose 是同步的，无法 await。
    if (_dirty) {
      _saveInFlight = save(); // save() 内部会串行等待前一次写盘
    }
    final inFlight = _saveInFlight;
    if (inFlight != null) {
      unawaited(inFlight.catchError((_) {}));
    }
    _saveInFlight = null;
  }

  // --- Config Library persistence ---

  Future<List<Map<String, dynamic>>> loadLibrary() async {
    final span = _trace?.begin('storage.library_load');
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_libraryFilename');
      if (!await file.exists()) {
        span?.finish(
          success: true,
          details: {'reason': 'missing', 'itemCount': 0, 'skippedCount': 0},
        );
        return [];
      }
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      // 逐个验证条目类型（cast 是懒加载的，坏条目会在首次使用时抛 TypeCastError）；
      // 坏条目只跳过，不能因为一条损坏就把整个配置库丢光。
      final entries = <Map<String, dynamic>>[];
      var skippedCount = 0;
      for (final entry in list) {
        if (entry is Map<String, dynamic>) {
          entries.add(entry);
        } else {
          skippedCount++;
        }
      }
      span?.finish(
        success: true,
        details: {
          'itemCount': entries.length,
          'skippedCount': skippedCount,
          'totalCount': list.length,
        },
      );
      return entries;
    } catch (error) {
      span?.finish(
        success: false,
        error: error,
        details: {'reason': 'read_failed'},
      );
      return [];
    }
  }

  Future<void> saveLibrary(List<Map<String, dynamic>> entries) async {
    final span = _trace?.begin(
      'storage.library_save',
      details: {'itemCount': entries.length},
    );
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_libraryFilename');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(entries),
      );
      span?.finish(success: true, details: {'itemCount': entries.length});
    } catch (error) {
      span?.finish(
        success: false,
        error: error,
        details: {'reason': 'write_failed', 'itemCount': entries.length},
      );
    }
  }

  // --- 处理队列结果持久化 ---
  // 队列（含已完成/失败/等待中的任务结果）落盘到 task_history.json，
  // 下次启动恢复展示；仅结构性变化（增删/状态终态）时写入，进度心跳不落盘。

  Future<List<Map<String, dynamic>>> loadTaskHistory() async {
    final span = _trace?.begin('storage.task_history_load');
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_taskHistoryFilename');
      if (!await file.exists()) {
        span?.finish(
          success: true,
          details: {'reason': 'missing', 'itemCount': 0, 'skippedCount': 0},
        );
        return [];
      }
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      final entries = <Map<String, dynamic>>[];
      var skippedCount = 0;
      for (final entry in list) {
        if (entry is Map<String, dynamic>) {
          entries.add(entry);
        } else {
          skippedCount++;
        }
      }
      span?.finish(
        success: true,
        details: {
          'itemCount': entries.length,
          'skippedCount': skippedCount,
          'totalCount': list.length,
        },
      );
      return entries;
    } catch (error) {
      span?.finish(
        success: false,
        error: error,
        details: {'reason': 'read_failed'},
      );
      return [];
    }
  }

  Future<void> saveTaskHistory(List<Map<String, dynamic>> entries) async {
    final span = _trace?.begin(
      'storage.task_history_save',
      details: {'itemCount': entries.length},
    );
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_taskHistoryFilename');
      // 紧凑 JSON（无缩进）：任务历史可能包含日志行，体积小一点是一点
      await file.writeAsString(jsonEncode(entries));
      span?.finish(success: true, details: {'itemCount': entries.length});
    } catch (error) {
      span?.finish(
        success: false,
        error: error,
        details: {'reason': 'write_failed', 'itemCount': entries.length},
      );
    }
  }

  Future<String> _configDir() async {
    final appDir = await _supportDirectory();
    final dir = Directory('${appDir.path}${_s}ffmpegpp_gui');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  bool _containsLegacyAiKeys(Map<String, dynamic> json) {
    if ((json['ai_api_key'] as String? ?? '').isNotEmpty) return true;
    final profiles = json['ai_profiles'];
    if (profiles is! List) return false;
    return profiles.whereType<Map>().any(
      (profile) =>
          (profile['api_key'] as String? ?? '').isNotEmpty ||
          (profile['api_keys'] as List?)?.isNotEmpty == true,
    );
  }
}
