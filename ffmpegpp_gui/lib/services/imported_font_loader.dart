import 'dart:io';

import 'package:flutter/services.dart';

/// Registers only custom fonts actually selected by the application.
///
/// Flutter retains registered font faces for the engine lifetime. Keeping the
/// unopened font directory out of FontLoader avoids permanently retaining every
/// imported font on startup. The loader itself never caches font bytes.
final class ImportedFontLoader {
  ImportedFontLoader({
    Future<void> Function(String family, Uint8List bytes)? register,
  }) : _register = register ?? _registerFont;

  final Future<void> Function(String, Uint8List) _register;
  final Set<String> _loaded = {};
  final Map<String, Future<bool>> _pending = {};

  Future<bool> ensureLoaded(String family, Iterable<Directory> directories) {
    if (family.isEmpty ||
        family.contains('/') ||
        family.contains(String.fromCharCode(92)) ||
        family == '.' ||
        family == '..') {
      return Future.value(false);
    }
    if (_loaded.contains(family)) return Future.value(true);
    return _pending[family] ??= _load(family, directories).whenComplete(() {
      // Do not return the pending Future: waiting on itself would deadlock.
      _pending.remove(family);
    });
  }

  Future<bool> _load(String family, Iterable<Directory> directories) async {
    for (final directory in directories) {
      for (final extension in const ['ttf', 'otf']) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}$family.$extension',
        );
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        await _register(family, bytes);
        _loaded.add(family);
        return true;
      }
    }
    return false;
  }

  static Future<void> _registerFont(String family, Uint8List bytes) async {
    final loader = FontLoader(family);
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}
