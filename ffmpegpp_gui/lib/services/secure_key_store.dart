import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// API Key 本地加密存储。
///
/// 目的：避免 API Key 以明文写入 settings.json（会随备份/同步/打包日志泄露）。
/// 实现：HMAC-SHA256 作为 PRF 的 CTR 式流加密，密钥由固定应用密钥 + 机器指纹
///       （主机名 + 用户主目录的哈希）派生；密文以 `enc:` 前缀的 base64 存储，
///       并向后兼容旧版明文（`decrypt` 对无前缀的明文原样返回）。
///
/// 版本化：v1 = `enc:`（旧，派生算法保持稳定以保证已存 Key 可解）；v2 = `enc2:`
///       （新，指纹采集多熵源 + 持久随机盐，强度更高）。`decrypt` 按前缀选算法，
///       任一前缀解密失败均记 debugPrint 并返回空串（保持调用方 String 语义）。
///
/// 安全边界：这是可逆的「静态混淆」——能阻止明文读取与跨机器直接解码，
/// 但不能抵御能读取本机可执行文件/内存的恶意程序。若需强安全，请改用系统
/// 密钥链（flutter_secure_storage 对应 Keychain / DPAPI / Android Keystore）。
class SecureKeyStore {
  static const String prefix = 'enc:'; // v1
  static const String prefixV2 = 'enc2:'; // [FIX L-2] v2 新前缀
  static const String _appSecret = 'ffmpegpp.ai-key-store.v1';
  static const String _saltFileName = 'ffmpegpp_key_salt.bin';

  /// [FIX L-1] 持久化随机盐（首次运行生成并写入磁盘，后续复用）。
  /// 用系统临时目录（同步可用，Android 亦可读写），作为多设备/安装间的唯一熵源——
  /// 即便所有环境变量熵源都为空（Android 常见），也能靠它保证盐的唯一性。
  static String? _persistedSalt;

  static String get _persistedSaltValue {
    if (_persistedSalt != null) return _persistedSalt!;
    _persistedSalt = _loadOrCreatePersistedSalt();
    return _persistedSalt!;
  }

  static String _loadOrCreatePersistedSalt() {
    try {
      final dir = Directory.systemTemp;
      final file = File('${dir.path}${Platform.pathSeparator}$_saltFileName');
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        if (bytes.isNotEmpty) return base64Encode(bytes);
      }
      // 首次运行：生成 32 字节安全随机盐并落盘
      final rnd = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      file.writeAsBytesSync(rnd);
      return base64Encode(rnd);
    } catch (_) {
      // 落盘失败仅本次进程有效（重启后变化），但至少仍是一份随机盐
      return base64Encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    }
  }

  /// 机器指纹 v1：换机器/换用户后密钥无法再解码（回退为需重新输入，而非明文泄露）。
  /// 注意：该派生结果必须保持稳定，否则已存的 `enc:` 数据会在升级后无法解密
  /// （静默丢 Key）。v2 的增强指纹见 [_saltV2]，两者前缀隔离、互不干扰。
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

  /// [FIX L-1] 机器指纹 v2：采集多个熵源（主机名、HOME/USERPROFILE、USER/USERNAME、
  /// 操作系统、持久化随机盐）拼接后再哈希，显著增强 Android 上的盐唯一性。
  static String get _saltV2 {
    try {
      final host = Platform.localHostname;
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      final user = Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          '';
      final os = Platform.operatingSystem;
      // 多熵源拼接；Android 上 HOME/USER 多为空，此时依赖持久化随机盐保证唯一
      final seed = '$host|$home|$user|$os|$_persistedSaltValue';
      return sha256.convert(utf8.encode(seed)).toString();
    } catch (_) {
      // 兜底：只剩持久化随机盐（多设备/安装间唯一）
      return sha256.convert(utf8.encode(_persistedSaltValue)).toString();
    }
  }

  /// v1 派生（与旧版本完全一致，专供 `enc:` 数据解密，保证已存 Key 可用）
  static List<int> _deriveKeyV1() {
    final hmac = Hmac(sha256, utf8.encode(_appSecret));
    return hmac.convert(utf8.encode(_salt)).bytes; // 32 字节
  }

  /// [FIX L-1/L-2] v2 派生，使用增强指纹
  static List<int> _deriveKeyV2() {
    final hmac = Hmac(sha256, utf8.encode(_appSecret));
    return hmac.convert(utf8.encode(_saltV2)).bytes; // 32 字节
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

  /// [FIX L-2] 新加密统一使用 v2 算法 + `enc2:` 前缀
  static String encrypt(String plaintext) {
    if (plaintext.isEmpty) return '';
    // 已是密文（v1 或 v2 前缀）则原样返回，避免重复加密
    if (plaintext.startsWith(prefix) || plaintext.startsWith(prefixV2)) {
      return plaintext;
    }
    final rnd = Random.secure();
    final iv = List<int>.generate(16, (_) => rnd.nextInt(256));
    final data = utf8.encode(plaintext);
    final key = _deriveKeyV2();
    final ks = _keystream(key, iv, data.length);
    final enc = List<int>.generate(data.length, (i) => data[i] ^ ks[i]);
    return '$prefixV2${base64Encode(iv)}:${base64Encode(enc)}';
  }

  static String decrypt(String stored) {
    if (stored.isEmpty) return '';
    if (stored.startsWith(prefixV2)) {
      return _decryptWith(stored, prefixV2, _deriveKeyV2());
    }
    if (stored.startsWith(prefix)) {
      // 旧 `enc:` 数据：用 v1 派生（兼容既有密钥，勿改否则已存 Key 失效）
      return _decryptWith(stored, prefix, _deriveKeyV1());
    }
    return stored; // 旧版明文兼容，直接返回
  }

  /// 通用解密；失败时记 debugPrint 并返回空串（保持调用方 String 语义，避免空指针）。
  static String _decryptWith(String stored, String usedPrefix, List<int> key) {
    final body = stored.substring(usedPrefix.length);
    final parts = body.split(':');
    if (parts.length != 2) {
      debugPrint('[SecureKeyStore] 密文格式异常，无法解密（前缀 $usedPrefix）');
      return '';
    }
    try {
      final iv = base64Decode(parts[0]);
      final enc = base64Decode(parts[1]);
      final ks = _keystream(key, iv, enc.length);
      final data = List<int>.generate(enc.length, (i) => enc[i] ^ ks[i]);
      return utf8.decode(data);
    } catch (_) {
      // 换机/损坏等原因无法解码时返回空，避免把密文/乱码暴露到 UI，用户重新输入即可
      debugPrint('[SecureKeyStore] 解密失败（前缀 $usedPrefix），可能已换机或数据损坏');
      return '';
    }
  }
}
