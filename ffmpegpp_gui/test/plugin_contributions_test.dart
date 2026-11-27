import 'dart:convert';

import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/plugins/plugin_contributions.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> theme(Map<String, dynamic> values) => {
  'kind': 'ffmpegpp.theme',
  'schema_version': 1,
  'id': 'org.example.glass',
  'name': {'zh': '清透', 'en': 'Clear'},
  'values': values,
};

Map<String, dynamic> profile({
  String name = 'Imported provider',
  String url = 'https://api.example.test/v1',
  List<Map<String, dynamic>>? models,
}) => {
  'name': name,
  'provider': 'openai',
  'api_url': url,
  'api_path': '/chat/completions',
  'models':
      models ??
      [
        {'id': 'new-model'},
      ],
};

Map<String, dynamic> catalog(List<Map<String, dynamic>> entries) => {
  'kind': 'ffmpegpp.ai-config',
  'schema_version': 1,
  'bundle_id': 'org.example.catalog',
  'profiles': entries,
};

Map<String, dynamic> entry(Map<String, dynamic> data, {String id = 'cloud'}) =>
    {'source_id': id, 'profile': data};

PluginAiCatalog one(Map<String, dynamic> data) =>
    PluginAiCatalog.fromJson(catalog([entry(data)]));

AiProfile localProfile() => AiProfile(
  id: 'local',
  name: 'My provider',
  enabled: true,
  apiUrl: 'https://api.example.test/v1',
  apiPath: '/chat/completions',
  apiKey: 'local-private-key',
  apiKeys: ['rotating-private-key'],
  multiKeyEnabled: true,
  model: 'user-model',
  group: 'Personal',
  temperature: 1.4,
  contextWindow: 8000,
  maxTokens: 2000,
  models: [
    AiModelEntry(
      id: 'user-model',
      displayName: 'My model',
      enabled: false,
      capabilities: [AiModelCapability.reasoning],
      contextWindow: 32000,
      maxTokens: 900,
      temperature: 0.7,
      topP: 0.8,
    ),
  ],
);

void main() {
  group('host-owned theme presets', () {
    test(
      'preview is inert and apply changes only explicit appearance keys',
      () {
        final config = AppConfig(
          cardStyle: 'gray',
          themeColor2: 0xFFAABBCC,
          fontSize: 23,
          darkMode: false,
          disableAnimations: true,
          useDynamicColor: true,
          glassGpuOnDesktop: true,
          aiApiKey: 'private-global-key',
          aiProfiles: [localProfile()],
        );
        final original = Map<String, dynamic>.of(config.toJson());
        final preset = PluginThemePreset.fromJson(
          theme({
            'card_style': 'liquid',
            'theme_color': '#FF123456',
            'theme_color2': null,
            'glass_blur': 20,
          }),
        );
        expect(preset.displayName('en'), 'Clear');
        expect(
          preset.preview(config).map((change) => change.field),
          containsAll([
            'card_style',
            'theme_color',
            'theme_color2',
            'glass_blur',
          ]),
        );
        expect(config.toJson(), original);
        expect(preset.applyTo(config), same(config));
        expect(config.cardStyle, 'liquid');
        expect(config.themeColor, 0xFF123456);
        expect(config.themeColor2, -1);
        expect(config.glassBlur, 20.0);
        final remaining = Map<String, dynamic>.of(config.toJson());
        for (final key in preset.values.keys) {
          remaining.remove(key);
          original.remove(key);
        }
        expect(remaining, original);
        expect(config.aiApiKey, 'private-global-key');
        expect(config.aiProfiles.single.apiKey, 'local-private-key');
        expect(preset.preview(config), isEmpty);
        expect(
          PluginThemePreset.fromJson(preset.toJson()).values,
          preset.values,
        );
      },
    );

    test('unrecognized settings cannot expand the appearance capability', () {
      for (final key in [
        'ai_profiles',
        'ai_api_key',
        'mcp_allow_write',
        'font_family',
        'background_image',
        'dark_mode',
        'disable_animations',
        'glass_gpu_on_desktop',
      ]) {
        expect(
          () => PluginThemePreset.fromJson(theme({key: true})),
          throwsFormatException,
        );
      }
      expect(
        () => PluginThemePreset.fromJson({
          ...theme({'card_style': 'gray'}),
          'ThemeData': {},
        }),
        throwsFormatException,
      );
    });

    test(
      'invalid ranges, non-finite values, colors and schema are rejected',
      () {
        for (final values in <Map<String, dynamic>>[
          {'card_style': 'shader-code'},
          {'glass_blur': 30.1},
          {'card_opacity': -0.1},
          {'glass_clarity': double.nan},
          {'glass_highlight': double.infinity},
          {'glass_edge': 2.1},
          {'glass_light_pos': 1.1},
          {'theme_tone': 0.81},
          {'border_width': 0.4},
          {'glass_follow_theme': 'true'},
          {'theme_color': '#00123456'},
          {'theme_color': '#123456'},
        ]) {
          expect(
            () => PluginThemePreset.fromJson(theme(values)),
            throwsFormatException,
          );
        }
        expect(
          () => PluginThemePreset.fromJson({
            ...theme({'card_style': 'gray'}),
            'schema_version': 2,
          }),
          throwsFormatException,
        );
        expect(
          () => PluginThemePreset.fromJson(theme({})),
          throwsFormatException,
        );
      },
    );

    test('input and output mutations cannot change a validated preset', () {
      final values = <String, dynamic>{'card_style': 'gray'};
      final preset = PluginThemePreset.fromJson(theme(values));
      values['card_style'] = 'unsafe';
      expect(
        () => preset.values['card_style'] = 'unsafe',
        throwsUnsupportedError,
      );
      (preset.toJson()['values'] as Map)['card_style'] = 'unsafe';
      expect(preset.applyTo(AppConfig()).cardStyle, 'gray');
    });
  });

  group('AI catalog validation', () {
    test('rejects credentials and authority fields without echoing values', () {
      for (final key in [
        'api_key',
        'api_keys',
        'custom_headers',
        'proxy_url',
        'id',
        'enabled',
        'multi_key_enabled',
        'ai_read_access',
        'ai_auto_execute',
      ]) {
        try {
          one({...profile(), key: 'must-not-appear-in-errors'});
          fail('Unexpected field was accepted: $key');
        } on FormatException catch (error) {
          expect(
            error.toString(),
            isNot(contains('must-not-appear-in-errors')),
          );
        }
      }
      expect(
        () => one(
          profile(
            models: [
              {'id': 'model', 'api_key': 'secret'},
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => PluginAiCatalog.fromJson({
          ...catalog([entry(profile())]),
          'ai_approve_mode': 'auto',
        }),
        throwsFormatException,
      );
    });

    test('accepts HTTPS and explicit loopback HTTP without networking', () {
      for (final url in [
        'https://api.example.test/v1',
        'http://localhost:11434/v1',
        'http://127.0.0.1:11434/v1',
        'http://[::1]:11434/v1',
      ]) {
        expect(one(profile(url: url)).profiles.single.apiUrl, url);
      }
      expect(
        one(
          profile(url: 'https://API.EXAMPLE.TEST/v1/'),
        ).profiles.single.apiUrl,
        'https://api.example.test/v1',
      );
    });

    test('rejects unsafe provider URLs and request paths', () {
      for (final url in [
        'http://api.example.test/v1',
        'file:///tmp/config',
        'https://user:password@api.example.test/v1',
        'https://api.example.test/v1?api_key=secret',
        'https://api.example.test/v1#secret',
        '//api.example.test/v1',
        'https://api.example.test:0/v1',
        'https://api.example.test:65536/v1',
        'https://api.example.test:bad/v1',
        r'https://api.example.test\attacker.test/v1',
        'https://api.example.test/%2e%2e/secret',
      ]) {
        expect(
          () => one(profile(url: url)),
          throwsFormatException,
          reason: url,
        );
      }
      for (final path in [
        '//attacker.test/',
        'https://attacker.test/',
        'chat/completions',
        '/chat?token=secret',
        '/chat#secret',
        r'/chat\bad',
        '/%2e%2e/secret',
      ]) {
        expect(
          () => one({...profile(), 'api_path': path}),
          throwsFormatException,
          reason: path,
        );
      }
    });

    test('retains absent fields and explicit model inheritance nulls', () {
      final parsed = one(
        profile(
          models: [
            {'id': 'new-model', 'context_window': null, 'temperature': null},
          ],
        ),
      );
      final data = parsed.profiles.single.toJson()['profile'] as Map;
      expect(data, isNot(contains('temperature')));
      expect(data, isNot(contains('context_window')));
      final model = (data['models'] as List).single as Map;
      expect(model, containsPair('context_window', null));
      expect(model, containsPair('temperature', null));
      expect(model, isNot(contains('top_p')));
      final config = AppConfig();
      parsed.preview(config).applyTo(config);
      expect(config.aiProfiles.single.models.single.temperature, isNull);
      expect(config.aiProfiles.single.models.single.contextWindow, isNull);
    });

    test(
      'model metadata is bounded and modalities agree with capabilities',
      () {
        final model = one(
          profile(
            models: [
              {
                'id': 'vision-model',
                'input_modalities': ['text', 'image'],
                'output_modalities': ['text'],
              },
            ],
          ),
        ).profiles.single.models.single;
        expect(model.capabilities, contains(AiModelCapability.vision));
        for (final patch in <Map<String, dynamic>>[
          {'temperature': 2.1},
          {'top_p': -0.1},
          {'max_tokens': 0},
          {'context_window': 1.2},
          {'context_window': double.infinity},
          {
            'capabilities': ['unknown'],
          },
          {
            'input_modalities': ['audio'],
          },
          {'output_modalities': []},
          {'enabled': 'yes'},
          {
            'capabilities': ['vision'],
            'input_modalities': ['text'],
          },
        ]) {
          expect(
            () => one(
              profile(
                models: [
                  {'id': 'm', ...patch},
                ],
              ),
            ),
            throwsFormatException,
          );
        }
        expect(
          () => one({...profile(), 'provider': 'unknown'}),
          throwsFormatException,
        );
        expect(
          () => one({
            ...profile(),
            'provider': 'anthropic',
            'use_responses_api': true,
          }),
          throwsFormatException,
        );
        expect(
          () => one({...profile(), 'model': 'undeclared'}),
          throwsFormatException,
        );
        expect(
          () => one(
            profile(
              models: [
                {'id': 'm'},
                {'id': 'm'},
              ],
            ),
          ),
          throwsFormatException,
        );
      },
    );

    test('catalog identities and collection budgets are checked', () {
      expect(
        () => PluginAiCatalog.fromJson(
          catalog([entry(profile()), entry(profile())]),
        ),
        throwsFormatException,
      );
      expect(
        () => PluginAiCatalog.fromJson(catalog([])),
        throwsFormatException,
      );
      expect(
        () => PluginAiCatalog.fromJson(
          catalog([
            for (var i = 0; i < 65; i++) entry(profile(), id: 'source-$i'),
          ]),
        ),
        throwsFormatException,
      );
      expect(
        () => one(
          profile(
            models: [
              for (var i = 0; i < 1025; i++) {'id': 'model-$i'},
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => PluginAiCatalog.fromJson(
          catalog([
            for (var i = 0; i < 5; i++)
              entry(
                profile(
                  models: [
                    for (var j = 0; j < 1024; j++) {'id': 'model-$j'},
                  ],
                ),
                id: 'source-$i',
              ),
          ]),
        ),
        throwsFormatException,
      );
    });

    test('validated catalog does not retain mutable caller data', () {
      final model = <String, dynamic>{
        'id': 'm',
        'capabilities': ['chat'],
      };
      final parsed = one(profile(models: [model]));
      (model['capabilities'] as List).add('secret');
      parsed.profiles.single.models.single.capabilities.add('secret');
      final exported = parsed.toJson();
      final wrapped = (exported['profiles'] as List).single as Map;
      ((wrapped['profile'] as Map)['models'] as List).clear();
      expect(parsed.profiles.single.models.single.capabilities, ['chat']);
      expect(
        PluginAiCatalog.fromJson(
          parsed.toJson(),
        ).profiles.single.models.single.id,
        'm',
      );
    });
  });

  group('AI preview and incremental commit', () {
    test(
      'default import creates a disabled fresh identity without changing selection',
      () {
        final existing = localProfile();
        final config = AppConfig(
          aiProfiles: [existing],
          activeAiProfileId: existing.id,
          aiApiKey: 'global-secret',
          aiReadAccess: true,
        );
        final before = jsonEncode(config.toJson());
        final parsed = one(profile());
        final plan = parsed.preview(config);
        expect(plan.newProfileCount, 1);
        expect(plan.mergedProfileCount, 0);
        expect(plan.addedModelCount, 1);
        expect(jsonEncode(config.toJson()), before);
        plan.applyTo(config);
        final added = config.aiProfiles.last;
        expect(added.id, isNot(existing.id));
        expect(added.id, isNot('cloud'));
        expect(added.enabled, isFalse);
        expect(added.apiKey, isEmpty);
        expect(added.apiKeys, isEmpty);
        expect(added.customHeaders, isEmpty);
        expect(added.proxyUrl, isEmpty);
        expect(added.multiKeyEnabled, isFalse);
        expect(config.activeAiProfileId, existing.id);
        expect(config.aiApiKey, 'global-secret');
        expect(config.aiReadAccess, isTrue);
        expect(config.aiProfiles.first, same(existing));
        expect(() => plan.applyTo(config), throwsFormatException);
      },
    );

    test(
      'explicit merge adds missing models and preserves all user fields and keys',
      () {
        final target = localProfile();
        final original = Map<String, dynamic>.of(target.toJson())
          ..remove('models');
        final originalModel = target.models.single.toJson();
        final config = AppConfig(
          aiProfiles: [target],
          activeAiProfileId: 'local',
        );
        final parsed = one({
          ...profile(
            models: [
              {
                'id': 'user-model',
                'display_name': 'Overwrite attempt',
                'temperature': null,
              },
              {'id': 'new-model', 'context_window': null, 'temperature': 0.2},
            ],
          ),
          'context_window': 1000000,
          'temperature': 0.1,
        });
        final plan = parsed.preview(config, mergeTargets: {'cloud': 'local'});
        expect(plan.newProfileCount, 0);
        expect(plan.mergedProfileCount, 1);
        expect(plan.items.single.addedModelIds, ['new-model']);
        expect(
          jsonEncode(plan.items.single.changes.map((c) => c.after).toList()),
          isNot(contains('private-key')),
        );
        plan.applyTo(config);
        final merged = config.aiProfiles.single;
        expect(
          Map<String, dynamic>.of(merged.toJson())..remove('models'),
          original,
        );
        expect(merged.models.first.toJson(), originalModel);
        expect(merged.models.last.id, 'new-model');
        expect(merged.models.last.temperature, 0.2);
        expect(merged.apiKey, 'local-private-key');
        expect(merged.apiKeys, ['rotating-private-key']);
        expect(target.models, hasLength(1));
        expect(config.activeAiProfileId, 'local');
      },
    );

    test(
      'request semantics must match before any existing key may be retained',
      () {
        final parsed = one(profile());
        for (final change in <void Function(AiProfile)>[
          (p) => p.apiUrl = 'https://attacker.test/v1',
          (p) => p.apiPath = '/responses',
          (p) => p.provider = 'anthropic',
          (p) => p.useResponsesApi = true,
          (p) => p.customHeaders = {'Authorization': 'secret'},
          (p) => p.proxyUrl = 'https://proxy.test',
        ]) {
          final target = localProfile();
          change(target);
          final config = AppConfig(aiProfiles: [target]);
          expect(
            () => parsed.preview(config, mergeTargets: {'cloud': 'local'}),
            throwsFormatException,
          );
          expect(config.aiProfiles.single, same(target));
        }
      },
    );

    test('rejects unknown, reused or missing explicit merge targets', () {
      final config = AppConfig(aiProfiles: [localProfile()]);
      final parsed = one(profile());
      expect(
        () => parsed.preview(config, mergeTargets: {'absent': 'local'}),
        throwsFormatException,
      );
      expect(
        () => parsed.preview(config, mergeTargets: {'cloud': 'missing'}),
        throwsFormatException,
      );
      final two = PluginAiCatalog.fromJson(
        catalog([entry(profile(), id: 'a'), entry(profile(), id: 'b')]),
      );
      expect(
        () => two.preview(config, mergeTargets: {'a': 'local', 'b': 'local'}),
        throwsFormatException,
      );
    });

    test(
      'stale plan rejects the entire batch before assigning new providers',
      () {
        final target = localProfile();
        final config = AppConfig(aiProfiles: [target]);
        final parsed = PluginAiCatalog.fromJson(
          catalog([entry(profile(), id: 'new'), entry(profile(), id: 'merge')]),
        );
        final plan = parsed.preview(config, mergeTargets: {'merge': 'local'});
        target.name = 'Changed since preview';
        final before = jsonEncode(config.toJson());
        expect(() => plan.applyTo(config), throwsFormatException);
        expect(jsonEncode(config.toJson()), before);
        expect(config.aiProfiles, hasLength(1));
        expect(config.aiProfiles.single.apiKey, 'local-private-key');
      },
    );

    test(
      'a secret edited during preview stays local and is preserved at commit',
      () {
        final target = localProfile();
        final config = AppConfig(aiProfiles: [target]);
        final plan = one(
          profile(),
        ).preview(config, mergeTargets: {'cloud': 'local'});
        target.apiKey = 'new-private-key';
        target.apiKeys = ['new-rotating-key'];
        plan.applyTo(config);
        expect(config.aiProfiles.single.apiKey, 'new-private-key');
        expect(config.aiProfiles.single.apiKeys, ['new-rotating-key']);
      },
    );
  });
}
