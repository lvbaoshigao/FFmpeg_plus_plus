/// Versioned, host-validated plugin metadata. No Flutter or platform dependency.
library;

class PluginBasicInfo {
  final String name;
  final String version;
  final bool isPreview;
  final String summary;

  const PluginBasicInfo({
    required this.name,
    required this.version,
    required this.isPreview,
    required this.summary,
  });

  factory PluginBasicInfo.fromJson(Map<String, dynamic> json) {
    _keys(json, const {
      'Name',
      'Version',
      'IsPreview',
      'Summary',
    }, 'Basic_info');
    final name = _text(json['Name'], 'Basic_info.Name', max: 120);
    final version = _text(json['Version'], 'Basic_info.Version', max: 256);
    PluginVersion.parse(version);
    return PluginBasicInfo(
      name: name,
      version: version,
      isPreview: _boolean(json['IsPreview'], 'Basic_info.IsPreview'),
      summary: _text(
        json['Summary'],
        'Basic_info.Summary',
        max: 4096,
        allowEmpty: true,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'Name': name,
    'Version': version,
    'IsPreview': isPreview,
    'Summary': summary,
  };
}

class PluginLimits {
  static const int maxMemoryMb = 64;
  static const int maxTimeMs = 5000;
  static const int maxFuel = 10000000;
  final int memoryMb;
  final int timeMs;
  final int fuel;

  const PluginLimits({
    this.memoryMb = 16,
    this.timeMs = 1000,
    this.fuel = 1000000,
  });

  int get memoryBytes => memoryMb * 1024 * 1024;

  factory PluginLimits.fromJson(Map<String, dynamic> json) {
    _keys(json, const {'memory_mb', 'time_ms', 'fuel'}, 'limits');
    return PluginLimits(
      memoryMb: _integer(
        json['memory_mb'] ?? 16,
        'limits.memory_mb',
        min: 1,
        max: maxMemoryMb,
      ),
      timeMs: _integer(
        json['time_ms'] ?? 1000,
        'limits.time_ms',
        min: 1,
        max: maxTimeMs,
      ),
      fuel: _integer(
        json['fuel'] ?? 1000000,
        'limits.fuel',
        min: 1,
        max: maxFuel,
      ),
    );
  }

  void validate() => PluginLimits.fromJson(toJson());
  Map<String, dynamic> toJson() => {
    'memory_mb': memoryMb,
    'time_ms': timeMs,
    'fuel': fuel,
  };
}

class PluginPermissions {
  final bool filesRead;
  final bool filesWrite;
  final List<String> network;

  const PluginPermissions({
    this.filesRead = false,
    this.filesWrite = false,
    this.network = const [],
  });

  bool get readFiles => filesRead;
  bool get writeFiles => filesWrite;
  bool get fileRead => filesRead;
  bool get fileWrite => filesWrite;
  List<String> get networkOrigins => network;

  /// Keys used by the permission grant UI and host capability checks.
  Set<String> get grantKeys => Set.unmodifiable({
    if (filesRead) 'files.read',
    if (filesWrite) 'files.write',
    for (final origin in network) 'network:$origin',
  });
  Set<String> get requiredGrants => grantKeys;

  factory PluginPermissions.fromJson(Map<String, dynamic> json) {
    _keys(json, const {'files', 'network'}, 'permissions');
    final files = _object(
      json['files'] ?? <String, dynamic>{},
      'permissions.files',
    );
    _keys(files, const {'read', 'write'}, 'permissions.files');
    final origins = _list(json['network'] ?? [], 'permissions.network', max: 32)
        .map(
          (value) => canonicalPluginOrigin(
            _text(value, 'permissions.network origin', max: 2048),
          ),
        )
        .toList();
    if (origins.toSet().length != origins.length) {
      _fail('permissions.network has duplicate origins');
    }
    return PluginPermissions(
      filesRead: _boolean(files['read'] ?? false, 'permissions.files.read'),
      filesWrite: _boolean(files['write'] ?? false, 'permissions.files.write'),
      network: List.unmodifiable(origins),
    );
  }

  void validate() => PluginPermissions.fromJson(toJson());
  Map<String, dynamic> toJson() => {
    'files': {'read': filesRead, 'write': filesWrite},
    'network': List<String>.of(network),
  };
}

/// Returns the exact canonical HTTPS origin accepted by the plugin host.
String canonicalPluginOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.host.contains('*') ||
      value.trim() != value ||
      value.runes.any((code) => code <= 32 || code == 127) ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.port < 1 ||
      uri.port > 65535 ||
      value.contains('\\')) {
    _fail('Network permissions require an exact HTTPS origin: $value');
  }
  return uri.origin;
}

class PluginDependency {
  final String id;
  final String version;
  const PluginDependency({required this.id, required this.version});
  PluginVersionConstraint get constraint =>
      PluginVersionConstraint.parse(version);
  bool matches(String candidateVersion) => constraint.matches(candidateVersion);

  factory PluginDependency.fromJson(Map<String, dynamic> json) {
    _keys(json, const {'id', 'version'}, 'dependency');
    final id = _pluginId(json['id'], 'dependency.id');
    final version = _text(json['version'], 'dependency.version', max: 1024);
    PluginVersionConstraint.parse(version);
    return PluginDependency(id: id, version: version);
  }

  Map<String, dynamic> toJson() => {'id': id, 'version': version};
}

class PluginFieldDefinition {
  final String key;
  final String label;
  final String type;
  final dynamic defaultValue;
  final num? min;
  final num? max;
  final List<String> options;

  const PluginFieldDefinition({
    required this.key,
    required this.label,
    required this.type,
    required this.defaultValue,
    this.min,
    this.max,
    this.options = const [],
  });

  factory PluginFieldDefinition.fromJson(Map<String, dynamic> json) {
    _keys(json, const {
      'key',
      'label',
      'type',
      'default',
      'min',
      'max',
      'options',
    }, 'field');
    final key = _identifier(json['key'], 'field.key');
    final label = _text(json['label'], 'field.label', max: 256);
    final type = _text(json['type'], 'field.type', max: 16);
    if (!const {
      'number',
      'integer',
      'string',
      'boolean',
      'select',
    }.contains(type)) {
      _fail('Unsupported field type: $type');
    }
    if (!json.containsKey('default')) _fail('field.default is required');
    final min = json.containsKey('min')
        ? _finiteNumber(json['min'], 'field.min')
        : null;
    final max = json.containsKey('max')
        ? _finiteNumber(json['max'], 'field.max')
        : null;
    if ((min != null || max != null) && type != 'number' && type != 'integer') {
      _fail('Only number and integer fields accept min/max');
    }
    if (type == 'integer') {
      if (min != null) _exactInteger(min, 'field.min');
      if (max != null) _exactInteger(max, 'field.max');
    }
    if (min != null && max != null && min > max) {
      _fail('field.min exceeds field.max');
    }
    final options = _list(
      json['options'] ?? [],
      'field.options',
      max: 128,
    ).map((value) => _text(value, 'field option', max: 1024)).toList();
    if (type == 'select' && options.isEmpty) {
      _fail('Select fields need options');
    }
    if (type != 'select' && json.containsKey('options')) {
      _fail('Only select fields accept options');
    }
    if (options.toSet().length != options.length) {
      _fail('Select options must be unique');
    }
    final result = PluginFieldDefinition(
      key: key,
      label: label,
      type: type,
      defaultValue: json['default'],
      min: min,
      max: max,
      options: List.unmodifiable(options),
    );
    result.validateValue(result.defaultValue);
    return result;
  }

  dynamic validateValue(Object? value) {
    switch (type) {
      case 'number':
      case 'integer':
        final number = _finiteNumber(value, key);
        final normalized = type == 'integer'
            ? _exactInteger(number, key)
            : number;
        if (min != null && number < min!) _fail('$key is below its minimum');
        if (max != null && number > max!) _fail('$key exceeds its maximum');
        return normalized;
      case 'boolean':
        return _boolean(value, key);
      case 'string':
        return _text(value, key, max: 16384, allowEmpty: true);
      case 'select':
        final text = _text(value, key, max: 1024);
        if (!options.contains(text)) _fail('$key is not one of its options');
        return text;
      default:
        _fail('Unsupported field type: $type');
    }
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'type': type,
    'default': defaultValue,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (type == 'select') 'options': List<String>.of(options),
  };
}

class PluginNodeDefinition {
  final String id;
  final String name;
  final String fun;
  final bool isLogic;
  final int inputCount;
  final int outputCount;
  final List<String> inputTypes;
  final String outputType;
  final int schemaVersion;
  final List<PluginFieldDefinition> fields;

  const PluginNodeDefinition({
    required this.id,
    required this.name,
    required this.fun,
    required this.isLogic,
    this.inputCount = 1,
    this.outputCount = 1,
    required this.inputTypes,
    required this.outputType,
    this.schemaVersion = 1,
    this.fields = const [],
  });

  String get description => fun;

  factory PluginNodeDefinition.fromJson(Map<String, dynamic> json) {
    _keys(json, const {
      'id',
      'name',
      'fun',
      'IsLogic',
      'IO',
      'input_types',
      'output_type',
      'schema_version',
      'fields',
    }, 'node');
    final io = _object(json['IO'], 'node.IO');
    _keys(io, const {'inputs', 'outputs'}, 'node.IO');
    final inputCount = _integer(io['inputs'], 'node.IO.inputs', min: 1, max: 1);
    final outputCount = _integer(
      io['outputs'],
      'node.IO.outputs',
      min: 1,
      max: 1,
    );
    final inputTypes = _list(
      json['input_types'],
      'node.input_types',
      max: 3,
    ).map((value) => _mediaType(value, 'node.input_types')).toList();
    if (inputTypes.isEmpty || inputTypes.toSet().length != inputTypes.length) {
      _fail('node.input_types must contain unique media types');
    }
    final fields = _list(json['fields'] ?? [], 'node.fields', max: 64)
        .map((value) => PluginFieldDefinition.fromJson(_object(value, 'field')))
        .toList();
    if (fields.map((field) => field.key).toSet().length != fields.length) {
      _fail('Node field keys must be unique');
    }
    return PluginNodeDefinition(
      id: _identifier(json['id'], 'node.id'),
      name: _text(json['name'], 'node.name', max: 120),
      fun: _text(json['fun'], 'node.fun', max: 4096, allowEmpty: true),
      isLogic: _boolean(json['IsLogic'], 'node.IsLogic'),
      inputCount: inputCount,
      outputCount: outputCount,
      inputTypes: List.unmodifiable(inputTypes),
      outputType: _mediaType(json['output_type'], 'node.output_type'),
      schemaVersion: _integer(
        json['schema_version'] ?? 1,
        'node.schema_version',
        min: 1,
        max: 1,
      ),
      fields: List.unmodifiable(fields),
    );
  }

  /// Validates against a live declaration. Stored snapshots are display data only.
  Map<String, dynamic> validateValues(
    Map<String, dynamic> values, {
    bool fillDefaults = true,
  }) {
    final known = fields.map((field) => field.key).toSet();
    for (final key in values.keys) {
      if (!known.contains(key)) _fail('Unknown node parameter: $key');
    }
    return {
      for (final field in fields)
        if (values.containsKey(field.key))
          field.key: field.validateValue(values[field.key])
        else if (fillDefaults)
          field.key: field.validateValue(field.defaultValue),
    };
  }

  void validate() => PluginNodeDefinition.fromJson(toJson());
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'fun': fun,
    'IsLogic': isLogic,
    'IO': {'inputs': inputCount, 'outputs': outputCount},
    'input_types': List<String>.of(inputTypes),
    'output_type': outputType,
    'schema_version': schemaVersion,
    'fields': fields.map((field) => field.toJson()).toList(),
  };
}

/// One installation manifest. Constructed values are revalidated before publishing.
class PluginManifest {
  static const int currentFormatVersion = 1;
  static const int currentApiVersion = 1;
  final int formatVersion;
  final String id;
  final int apiVersion;
  final String appVersion;
  final PluginBasicInfo basicInfo;
  final String? modulePath;
  final List<PluginNodeDefinition> nodes;
  final PluginPermissions permissions;
  final PluginLimits limits;
  final List<PluginDependency> dependencies;
  final List<Map<String, dynamic>> themes;
  final List<Map<String, dynamic>> aiConfigs;

  const PluginManifest({
    this.formatVersion = currentFormatVersion,
    required this.id,
    this.apiVersion = currentApiVersion,
    required this.appVersion,
    required this.basicInfo,
    this.modulePath,
    this.nodes = const [],
    this.permissions = const PluginPermissions(),
    this.limits = const PluginLimits(),
    this.dependencies = const [],
    this.themes = const [],
    this.aiConfigs = const [],
  });

  String get name => basicInfo.name;
  String get version => basicInfo.version;
  bool get isPreview => basicInfo.isPreview;
  String get summary => basicInfo.summary;
  String? get module => modulePath;
  List<PluginNodeDefinition> get nodeInfo => nodes;
  PluginVersionConstraint get appVersionConstraint =>
      PluginVersionConstraint.parse(appVersion);
  bool supportsAppVersion(String version) =>
      appVersionConstraint.matches(version);

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    _keys(json, const {
      'format_version',
      'id',
      'api_version',
      'app_version',
      'Basic_info',
      'module',
      'Node_info',
      'permissions',
      'limits',
      'dependencies',
      'themes',
      'ai_configs',
    }, 'manifest');
    final formatVersion = _integer(
      json['format_version'],
      'format_version',
      min: 1,
      max: currentFormatVersion,
    );
    final apiVersion = _integer(
      json['api_version'],
      'api_version',
      min: 1,
      max: currentApiVersion,
    );
    final id = _pluginId(json['id'], 'id');
    final appVersion = _text(json['app_version'], 'app_version', max: 1024);
    PluginVersionConstraint.parse(appVersion);
    final nodes = _list(json['Node_info'] ?? [], 'Node_info', max: 128)
        .map((value) => PluginNodeDefinition.fromJson(_object(value, 'node')))
        .toList();
    if (nodes.map((node) => node.id).toSet().length != nodes.length) {
      _fail('Node_info contains duplicate node IDs');
    }
    final modulePath = json.containsKey('module')
        ? validatePluginRelativePath(_text(json['module'], 'module', max: 240))
        : null;
    if (modulePath != null && !modulePath.endsWith('.wasm')) {
      _fail('module must name a .wasm file');
    }
    if (nodes.isNotEmpty && modulePath == null) {
      _fail('Plugins declaring nodes require a WASM module');
    }
    final dependencies =
        _list(json['dependencies'] ?? [], 'dependencies', max: 32)
            .map(
              (value) =>
                  PluginDependency.fromJson(_object(value, 'dependency')),
            )
            .toList();
    if (dependencies.any((value) => value.id == id)) {
      _fail('A plugin cannot depend on itself');
    }
    if (dependencies.map((value) => value.id).toSet().length !=
        dependencies.length) {
      _fail('Duplicate plugin dependencies');
    }
    return PluginManifest(
      formatVersion: formatVersion,
      id: id,
      apiVersion: apiVersion,
      appVersion: appVersion,
      basicInfo: PluginBasicInfo.fromJson(
        _object(json['Basic_info'], 'Basic_info'),
      ),
      modulePath: modulePath,
      nodes: List.unmodifiable(nodes),
      permissions: PluginPermissions.fromJson(
        _object(json['permissions'] ?? <String, dynamic>{}, 'permissions'),
      ),
      limits: PluginLimits.fromJson(
        _object(json['limits'] ?? <String, dynamic>{}, 'limits'),
      ),
      dependencies: List.unmodifiable(dependencies),
      themes: _contributions(json['themes'] ?? [], 'themes'),
      aiConfigs: _contributions(json['ai_configs'] ?? [], 'ai_configs'),
    );
  }

  void validate() => PluginManifest.fromJson(toJson());
  void validateCompatibility(
    String appVersion, {
    int supportedApiVersion = currentApiVersion,
  }) {
    if (apiVersion != supportedApiVersion) {
      _fail('Unsupported plugin API version: $apiVersion');
    }
    if (!supportsAppVersion(appVersion)) {
      _fail('Plugin $id is incompatible with application $appVersion');
    }
  }

  Map<String, dynamic> toJson() => {
    'format_version': formatVersion,
    'id': id,
    'api_version': apiVersion,
    'app_version': appVersion,
    'Basic_info': basicInfo.toJson(),
    if (modulePath != null) 'module': modulePath,
    if (nodes.isNotEmpty)
      'Node_info': nodes.map((node) => node.toJson()).toList(),
    'permissions': permissions.toJson(),
    'limits': limits.toJson(),
    'dependencies': dependencies
        .map((dependency) => dependency.toJson())
        .toList(),
    'themes': _jsonCopy(themes),
    'ai_configs': _jsonCopy(aiConfigs),
  };
}

/// Strict relative archive path, shared by package/module validation.
String validatePluginRelativePath(String value) {
  if (value.isEmpty ||
      value.length > 240 ||
      value.startsWith('/') ||
      value.contains('\\') ||
      value.contains(':') ||
      value.runes.any((code) => code < 32 || code == 127)) {
    _fail('Invalid plugin relative path: $value');
  }
  final segments = value.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    _fail('Invalid plugin relative path: $value');
  }
  return value;
}

/// Semantic Versioning 2.0 precedence, including numeric prerelease identifiers.
class PluginVersion implements Comparable<PluginVersion> {
  final String value;
  final BigInt major;
  final BigInt minor;
  final BigInt patch;
  final List<String> prerelease;
  final List<String> build;
  const PluginVersion._(
    this.value,
    this.major,
    this.minor,
    this.patch,
    this.prerelease,
    this.build,
  );

  static final _pattern = RegExp(
    r'^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*))?(?:[+]([0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*))?$',
  );
  static final _numeric = RegExp(r'^[0-9]+$');

  factory PluginVersion.parse(String value) {
    if (value.length > 256) _fail('Semantic version is too long');
    final match = _pattern.firstMatch(value);
    if (match == null || match.end != value.length) {
      _fail('Invalid semantic version: $value');
    }
    final prerelease = match.group(4)?.split('.') ?? <String>[];
    for (final identifier in prerelease) {
      if (_numeric.hasMatch(identifier) &&
          identifier.length > 1 &&
          identifier.startsWith('0')) {
        _fail('Numeric prerelease identifiers must not have leading zeros');
      }
    }
    return PluginVersion._(
      value,
      BigInt.parse(match.group(1)!),
      BigInt.parse(match.group(2)!),
      BigInt.parse(match.group(3)!),
      List.unmodifiable(prerelease),
      List.unmodifiable(match.group(5)?.split('.') ?? <String>[]),
    );
  }

  @override
  int compareTo(PluginVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    final length = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var i = 0; i < length; i++) {
      final left = prerelease[i];
      final right = other.prerelease[i];
      final leftNumeric = _numeric.hasMatch(left);
      final rightNumeric = _numeric.hasMatch(right);
      final result = leftNumeric && rightNumeric
          ? BigInt.parse(left).compareTo(BigInt.parse(right))
          : leftNumeric != rightNumeric
          ? (leftNumeric ? -1 : 1)
          : left.compareTo(right);
      if (result != 0) return result;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  @override
  String toString() => value;
}

/// Space-separated AND comparators: >=1.0.0 <2.0.0, =1.2.0, or *.
class PluginVersionConstraint {
  final String value;
  final List<(String, PluginVersion)> _comparators;
  const PluginVersionConstraint._(this.value, this._comparators);

  factory PluginVersionConstraint.parse(String value) {
    if (value.length > 1024 || value.trim().isEmpty) {
      _fail('Invalid version constraint: $value');
    }
    if (value.trim() == '*') return PluginVersionConstraint._(value, const []);
    final tokens = value.trim().split(RegExp(r'\s+'));
    if (tokens.length > 16) _fail('Too many version comparators');
    final comparators = <(String, PluginVersion)>[];
    for (final token in tokens) {
      final match = RegExp(r'^(>=|<=|>|<|=)?(.+)$').firstMatch(token);
      if (match == null) _fail('Invalid version comparator: $token');
      comparators.add((
        match.group(1) ?? '=',
        PluginVersion.parse(match.group(2)!),
      ));
    }
    return PluginVersionConstraint._(value, List.unmodifiable(comparators));
  }

  bool matches(String version) => allows(PluginVersion.parse(version));
  bool allows(PluginVersion version) => _comparators.every((comparator) {
    final result = version.compareTo(comparator.$2);
    return switch (comparator.$1) {
      '>=' => result >= 0,
      '<=' => result <= 0,
      '>' => result > 0,
      '<' => result < 0,
      _ => result == 0,
    };
  });
  @override
  String toString() => value;
}

typedef NodeDefinition = PluginNodeDefinition;
typedef PluginField = PluginFieldDefinition;

Never _fail(String message) => throw FormatException(message);
void _keys(Map<String, dynamic> value, Set<String> allowed, String path) {
  for (final key in value.keys) {
    if (!allowed.contains(key)) _fail('Unknown $path field: $key');
  }
}

Map<String, dynamic> _object(Object? value, String path) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    _fail('$path must be an object');
  }
  return Map<String, dynamic>.from(value);
}

List<dynamic> _list(Object? value, String path, {required int max}) {
  if (value is! List || value.length > max) {
    _fail('$path must be an array with at most $max entries');
  }
  return value;
}

String _text(
  Object? value,
  String path, {
  int max = 256,
  bool allowEmpty = false,
}) {
  if (value is! String ||
      value.length > max ||
      (!allowEmpty && value.trim().isEmpty) ||
      value.contains(String.fromCharCode(0))) {
    _fail('$path must be a valid string of at most $max characters');
  }
  return value;
}

bool _boolean(Object? value, String path) {
  if (value is! bool) _fail('$path must be a boolean');
  return value;
}

int _integer(Object? value, String path, {required int min, required int max}) {
  if (value is! int || value < min || value > max) {
    _fail('$path must be an integer between $min and $max');
  }
  return value;
}

num _finiteNumber(Object? value, String path) {
  if (value is! num || !value.isFinite) _fail('$path must be a finite number');
  return value;
}

int _exactInteger(num value, String path) {
  if (value is int) return value;
  // Doubles beyond the exact JSON integer range can clamp in toInt().
  if (!value.isFinite ||
      value.abs() > 9007199254740991 ||
      value != value.truncateToDouble()) {
    _fail('$path must be an exactly representable integer');
  }
  return value.toInt();
}

String _identifier(Object? value, String path) {
  final text = _text(value, path, max: 128);
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]*$').hasMatch(text)) {
    _fail('Invalid $path identifier');
  }
  return text;
}

String _pluginId(Object? value, String path) {
  final text = _text(value, path, max: 128);
  if (!RegExp(
    r'^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*[.][a-z0-9]+(?:[.-][a-z0-9]+)*$',
  ).hasMatch(text)) {
    _fail('$path must be a lowercase reverse domain identifier');
  }
  return text;
}

String _mediaType(Object? value, String path) {
  final text = _text(value, path);
  if (!const {'video', 'audio', 'image'}.contains(text)) {
    _fail('Unsupported media type in $path');
  }
  return text;
}

List<Map<String, dynamic>> _contributions(Object? value, String path) =>
    List.unmodifiable(
      _list(
        value,
        path,
        max: 64,
      ).map((entry) => _jsonCopy(_object(entry, path)) as Map<String, dynamic>),
    );
Object? _jsonCopy(Object? value, [int depth = 0]) {
  if (depth > 32) _fail('Plugin JSON nesting is too deep');
  if (value == null || value is bool || value is String) return value;
  if (value is num && value.isFinite) return value;
  if (value is List && value.length <= 10000) {
    return List.unmodifiable(value.map((entry) => _jsonCopy(entry, depth + 1)));
  }
  if (value is Map &&
      value.length <= 10000 &&
      value.keys.every((key) => key is String)) {
    return Map<String, dynamic>.unmodifiable(
      value.map(
        (key, entry) => MapEntry(key as String, _jsonCopy(entry, depth + 1)),
      ),
    );
  }
  _fail('Plugin contribution must contain bounded JSON values');
}
