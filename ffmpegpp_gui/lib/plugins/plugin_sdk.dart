import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Exports the same versioned SDK sources used to build the bundled example.
abstract final class PluginSdk {
  static const archiveFileName = 'ffmpegpp-plugin-sdk-v1.zip';
  static const _assetRoot = 'assets/plugin_sdk/';

  /// Creates a ZIP containing headers, schemas, build tools and example sources.
  ///
  /// Asset loading, malformed SDK indexes and ZIP encoding failures are surfaced
  /// to the caller so the UI can show its existing export-error treatment.
  static Future<Uint8List> createArchive() async {
    final index = jsonDecode(
      await rootBundle.loadString('${_assetRoot}files.json'),
    );
    if (index is! List || index.isEmpty) {
      throw const FormatException(
        'Plugin SDK asset index must be a nonempty list.',
      );
    }
    final archive = Archive();
    final seen = <String>{};
    for (final item in index) {
      if (item is! String ||
          item.isEmpty ||
          item.startsWith('/') ||
          item.contains('\\') ||
          item
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..') ||
          !seen.add(item)) {
        throw const FormatException(
          'Invalid or duplicate Plugin SDK asset path.',
        );
      }
      // Flat Flutter asset directory; ZIP entries retain their SDK subdirectories.
      final asset = item.replaceAll('/', '__');
      final data = await rootBundle.load('$_assetRoot$asset');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      archive.addFile(ArchiveFile(item, bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}
