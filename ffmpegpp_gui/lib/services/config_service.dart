import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';

final _s = Platform.pathSeparator;

class ConfigService {
  static const _filename = 'settings.json';
  static const _libraryFilename = 'config_library.json';

  AppConfig _config = AppConfig();
  AppConfig get config => _config;

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
    try {
      final dir = await _configDir();
      final file = File('$dir$_s$_filename');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_config.toJson()),
      );
    } catch (_) {}
  }

  Future<void> update(AppConfig Function(AppConfig) transform) async {
    _config = transform(_config);
    await save();
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
