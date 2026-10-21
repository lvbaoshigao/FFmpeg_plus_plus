import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';

/// Persists AI credentials in the operating system's secure storage.
class AiCredentialStore {
  AiCredentialStore._();

  static const _storage = FlutterSecureStorage();
  static const _keyPrefix = 'ffmpegpp.ai.';
  static const _globalKey = '${_keyPrefix}global';

  static Future<void> restore(AppConfig config) async {
    final globalKey = await _storage.read(key: _globalKey);
    if (globalKey != null) {
      config.aiApiKey = globalKey;
    } else if (config.aiApiKey.isNotEmpty) {
      await _storage.write(key: _globalKey, value: config.aiApiKey);
    }

    for (final profile in config.aiProfiles) {
      final storageKey = _profileKey(profile.id);
      final stored = await _storage.read(key: storageKey);
      if (stored != null) {
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
      } else if (profile.apiKey.isNotEmpty || profile.apiKeys.isNotEmpty) {
        await _writeProfile(profile);
      }
    }
  }

  static Future<void> save(AppConfig config) async {
    final retainedKeys = <String>{};
    if (config.aiApiKey.isNotEmpty) {
      retainedKeys.add(_globalKey);
      await _storage.write(key: _globalKey, value: config.aiApiKey);
    } else {
      await _storage.delete(key: _globalKey);
    }

    for (final profile in config.aiProfiles) {
      final storageKey = _profileKey(profile.id);
      if (profile.apiKey.isEmpty && profile.apiKeys.isEmpty) {
        await _storage.delete(key: storageKey);
        continue;
      }
      retainedKeys.add(storageKey);
      await _writeProfile(profile);
    }

    final existing = await _storage.readAll();
    for (final key in existing.keys) {
      if (key.startsWith(_keyPrefix) && !retainedKeys.contains(key)) {
        await _storage.delete(key: key);
      }
    }
  }

  static String _profileKey(String id) => '${_keyPrefix}profile.$id';

  static Future<void> _writeProfile(AiProfile profile) => _storage.write(
    key: _profileKey(profile.id),
    value: jsonEncode({'api_key': profile.apiKey, 'api_keys': profile.apiKeys}),
  );
}
