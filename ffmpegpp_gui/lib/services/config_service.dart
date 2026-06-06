import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';

/// 应用配置持久化服务
/// 读写 settings.json 文件
class ConfigService {
  static const _filename = 'settings.json';

  AppConfig _config = AppConfig();
  AppConfig get config => _config;

  Future<void> load() async {
    try {
      final dir = await _configDir();
      final file = File('$dir/$_filename');
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
      final file = File('$dir/$_filename');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_config.toJson()),
      );
    } catch (_) {}
  }

  Future<void> update(AppConfig Function(AppConfig) transform) async {
    _config = transform(_config);
    await save();
  }

  Future<String> _configDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}/ffmpegpp_gui');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }
}
