import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';

/// Persists AI credentials in the operating system's secure storage.
class AiCredentialStore {
  AiCredentialStore._();

  static const _storage = FlutterSecureStorage();
  static const _keyPrefix = 'ffmpegpp.ai.';
  static const _globalKey = '${_keyPrefix}global';

  static Future<void> restore(AppConfig config) async {
    // 凭据存储可能整体不可用（未装 keyring / 无 DBus 会话），此时不能让异常
    // 冒泡出去：ConfigService.load() 是启动初始化第一步，抛出去会连带阻断
    // 后端启动、任务队列恢复与 MCP。失败即降级为“本次会话没有已存凭据”。
    String? globalKey;
    try {
      globalKey = await _storage.read(key: _globalKey);
    } catch (error) {
      debugPrint('[AiCredentialStore] secure storage unavailable: $error');
    }
    if (globalKey != null) {
      config.aiApiKey = globalKey;
    } else if (config.aiApiKey.isNotEmpty) {
      await _writeSafely(key: _globalKey, value: config.aiApiKey);
    }

    for (final profile in config.aiProfiles) {
      final storageKey = _profileKey(profile.id);
      String? stored;
      try {
        stored = await _storage.read(key: storageKey);
      } catch (error) {
        debugPrint('[AiCredentialStore] read failed for ${profile.id}: $error');
        continue;
      }
      if (stored == null) {
        if (profile.apiKey.isNotEmpty || profile.apiKeys.isNotEmpty) {
          await _writeProfile(profile);
        }
        continue;
      }
      // 单条记录损坏（旧格式、写入中断、字段类型变化）只丢弃该条并继续，
      // 不能让一个坏 profile 拖垮整个启动流程。
      try {
        final data = jsonDecode(stored);
        if (data is! Map<String, dynamic>) {
          throw FormatException(
            'Invalid secure credentials for profile ${profile.id}.',
          );
        }
        profile
          ..apiKey = data['api_key'] as String? ?? ''
          ..apiKeys =
              (data['api_keys'] as List?)?.whereType<String>().toList() ??
              <String>[];
      } catch (error) {
        debugPrint(
          '[AiCredentialStore] dropping corrupt entry for '
          '${profile.id}: $error',
        );
        try {
          await _storage.delete(key: storageKey);
        } catch (_) {}
      }
    }
  }

  /// 写入失败不抛出：调用方在启动路径上，写不进去只损失“记住凭据”，
  /// 不应升级成启动失败。
  static Future<void> _writeSafely({
    required String key,
    required String value,
  }) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (error) {
      debugPrint('[AiCredentialStore] write failed for $key: $error');
    }
  }

  static Future<void> save(AppConfig config) async {
    // 所有存储操作都走不抛异常的封装：配置落盘不能因为 keyring 不可用而
    // 整体失败（否则 ConfigService.save 的写盘链会被一并拖垮）。
    final retainedKeys = <String>{};
    if (config.aiApiKey.isNotEmpty) {
      retainedKeys.add(_globalKey);
      await _writeSafely(key: _globalKey, value: config.aiApiKey);
    } else {
      await _deleteSafely(_globalKey);
    }

    for (final profile in config.aiProfiles) {
      final storageKey = _profileKey(profile.id);
      if (profile.apiKey.isEmpty && profile.apiKeys.isEmpty) {
        await _deleteSafely(storageKey);
        continue;
      }
      retainedKeys.add(storageKey);
      await _writeProfile(profile);
    }

    try {
      final existing = await _storage.readAll();
      for (final key in existing.keys) {
        if (key.startsWith(_keyPrefix) && !retainedKeys.contains(key)) {
          await _deleteSafely(key);
        }
      }
    } catch (error) {
      debugPrint('[AiCredentialStore] cleanup skipped: $error');
    }
  }

  static String _profileKey(String id) => '${_keyPrefix}profile.$id';

  static Future<void> _deleteSafely(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (error) {
      debugPrint('[AiCredentialStore] delete failed for $key: $error');
    }
  }

  static Future<void> _writeProfile(AiProfile profile) => _writeSafely(
    key: _profileKey(profile.id),
    value: jsonEncode({'api_key': profile.apiKey, 'api_keys': profile.apiKeys}),
  );
}
