import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ffmpegpp_gui/models/models.dart';
import 'package:ffmpegpp_gui/plugins/plugin_contributions.dart';
import 'package:ffmpegpp_gui/plugins/plugin_manifest.dart';
import 'package:ffmpegpp_gui/plugins/plugin_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SDK manifests pass actual host models and contributions',
    () async {
      for (final example in ['audio-gain', 'video-flip', 'theme-ai']) {
        final source = File('../plugin_sdk/examples/$example/manifest.json');
        final manifest = PluginManifest.fromJson(
          jsonDecode(await source.readAsString()) as Map<String, dynamic>,
        );
        manifest.validateCompatibility('6.0.0-beta2');
        final config = AppConfig();
        for (final theme in manifest.themes) {
          final preset = PluginThemePreset.fromJson(theme);
          expect(preset.preview(config), isNotEmpty);
        }
        for (final data in manifest.aiConfigs) {
          final catalog = PluginAiCatalog.fromJson(data);
          final plan = catalog.preview(config);
          expect(plan.newProfileCount, 1);
          expect(plan.mergedProfileCount, 0);
          final applied = plan.applyTo(config);
          expect(applied.aiProfiles.last.enabled, isFalse);
          expect(applied.aiProfiles.last.apiKey, isEmpty);
        }
      }
    },
  );

  test('SDK ZIP exports every source asset byte for byte', () async {
    final zipBytes = await PluginSdk.createArchive();
    expect(zipBytes, isNotEmpty);
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final root = Directory.current.path;
    final sdk = Directory('$root/../plugin_sdk');
    final index = jsonDecode(
      await File('$root/assets/plugin_sdk/files.json').readAsString(),
    ) as List<dynamic>;
    expect(archive.files.map((file) => file.name).toSet(), index.toSet());
    for (final name in index.cast<String>()) {
      final file = archive.findFile(name);
      expect(file, isNotNull, reason: name);
      expect(
        file!.content,
        await File('${sdk.path}/$name').readAsBytes(),
        reason: name,
      );
    }
    expect(archive.findFile('include/ffmpegpp_plugin.h'), isNotNull);
    expect(archive.findFile('examples/audio-gain/plugin.c'), isNotNull);
    expect(archive.findFile('examples/video-flip/plugin.c'), isNotNull);
    expect(archive.findFile('tools/build_plugin.py'), isNotNull);
    expect(archive.findFile('schema/manifest.schema.json'), isNotNull);
    expect(PluginSdk.archiveFileName, endsWith('.zip'));
  });
}
