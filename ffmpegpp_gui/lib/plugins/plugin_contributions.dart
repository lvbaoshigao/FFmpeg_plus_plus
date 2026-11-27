import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';

/// A safe, non-secret change for a host-owned preview screen.
final class PluginContributionChange {
  const PluginContributionChange({
    required this.field,
    required this.before,
    required this.after,
  });

  final String field;
  final Object? before;
  final Object? after;
}

/// A declarative preset. Only the listed appearance keys can reach AppConfig.
///
/// [applyTo] mutates its argument and returns it, matching AppState.updateConfig.
/// No plugin gets an AppConfig or ThemeData reference.
final class PluginThemePreset {
  PluginThemePreset._(this.id, this._names, this.values);

  factory PluginThemePreset.fromJson(Map<String, dynamic> json) {
    _envelope(json, 'ffmpegpp.theme', {
      'kind',
      'schema_version',
      'id',
      'name',
      'values',
    });
    final id = _identifier(json['id'], 'theme.id');
    final names = _parseNames(json['name'], 'theme.name');
    final raw = _object(json['values'], 'theme.values');
    if (raw.isEmpty || raw.length > 32) {
      throw const FormatException('Theme values must contain 1 to 32 keys.');
    }
    final values = <String, dynamic>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      final where = 'theme.values.$key';
      values[key] = switch (key) {
        'theme_color' => _color(value, where, opaque: true),
        'theme_color2' =>
          value == null ? -1 : _color(value, where, opaque: true),
        'border_color' => _color(value, where),
        'use_theme_color' ||
        'glass_follow_theme' ||
        'border_enabled' => _boolean(value, where),
        'card_style' || 'nav_style' || 'pill_style' || 'menu_style' => _enum(
          value,
          const {'theme', 'liquid', 'blur', 'gray'},
          where,
        ),
        'glass_effect' => _enum(value, const {'liquid', 'blur', 'none'}, where),
        'dropdown_appearance' => _enum(value, const {
          'theme',
          'liquid',
          'frosted',
          'highlight',
          'gray',
        }, where),
        'selection_indicator_style' => _enum(value, const {
          'theme',
          'liquid',
          'blur',
          'outline',
        }, where),
        'settings_glass_mode' => _enum(value, const {
          'follow',
          'frosted',
          'solid',
        }, where),
        'canvas_bg' => _enum(value, const {
          'global',
          'gray',
          'black',
          'white',
        }, where),
        'card_opacity' ||
        'glass_clarity' ||
        'glass_light_pos' => _number(value, where, 0, 1),
        'glass_blur' => _number(value, where, 0, 30),
        'glass_highlight' => _number(value, where, 0, 1.6),
        'glass_edge' => _number(value, where, 0, 2),
        'theme_tone' => _number(value, where, 0, 0.8),
        'border_width' => _number(value, where, 0.5, 4),
        _ => throw FormatException('Unsupported theme key: $key.'),
      };
    }
    return PluginThemePreset._(
      id,
      names,
      Map<String, dynamic>.unmodifiable(values),
    );
  }

  final String id;
  final Map<String, String> _names;

  /// Validated AppConfig values; color strings have been converted to ARGB.
  final Map<String, dynamic> values;

  String get name => displayName();
  String displayName([String language = 'zh']) =>
      _names[language] ?? _names['en'] ?? _names.values.first;

  List<PluginContributionChange> preview(AppConfig config) {
    final current = config.toJson();
    return List<PluginContributionChange>.unmodifiable([
      for (final entry in values.entries)
        if (current[entry.key] != entry.value)
          PluginContributionChange(
            field: entry.key,
            before: current[entry.key],
            after: entry.value,
          ),
    ]);
  }

  AppConfig applyTo(AppConfig config) {
    for (final entry in values.entries) {
      final value = entry.value;
      switch (entry.key) {
        case 'theme_color':
          config.themeColor = value as int;
        case 'theme_color2':
          config.themeColor2 = value as int;
        case 'border_color':
          config.borderColor = value as int;
        case 'use_theme_color':
          config.useThemeColor = value as bool;
        case 'glass_follow_theme':
          config.glassFollowTheme = value as bool;
        case 'border_enabled':
          config.borderEnabled = value as bool;
        case 'card_style':
          config.cardStyle = value as String;
        case 'nav_style':
          config.navStyle = value as String;
        case 'pill_style':
          config.pillStyle = value as String;
        case 'menu_style':
          config.menuStyle = value as String;
        case 'glass_effect':
          config.glassEffect = value as String;
        case 'dropdown_appearance':
          config.dropdownAppearance = value as String;
        case 'selection_indicator_style':
          config.selectionIndicatorStyle = value as String;
        case 'settings_glass_mode':
          config.settingsGlassMode = value as String;
        case 'canvas_bg':
          config.canvasBg = value as String;
        case 'card_opacity':
          config.cardOpacity = value as double;
        case 'glass_clarity':
          config.glassClarity = value as double;
        case 'glass_light_pos':
          config.glassLightPos = value as double;
        case 'glass_blur':
          config.glassBlur = value as double;
        case 'glass_highlight':
          config.glassHighlight = value as double;
        case 'glass_edge':
          config.glassEdge = value as double;
        case 'theme_tone':
          config.themeTone = value as double;
        case 'border_width':
          config.borderWidth = value as double;
      }
    }
    return config;
  }

  AppConfig apply(AppConfig config) => applyTo(config);

  Map<String, dynamic> toJson() => {
    'kind': 'ffmpegpp.theme',
    'schema_version': 1,
    'id': id,
    'name': Map<String, String>.of(_names),
    'values': {
      for (final entry in values.entries)
        entry.key: switch (entry.key) {
          'theme_color' || 'border_color' => _colorString(entry.value as int),
          'theme_color2' =>
            entry.value == -1 ? null : _colorString(entry.value as int),
          _ => entry.value,
        },
    },
  };
}

/// A validated provider definition with no local identity or credentials.
final class PluginAiProfile {
  PluginAiProfile._(this.sourceId, this._data);

  final String sourceId;
  final Map<String, dynamic> _data;

  String get name => _data['name'] as String;
  String get provider => _data['provider'] as String;
  String get apiUrl => _data['api_url'] as String;
  String get apiPath => _data['api_path'] as String? ?? '';
  bool get useResponsesApi => _data['use_responses_api'] as bool? ?? false;
  List<AiModelEntry> get models => [
    for (final model in _data['models'] as List)
      AiModelEntry.fromJson(
        Map<String, dynamic>.of(model as Map<String, dynamic>),
      ),
  ];

  Map<String, dynamic> toJson() => {
    'source_id': sourceId,
    'profile': _mutableJson(_data),
  };

  AiProfile _createProfile(String id) => AiProfile(
    id: id,
    name: name,
    enabled: false,
    provider: provider,
    apiUrl: apiUrl,
    apiPath: apiPath,
    useResponsesApi: useResponsesApi,
    model: _data['model'] as String? ?? '',
    group: _data['group'] as String? ?? '',
    contextWindow: _data['context_window'] as int? ?? 128000,
    maxTokens: _data['max_tokens'] as int? ?? 4096,
    temperature: _data['temperature'] as double? ?? 0.3,
    models: models,
  );

  void _checkMergeTarget(AiProfile target) {
    // Headers may contain authentication. Refuse a merge that cannot be
    // described by the catalog rather than infer or expose their values.
    if (target.provider != provider ||
        _baseUrl(target.apiUrl, 'existing provider URL') != apiUrl ||
        target.apiPath != apiPath ||
        target.useResponsesApi != useResponsesApi ||
        target.customHeaders.isNotEmpty ||
        target.proxyUrl.isNotEmpty) {
      throw const FormatException(
        'Merge requires the same protocol, URL, path and request mode, '
        'with no custom headers or proxy. Import a disabled copy instead.',
      );
    }
  }
}

/// A data-only AI catalog. Parsing does not contact providers or save settings.
final class PluginAiCatalog {
  PluginAiCatalog._(this.bundleId, this._names, this.profiles);

  factory PluginAiCatalog.fromJson(Map<String, dynamic> json) {
    _envelope(json, 'ffmpegpp.ai-config', {
      'kind',
      'schema_version',
      'bundle_id',
      'name',
      'profiles',
    });
    final bundleId = _identifier(json['bundle_id'], 'ai.bundle_id');
    final names = json.containsKey('name')
        ? _parseNames(json['name'], 'ai.name')
        : Map<String, String>.unmodifiable({'en': bundleId});
    final rawProfiles = json['profiles'];
    if (rawProfiles is! List ||
        rawProfiles.isEmpty ||
        rawProfiles.length > 64) {
      throw const FormatException('AI catalog must contain 1 to 64 profiles.');
    }
    final profiles = <PluginAiProfile>[];
    final seen = <String>{};
    var modelCount = 0;
    for (final raw in rawProfiles) {
      final wrapper = _object(raw, 'ai.profiles entry');
      _keys(wrapper, const {'source_id', 'profile'}, 'ai.profiles entry');
      final sourceId = _identifier(wrapper['source_id'], 'ai.source_id');
      if (!seen.add(sourceId)) {
        throw const FormatException(
          'AI catalog contains duplicate source IDs.',
        );
      }
      final data = _profileData(_object(wrapper['profile'], 'ai.profile'));
      modelCount += (data['models'] as List).length;
      if (modelCount > 4096) {
        throw const FormatException('AI catalog exceeds 4096 models.');
      }
      profiles.add(PluginAiProfile._(sourceId, data));
    }
    return PluginAiCatalog._(
      bundleId,
      names,
      List<PluginAiProfile>.unmodifiable(profiles),
    );
  }

  final String bundleId;
  final Map<String, String> _names;
  final List<PluginAiProfile> profiles;
  String get name => displayName();
  String displayName([String language = 'zh']) =>
      _names[language] ?? _names['en'] ?? _names.values.first;

  /// Explicit source-ID -> local profile-ID targets; absence means a new copy.
  /// Merges add missing models only and preserve local configuration.
  PluginAiImportPlan preview(
    AppConfig config, {
    Map<String, String> mergeTargets = const {},
  }) {
    final sources = profiles.map((profile) => profile.sourceId).toSet();
    if (mergeTargets.keys.any((source) => !sources.contains(source)) ||
        mergeTargets.values.toSet().length != mergeTargets.length) {
      throw const FormatException(
        'Merge targets must be unique catalog sources.',
      );
    }
    final local = <String, AiProfile>{};
    for (final profile in config.aiProfiles) {
      if (local.containsKey(profile.id)) {
        throw const FormatException('Existing provider IDs must be unique.');
      }
      local[profile.id] = profile;
    }
    final items = <PluginAiImportItem>[];
    for (final source in profiles) {
      final targetId = mergeTargets[source.sourceId];
      if (targetId == null) {
        items.add(
          PluginAiImportItem._(
            source,
            const Uuid().v4(),
            null,
            null,
            source.models,
          ),
        );
      } else {
        final target = local[targetId];
        if (target == null) {
          throw const FormatException(
            'Selected merge target no longer exists.',
          );
        }
        source._checkMergeTarget(target);
        final ids = target.models.map((model) => model.id).toSet();
        // A legacy selected-model field is also a user choice. Do not replace
        // its implicit configuration with an imported model of the same ID.
        if (target.model.isNotEmpty) ids.add(target.model);
        items.add(
          PluginAiImportItem._(
            source,
            target.id,
            target.id,
            _fingerprint(target),
            source.models.where((model) => !ids.contains(model.id)),
          ),
        );
      }
    }
    return PluginAiImportPlan._(List<PluginAiImportItem>.unmodifiable(items));
  }

  Map<String, dynamic> toJson() => {
    'kind': 'ffmpegpp.ai-config',
    'schema_version': 1,
    'bundle_id': bundleId,
    'name': Map<String, String>.of(_names),
    'profiles': [for (final profile in profiles) profile.toJson()],
  };
}

/// Preview data never contains existing credentials or custom header values.
final class PluginAiImportItem {
  PluginAiImportItem._(
    this._source,
    this._profileId,
    this.targetProfileId,
    this._targetFingerprint,
    Iterable<AiModelEntry> addedModels,
  ) : _addedModelData = List<Map<String, dynamic>>.unmodifiable([
        for (final model in addedModels) _frozenObject(model.toJson()),
      ]);

  final PluginAiProfile _source;
  final String _profileId;
  final String? _targetFingerprint;
  final List<Map<String, dynamic>> _addedModelData;
  final String? targetProfileId;
  bool get isNew => targetProfileId == null;
  String get sourceId => _source.sourceId;
  String get name => _source.name;
  String get provider => _source.provider;
  String get apiUrl => _source.apiUrl;
  String get apiPath => _source.apiPath;
  List<String> get addedModelIds => List<String>.unmodifiable([
    for (final model in _addedModelData) model['id'] as String,
  ]);
  List<PluginContributionChange> get changes =>
      List<PluginContributionChange>.unmodifiable([
        if (isNew)
          PluginContributionChange(
            field: 'provider',
            before: null,
            after: name,
          ),
        for (final model in _addedModelData)
          PluginContributionChange(
            field: 'models.${model['id']}',
            before: null,
            after: model,
          ),
      ]);

  List<AiModelEntry> _models() => [
    for (final model in _addedModelData) AiModelEntry.fromJson(model),
  ];
}

/// A checked incremental import, suitable for one AppState.updateConfig call.
final class PluginAiImportPlan {
  PluginAiImportPlan._(this.items);
  final List<PluginAiImportItem> items;
  int get newProfileCount => items.where((item) => item.isNew).length;
  int get mergedProfileCount => items.length - newProfileCount;
  int get addedModelCount =>
      items.fold(0, (count, item) => count + item._addedModelData.length);

  AppConfig applyTo(AppConfig config) {
    final local = <String, AiProfile>{};
    for (final profile in config.aiProfiles) {
      if (local.containsKey(profile.id)) {
        throw const FormatException('Existing provider IDs must be unique.');
      }
      local[profile.id] = profile;
    }
    final replacements = <String, AiProfile>{};
    final additions = <AiProfile>[];
    // Validate and construct everything before assigning the list. A rejected
    // plan leaves the whole AppConfig, including its credentials, unchanged.
    for (final item in items) {
      if (item.isNew) {
        if (local.containsKey(item._profileId)) {
          throw const FormatException(
            'Import preview is stale; preview again.',
          );
        }
        additions.add(item._source._createProfile(item._profileId));
      } else {
        final target = local[item.targetProfileId];
        if (target == null || _fingerprint(target) != item._targetFingerprint) {
          throw const FormatException(
            'Import preview is stale; preview again.',
          );
        }
        item._source._checkMergeTarget(target);
        replacements[target.id] = target.copyWith(
          models: [
            for (final model in target.models) model.copy(),
            ...item._models(),
          ],
        );
      }
    }
    config.aiProfiles = [
      for (final profile in config.aiProfiles)
        replacements[profile.id] ?? profile,
      ...additions,
    ];
    return config;
  }

  AppConfig apply(AppConfig config) => applyTo(config);
}

Map<String, dynamic> _profileData(Map<String, dynamic> raw) {
  _keys(raw, const {
    'name',
    'provider',
    'api_url',
    'api_path',
    'use_responses_api',
    'model',
    'group',
    'context_window',
    'max_tokens',
    'temperature',
    'models',
  }, 'ai.profile');
  final data = <String, dynamic>{
    'name': _text(raw['name'], 'ai.profile.name', max: 128),
    'provider': _enum(raw['provider'], const {
      'openai',
      'anthropic',
    }, 'ai.provider'),
    'api_url': _baseUrl(raw['api_url'], 'ai.api_url'),
  };
  if (raw.containsKey('api_path')) {
    data['api_path'] = _apiPath(raw['api_path']);
  }
  if (raw.containsKey('use_responses_api')) {
    data['use_responses_api'] = _boolean(
      raw['use_responses_api'],
      'ai.use_responses_api',
    );
    if (data['use_responses_api'] == true && data['provider'] != 'openai') {
      throw const FormatException(
        'Responses API requires the OpenAI protocol.',
      );
    }
  }
  for (final key in const ['model', 'group']) {
    if (raw.containsKey(key)) {
      data[key] = _text(raw[key], 'ai.$key', max: 256, empty: true);
    }
  }
  for (final key in const ['context_window', 'max_tokens']) {
    if (raw.containsKey(key)) {
      data[key] = _integer(raw[key], 'ai.$key', 1, 100000000);
    }
  }
  if (raw.containsKey('temperature')) {
    data['temperature'] = _number(raw['temperature'], 'ai.temperature', 0, 2);
  }
  final models = raw['models'];
  if (models is! List || models.length > 1024) {
    throw const FormatException(
      'Each provider needs a models list of at most 1024 entries.',
    );
  }
  final cleanModels = <Map<String, dynamic>>[];
  final ids = <String>{};
  for (final model in models) {
    final clean = _modelData(_object(model, 'ai.models entry'));
    if (!ids.add(clean['id'] as String)) {
      throw const FormatException('Provider contains duplicate model IDs.');
    }
    cleanModels.add(clean);
  }
  final selected = data['model'] as String? ?? '';
  if (selected.isNotEmpty &&
      !cleanModels.any((m) => m['id'] == selected && m['enabled'] != false)) {
    throw const FormatException(
      'Selected model must be an enabled declared model.',
    );
  }
  data['models'] = cleanModels;
  return _frozenObject(data);
}

Map<String, dynamic> _modelData(Map<String, dynamic> raw) {
  _keys(raw, const {
    'id',
    'display_name',
    'enabled',
    'capabilities',
    'input_modalities',
    'output_modalities',
    'context_window',
    'max_tokens',
    'temperature',
    'top_p',
  }, 'ai.model');
  final data = <String, dynamic>{
    'id': _text(raw['id'], 'ai.model.id', max: 256),
  };
  if (raw.containsKey('display_name')) {
    data['display_name'] = _text(
      raw['display_name'],
      'ai.model.display_name',
      max: 256,
      empty: true,
    );
  }
  if (raw.containsKey('enabled')) {
    data['enabled'] = _boolean(raw['enabled'], 'ai.model.enabled');
  }
  final caps = raw.containsKey('capabilities')
      ? _enumList(
          raw['capabilities'],
          AiModelCapability.all.toSet(),
          'ai.model.capabilities',
        )
      : <String>[AiModelCapability.chat];
  final inputs = raw.containsKey('input_modalities')
      ? _enumList(raw['input_modalities'], const {
          'text',
          'image',
          'voice',
        }, 'ai.model.input_modalities')
      : <String>['text'];
  final outputs = raw.containsKey('output_modalities')
      ? _enumList(raw['output_modalities'], const {
          'text',
          'image',
          'voice',
        }, 'ai.model.output_modalities')
      : <String>['text'];
  if (inputs.contains('image') && !caps.contains(AiModelCapability.vision)) {
    caps.add(AiModelCapability.vision);
  }
  if (caps.contains(AiModelCapability.vision) && !inputs.contains('image')) {
    if (raw.containsKey('input_modalities')) {
      throw const FormatException('Vision capability needs image input.');
    }
    inputs.add('image');
  }
  // Defaults stay absent when unspecified. New models get host defaults;
  // merging never rewrites an existing model or clears its nullable overrides.
  if (raw.containsKey('capabilities') ||
      caps.contains(AiModelCapability.vision)) {
    data['capabilities'] = caps;
  }
  if (raw.containsKey('input_modalities') || inputs.contains('image')) {
    data['input_modalities'] = inputs;
  }
  if (raw.containsKey('output_modalities')) data['output_modalities'] = outputs;
  for (final key in const ['context_window', 'max_tokens']) {
    if (raw.containsKey(key)) {
      data[key] = raw[key] == null
          ? null
          : _integer(raw[key], 'ai.model.$key', 1, 100000000);
    }
  }
  for (final key in const ['temperature', 'top_p']) {
    if (raw.containsKey(key)) {
      data[key] = raw[key] == null
          ? null
          : _number(raw[key], 'ai.model.$key', 0, key == 'top_p' ? 1 : 2);
    }
  }
  return _frozenObject(data);
}

void _envelope(Map<String, dynamic> value, String kind, Set<String> allowed) {
  _keys(value, allowed, kind);
  if (value['kind'] != kind ||
      value['schema_version'] is! int ||
      value['schema_version'] != 1) {
    throw FormatException('Unsupported $kind kind or schema version.');
  }
}

void _keys(Map<String, dynamic> value, Set<String> allowed, String where) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      // Never include the value: an invalid field can contain credentials.
      throw FormatException('Unsupported field at $where: $key.');
    }
  }
}

Map<String, dynamic> _object(Object? value, String where) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$where must be an object.');
  }
  return Map<String, dynamic>.from(value);
}

String _text(Object? value, String where, {int max = 128, bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw FormatException('$where must be bounded plain text.');
  }
  final text = value.trim();
  if (!empty && text.isEmpty) {
    throw FormatException('$where must not be empty.');
  }
  return text;
}

String _identifier(Object? value, String where) {
  final text = _text(value, where);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(text)) {
    throw FormatException('$where must be a stable identifier.');
  }
  return text;
}

Map<String, String> _parseNames(Object? value, String where) {
  if (value is String) {
    return Map<String, String>.unmodifiable({'en': _text(value, where)});
  }
  final raw = _object(value, where);
  _keys(raw, const {'zh', 'en'}, where);
  if (raw.isEmpty) throw FormatException('$where must include a name.');
  return Map<String, String>.unmodifiable({
    for (final entry in raw.entries) entry.key: _text(entry.value, where),
  });
}

String _enum(Object? value, Set<String> allowed, String where) {
  if (value is! String || !allowed.contains(value)) {
    throw FormatException('$where has an unsupported value.');
  }
  return value;
}

List<String> _enumList(Object? value, Set<String> allowed, String where) {
  if (value is! List || value.isEmpty || value.length > allowed.length) {
    throw FormatException('$where must be a bounded nonempty list.');
  }
  final result = <String>[];
  for (final item in value) {
    final entry = _enum(item, allowed, where);
    if (result.contains(entry)) {
      throw FormatException('$where contains duplicates.');
    }
    result.add(entry);
  }
  return result;
}

bool _boolean(Object? value, String where) {
  if (value is! bool) throw FormatException('$where must be a boolean.');
  return value;
}

double _number(Object? value, String where, double minimum, double maximum) {
  if (value is! num || !value.isFinite || value < minimum || value > maximum) {
    throw FormatException('$where is outside its supported numeric range.');
  }
  return value.toDouble();
}

int _integer(Object? value, String where, int minimum, int maximum) {
  if (value is! num ||
      !value.isFinite ||
      value < minimum ||
      value > maximum ||
      value != value.truncate()) {
    throw FormatException('$where must be an integer in its supported range.');
  }
  return value.toInt();
}

int _color(Object? value, String where, {bool opaque = false}) {
  if (value is! String || !RegExp(r'^#[A-Fa-f0-9]{8}$').hasMatch(value)) {
    throw FormatException('$where must be an ARGB color (#AARRGGBB).');
  }
  final color = int.parse(value.substring(1), radix: 16);
  if (opaque && (color >> 24) != 255) {
    throw FormatException('$where must be opaque.');
  }
  return color;
}

String _colorString(int value) =>
    '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';

String _baseUrl(Object? value, String where) {
  final raw = _text(value, where, max: 2048);
  // Uri.parse normalizes encoded dot segments; validate the original spelling
  // first so traversal cannot disappear before validation.
  final authorityStart = raw.indexOf('://');
  final pathStart = authorityStart < 0
      ? -1
      : raw.indexOf('/', authorityStart + 3);
  if (pathStart >= 0) _checkRawPath(raw.substring(pathStart), where);
  final Uri uri;
  try {
    uri = Uri.parse(raw);
  } on FormatException {
    throw FormatException('$where must be an absolute provider URL.');
  }
  if (raw.contains('\\') ||
      RegExp(r'\s').hasMatch(raw) ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              const {
                'localhost',
                '127.0.0.1',
                '::1',
                '[::1]',
              }.contains(uri.host.toLowerCase())))) {
    throw FormatException(
      '$where requires HTTPS (or loopback HTTP), no credentials, query or fragment.',
    );
  }
  if (uri.pathSegments.any(
    (segment) => segment == '.' || segment == '..' || segment.contains('\\'),
  )) {
    throw FormatException('$where contains unsafe path segments.');
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        path: path,
      )
      .toString();
}

String _apiPath(Object? value) {
  final path = _text(value, 'ai.api_path', max: 512, empty: true);
  if (path.isEmpty) return path;
  _checkRawPath(path, 'ai.api_path');
  final Uri uri;
  try {
    uri = Uri.parse(path);
  } on FormatException {
    throw const FormatException(
      'AI API path must be a relative absolute-path reference.',
    );
  }
  if (!path.startsWith('/') ||
      path.startsWith('//') ||
      path.contains('\\') ||
      RegExp(r'\s').hasMatch(path) ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.any(
        (segment) =>
            segment == '.' || segment == '..' || segment.contains('\\'),
      )) {
    throw const FormatException(
      'AI API path must start with / and contain no host, query, fragment or traversal.',
    );
  }
  return path;
}

void _checkRawPath(String path, String where) {
  for (final segment in path.split('/')) {
    final String decoded;
    try {
      decoded = Uri.decodeComponent(segment);
    } on FormatException {
      throw FormatException('$where contains invalid path encoding.');
    }
    if (decoded == '.' ||
        decoded == '..' ||
        decoded.contains('/') ||
        decoded.contains('\\') ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(decoded)) {
      throw FormatException('$where contains unsafe path segments.');
    }
  }
}

String _fingerprint(AiProfile profile) =>
    sha256.convert(utf8.encode(jsonEncode(profile.toJson()))).toString();

Map<String, dynamic> _frozenObject(Map<String, dynamic> value) =>
    Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries) entry.key: _freezeJson(entry.value),
    });

Object? _freezeJson(Object? value) => switch (value) {
  Map<String, dynamic>() => _frozenObject(value),
  List() => List<Object?>.unmodifiable(value.map(_freezeJson)),
  _ => value,
};

Object? _mutableJson(Object? value) => switch (value) {
  Map<String, dynamic>() => {
    for (final entry in value.entries) entry.key: _mutableJson(entry.value),
  },
  List() => value.map(_mutableJson).toList(),
  _ => value,
};
