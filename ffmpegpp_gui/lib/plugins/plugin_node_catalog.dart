import 'plugin_manifest.dart';

class PluginNodeCatalogEntry {
  final String pluginId;
  final String pluginVersion;
  final PluginNodeDefinition definition;
  const PluginNodeCatalogEntry({
    required this.pluginId,
    required this.pluginVersion,
    required this.definition,
  });
  String get nodeId => definition.id;
}

/// Live, enabled plugin declarations. A saved graph snapshot never enters here.
/// PluginManager owns publication; its ChangeNotifier delivers UI invalidation.
class PluginNodeCatalog {
  static final PluginNodeCatalog instance = PluginNodeCatalog();
  Map<String, PluginManifest> _plugins = const {};
  List<PluginNodeCatalogEntry> _entries = const [];
  int _revision = 0;

  int get revision => _revision;
  List<PluginNodeCatalogEntry> get entries => _entries;
  List<PluginNodeCatalogEntry> get availableNodes => _entries;

  PluginManifest? plugin(String pluginId) => _plugins[pluginId];

  PluginNodeDefinition? lookup(String pluginId, String nodeId) {
    final nodes = _plugins[pluginId]?.nodes;
    if (nodes == null) return null;
    for (final node in nodes) {
      if (node.id == nodeId) return node;
    }
    return null;
  }

  bool isAvailable(
    String pluginId,
    String nodeId, {
    String? version,
    int? schemaVersion,
  }) {
    final manifest = plugin(pluginId);
    final definition = lookup(pluginId, nodeId);
    return manifest != null &&
        definition != null &&
        (version == null || version == manifest.version) &&
        (schemaVersion == null || schemaVersion == definition.schemaVersion);
  }

  /// Publishes a validated snapshot of enabled plugins atomically.
  void replaceAll(Iterable<PluginManifest> enabled) {
    final next = <String, PluginManifest>{};
    final entries = <PluginNodeCatalogEntry>[];
    for (final source in enabled) {
      final manifest = PluginManifest.fromJson(source.toJson());
      if (next.containsKey(manifest.id)) {
        throw FormatException('Duplicate catalog plugin: ${manifest.id}');
      }
      next[manifest.id] = manifest;
      entries.addAll(
        manifest.nodes.map(
          (definition) => PluginNodeCatalogEntry(
            pluginId: manifest.id,
            pluginVersion: manifest.version,
            definition: definition,
          ),
        ),
      );
    }
    _plugins = Map.unmodifiable(next);
    _entries = List.unmodifiable(entries);
    _revision++;
  }

  void publish(Iterable<PluginManifest> enabled) => replaceAll(enabled);
  void clear() => replaceAll(const []);
}
