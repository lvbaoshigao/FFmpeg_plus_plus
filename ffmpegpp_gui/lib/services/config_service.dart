import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';

final _s = Platform.pathSeparator;

class ConfigService {
  static const _filename = 'settings.json';
  static const _libraryFilename = 'config_library.json';

  /// 连续修改（拖动滑块、输入框逐字输入）时的落盘防抖间隔。
  static const _saveDebounce = Duration(milliseconds: 400);

  AppConfig _config = AppConfig();
  AppConfig get config => _config;

  Timer? _saveTimer;
  Future<void>? _saveInFlight;
  bool _dirty = false;

  Future<void> load() async {
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_filename');
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _config = AppConfig.fromJson(json);
      }
    } catch (_) {
      _config = AppConfig();
    }
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = false;
    // 串行化写入，避免两次保存交错写同一个文件产生半截 JSON
    final prev = _saveInFlight;
    final next = () async {
      if (prev != null) {
        try { await prev; } catch (_) {}
      }
      try {
        final dir = await _configDir();
        final file = File('$dir$_s$_filename');
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(_config.toJson()),
        );
      } catch (_) {}
    }();
    _saveInFlight = next;
    return next;
  }

  /// 修改配置。落盘是防抖的：滑块拖动等高频调用只会在停止后写一次磁盘，
  /// 内存中的 [config] 立即生效。需要立刻持久化时调用 [flush]。
  Future<void> update(AppConfig Function(AppConfig) transform) async {
    _config = transform(_config);
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () { if (_dirty) save(); });
  }

  /// 立即写入尚未落盘的修改（退出应用前调用）。
  Future<void> flush() async {
    if (_dirty) {
      await save();
    } else {
      final inFlight = _saveInFlight;
      if (inFlight != null) {
        try { await inFlight; } catch (_) {}
      }
    }
  }

  void dispose() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  // --- Config Library persistence ---

  Future<List<Map<String, dynamic>>> loadLibrary() async {
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_libraryFilename');
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        return list.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }

  Future<void> saveLibrary(List<Map<String, dynamic>> entries) async {
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_libraryFilename');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(entries));
    } catch (_) {}
  }

  Future<String> _configDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}${_s}ffmpegpp_gui');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }
}
