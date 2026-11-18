import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';

/// Persists only credentials whose previous state is known to this session.
class AiCredentialStore {
  AiCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _keyPrefix = 'ffmpegpp.ai.';
  static const _globalKey = '${_keyPrefix}global';
  final Set<String> _knownKeys = {};
  final Set<String> _unrestoredKeys = {};

  /// Restores credentials without treating unavailable records as empty ones.
  Future<void> restore(AppConfig config) async {
    _knownKeys.clear();
    _unrestoredKeys.clear();
    try {
      final value = await _storage.read(key: _globalKey);
      if (value != null) {
        config.aiApiKey = value;
      }
      _knownKeys.add(_globalKey);
    } catch (_) {
      _unrestoredKeys.add(_globalKey);
      debugPrint(
        '[AiCredentialStore] Global credentials could not be restored.',
      );
    }

    for (final profile in config.aiProfiles) {
      final key = _profileKey(profile.id);
      try {
        final stored = await _storage.read(key: key);
        if (stored != null) {
          final data = jsonDecode(stored);
          if (data is! Map<String, dynamic> ||
              (data['api_key'] != null && data['api_key'] is! String) ||
              (data['api_keys'] != null &&
                  (data['api_keys'] is! List ||
                      (data['api_keys'] as List).any((v) => v is! String)))) {
            throw const FormatException('Invalid credential record.');
          }
          // Validate the whole record before changing either in-memory field.
          final apiKey = data['api_key'] as String? ?? '';
          final apiKeys =
              (data['api_keys'] as List?)?.cast<String>().toList() ??
              <String>[];
          profile
            ..apiKey = apiKey
            ..apiKeys = apiKeys;
        }
        _knownKeys.add(key);
      } catch (_) {
        _unrestoredKeys.add(key);
        debugPrint('[AiCredentialStore] Profile credentials not restored.');
      }
    }
  }

  /// Returns false if any requested credential change could not be persisted.
  ///
  /// Unknown records are never overwritten or swept by a settings save.
  /// Migration writes nonempty values only and never deletes other records.
  Future<bool> save(AppConfig config, {bool migrationOnly = false}) async {
    var succeeded = true;
    final currentKeys = <String>{_globalKey};
    if ((!migrationOnly || config.aiApiKey.isNotEmpty) &&
        !await _saveValue(_globalKey, config.aiApiKey)) {
      succeeded = false;
    }
    for (final profile in config.aiProfiles) {
      final key = _profileKey(profile.id);
      currentKeys.add(key);
      final value = profile.apiKey.isEmpty && profile.apiKeys.isEmpty
          ? ''
          : jsonEncode({
              'api_key': profile.apiKey,
              'api_keys': profile.apiKeys,
            });
      if ((!migrationOnly || value.isNotEmpty) &&
          !await _saveValue(key, value)) {
        succeeded = false;
      }
    }
    if (migrationOnly) {
      return succeeded;
    }
    // Only profiles successfully restored by this instance can be removed.
    for (final key in _knownKeys.difference(currentKeys)) {
      if (!await _saveValue(key, '')) {
        succeeded = false;
      }
    }
    return succeeded;
  }

  Future<bool> _saveValue(String key, String value) async {
    if (_unrestoredKeys.contains(key)) {
      return false;
    }
    try {
      if (!_knownKeys.contains(key)) {
        if (value.isEmpty) {
          return true;
        }
        // A newly added profile may reuse an id belonging to an orphan record.
        if (await _storage.read(key: key) != null) {
          _unrestoredKeys.add(key);
          return false;
        }
        _knownKeys.add(key);
      }
      if (value.isEmpty) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
      return true;
    } catch (_) {
      debugPrint('[AiCredentialStore] Credential change could not be saved.');
      return false;
    }
  }

  static String _profileKey(String id) => '${_keyPrefix}profile.$id';
}
