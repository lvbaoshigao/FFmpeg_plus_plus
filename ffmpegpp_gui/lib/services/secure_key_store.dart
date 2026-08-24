import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// API Key 本地加密存储。
///
/// 目的：避免 API Key 以明文写入 settings.json（会随备份/同步/打包日志泄露）。
/// 实现：HMAC-SHA256 作为 PRF 的 CTR 式流加密，密钥由固定应用密钥 + 机器指纹
///       （主机名 + 用户主目录的哈希）派生；密文以 `enc:` 前缀的 base64 存储，
///       并向后兼容旧版明文（`decrypt` 对无前缀的明文原样返回）。
///
/// 安全边界：这是可逆的「静态混淆」——能阻止明文读取与跨机器直接解码，
/// 但不能抵御能读取本机可执行文件/内存的恶意程序。若需强安全，请改用系统
/// 密钥链（flutter_secure_storage 对应 Keychain / DPAPI / Android Keystore）。
class SecureKeyStore {
  static const String prefix = 'enc:';
  static const String _appSecret = 'ffmpegpp.ai-key-store.v1';

  /// 机器指纹：换机器/换用户后密钥无法再解码（回退为需重新输入，而非明文泄露）。
  static String get _salt {
    try {
      final host = Platform.localHostname;
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      final seed = '$host|$home';
      return sha256.convert(utf8.encode(seed)).toString();
    } catch (_) {
      return 'ffmpegpp-fallback-salt';
    }
  }

  static List<int> _deriveKey() {
    final hmac = Hmac(sha256, utf8.encode(_appSecret));
    return hmac.convert(utf8.encode(_salt)).bytes; // 32 字节
  }

  static List<int> _keystream(List<int> key, List<int> iv, int length) {
    final out = <int>[];
    var counter = 0;
    while (out.length < length) {
      final input = <int>[...iv];
      // 4 字节大端计数器（CTR 模式）
      input.addAll([
        (counter >> 24) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 8) & 0xff,
        counter & 0xff,
      ]);
      out.addAll(Hmac(sha256, key).convert(input).bytes);
      counter++;
    }
    return out.sublist(0, length);
  }

  static String encrypt(String plaintext) {
    if (plaintext.isEmpty) return '';
    if (plaintext.startsWith(prefix)) return plaintext; // 已是密文，避免重复加密
    final rnd = Random.secure();
    final iv = List<int>.generate(16, (_) => rnd.nextInt(256));
    final data = utf8.encode(plaintext);
    final key = _deriveKey();
    final ks = _keystream(key, iv, data.length);
    final enc = List<int>.generate(data.length, (i) => data[i] ^ ks[i]);
    return '$prefix${base64Encode(iv)}:${base64Encode(enc)}';
  }

  static String decrypt(String stored) {
    if (stored.isEmpty) return '';
    if (!stored.startsWith(prefix)) return stored; // 旧版明文兼容，直接返回
    final body = stored.substring(prefix.length);
    final parts = body.split(':');
    if (parts.length != 2) return '';
    try {
      final iv = base64Decode(parts[0]);
      final enc = base64Decode(parts[1]);
      final key = _deriveKey();
      final ks = _keystream(key, iv, enc.length);
      final data = List<int>.generate(enc.length, (i) => enc[i] ^ ks[i]);
      return utf8.decode(data);
    } catch (_) {
      // 换机/损坏等原因无法解码时返回空，避免把密文/乱码暴露到 UI，用户重新输入即可
      return '';
    }
  }
}