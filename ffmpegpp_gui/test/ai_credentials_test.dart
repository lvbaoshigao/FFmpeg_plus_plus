import 'dart:convert';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI credentials are excluded from settings JSON', () {
    final profile = AiProfile(
      id: 'profile-1',
      apiKey: 'profile-secret',
      apiKeys: ['rotating-secret'],
    );
    final config = AppConfig()
      ..aiApiKey = 'global-secret'
      ..aiProfiles = [profile];

    final profileJson = profile.toJson();
    final configJson = config.toJson();

    expect(profileJson, isNot(contains('api_key')));
    expect(profileJson, isNot(contains('api_keys')));
    expect(configJson, isNot(contains('ai_api_key')));
    expect(jsonEncode(configJson), isNot(contains('global-secret')));
    expect(jsonEncode(configJson), isNot(contains('profile-secret')));
    expect(jsonEncode(configJson), isNot(contains('rotating-secret')));
  });

  test(
    'legacy plaintext credentials remain loadable for keychain migration',
    () {
      final config = AppConfig.fromJson({
        'ai_api_key': 'legacy-global-secret',
        'ai_profiles': [
          {
            'id': 'legacy-profile',
            'api_key': 'legacy-profile-secret',
            'api_keys': ['legacy-rotating-secret'],
          },
        ],
      });

      expect(config.aiApiKey, 'legacy-global-secret');
      expect(config.aiProfiles.single.apiKey, 'legacy-profile-secret');
      expect(config.aiProfiles.single.apiKeys, ['legacy-rotating-secret']);
    },
  );
}
