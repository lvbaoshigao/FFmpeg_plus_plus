import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Reads keys written by the former settings-file obfuscation format.
///
/// This is only used while migrating old settings into the platform keychain.
class LegacyAiKeyDecoder {
  LegacyAiKeyDecoder._();

  static const _prefixV1 = 'enc:';
  static const _prefixV2 = 'enc2:';
  static const _appSecret = 'ffmpegpp.ai-key-store.v1';
  static const _saltFileName = 'ffmpegpp_key_salt.bin';

  static String decode(String stored) {
    if (stored.isEmpty ||
        (!stored.startsWith(_prefixV1) && !stored.startsWith(_prefixV2))) {
      return stored;
    }

    final prefix = stored.startsWith(_prefixV2) ? _prefixV2 : _prefixV1;
    try {
      final parts = stored.substring(prefix.length).split(':');
      if (parts.length != 2) {
        throw const FormatException('Invalid legacy key format.');
      }
      final salt = prefix == _prefixV1 ? _saltV1 : _saltV2;
      final key = Hmac(
        sha256,
        utf8.encode(_appSecret),
      ).convert(utf8.encode(salt)).bytes;
      final iv = base64Decode(parts[0]);
      final encrypted = base64Decode(parts[1]);
      final stream = _keystream(key, iv, encrypted.length);
      return utf8.decode([
        for (var i = 0; i < encrypted.length; i++) encrypted[i] ^ stream[i],
      ]);
    } catch (error) {
      debugPrint(
        '[LegacyAiKeyDecoder] Could not migrate a legacy AI key: $error',
      );
      return '';
    }
  }

  static String get _saltV1 {
    final host = Platform.localHostname;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return sha256.convert(utf8.encode('$host|$home')).toString();
  }

  static String get _saltV2 {
    final saltFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}$_saltFileName',
    );
    if (!saltFile.existsSync()) {
      throw const FileSystemException('Legacy key salt is unavailable.');
    }
    final persistedSalt = base64Encode(saltFile.readAsBytesSync());
    final host = Platform.localHostname;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final user =
        Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? '';
    final seed = '$host|$home|$user|${Platform.operatingSystem}|$persistedSalt';
    return sha256.convert(utf8.encode(seed)).toString();
  }

  static List<int> _keystream(List<int> key, List<int> iv, int length) {
    final result = <int>[];
    var counter = 0;
    while (result.length < length) {
      final input = <int>[
        ...iv,
        (counter >> 24) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 8) & 0xff,
        counter & 0xff,
      ];
      result.addAll(Hmac(sha256, key).convert(input).bytes);
      counter++;
    }
    return result.sublist(0, length);
  }
}
