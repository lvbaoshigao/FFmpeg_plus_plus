import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

final _s = Platform.pathSeparator;

/// 启动完整性校验。
///
/// 设计要点（M-11）：
/// - 原实现只校验 3 张图片的 MD5，完全不覆盖真正决定行为的资产
///   （后端动态库、内置 ffmpeg/ffprobe、Dart 产物），安全价值几乎为零。
/// - 现在改为「多组资产 + 分组结果」：
///   * [verify] 校验图片等 UI 资产（缺一个即失败，阻止明显被篡改的资源）；
///   * [verifyCritical] 额外校验动态库与 ffmpeg/ffprobe 二进制。
/// - 失败策略：由调用方决定。[IntegrityCheck.lastFailure] 记录失败原因，
///   便于写日志/提示用户；不再只有 true/false 而无从定位。
class IntegrityCheck {
  /// UI 资源（相对 flutter_assets）。
  static const _expectedMd5 = {
    'icon.png': '5493df3e8d4afef9d6a479fd97715cb5',
    'wx.png': '1775d9410c7dc0679f64f9211c810979',
    'zfb.jpg': '405c5edd469221d63c56e9bb6d284387',
  };

  /// 上一次校验失败的原因（null 表示上次校验通过/尚未执行）。
  /// [FIX M-6] 注意：verify() 与 verifyCritical() 可能并发执行，二者都会写本字段。
  /// 为降低互相覆盖的影响，统一通过 [_setFailure] 写入（首次写入优先，不覆盖已记录失败）。
  static String? lastFailure;

  /// [FIX M-6] 写入失败原因：首次写入优先，不覆盖已记录的（可能更严重的）失败，
  /// 避免 verify() 与 verifyCritical() 并发执行时互相覆盖 [lastFailure]。
  static void _setFailure(String msg) {
    lastFailure ??= msg;
  }

  static Future<String?> _assetsDir() async {
    final exeDir = Directory(Platform.resolvedExecutable).parent;
    final candidates = [
      '${exeDir.path}${_s}data${_s}flutter_assets${_s}rele',
      '${exeDir.path}$_s..${_s}data${_s}flutter_assets${_s}rele',
      '${exeDir.path}$_s..$_s..${_s}data${_s}flutter_assets${_s}rele',
      // Android / iOS：直接从应用目录取资源
      '${exeDir.path}$_s',
    ];
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    return null;
  }

  /// 校验 UI 资源（向后兼容原行为，失败仍返回 false 但不抛异常）。
  static Future<bool> verify() async {
    try {
      final dir = await _assetsDir();
      if (dir == null) {
        _setFailure('未找到 flutter_assets 目录');  // [FIX M-6]
        return false;
      }
      for (final entry in _expectedMd5.entries) {
        final file = File('$dir$_s${entry.key}');
        if (!await file.exists()) {
          _setFailure('资源缺失: ${entry.key}');  // [FIX M-6]
          return false;
        }
        final bytes = await file.readAsBytes();
        final actual = md5.convert(bytes).toString();
        if (actual != entry.value) {
          _setFailure('资源被篡改: ${entry.key}');  // [FIX M-6]
          return false;
        }
      }
      // [FIX M-6] 通过时不置空 lastFailure：避免清掉并发执行的另一校验已写入的失败原因。
      // 调用方在 ok==true 时不会读取本字段，因此无需清零。
      return true;
    } catch (e) {
      _setFailure('校验异常: $e');  // [FIX M-6]
      return false;
    }
  }

  /// 校验关键可执行资产（后端动态库 + ffmpeg/ffprobe）。
  ///
  /// 注意：这些二进制随版本更新而变化，因此在没有可信基线（发布时生成的
  /// 清单文件）的情况下无法硬编码哈希。本方法做的是**存在性与基本健全性**
  /// 校验（文件存在、体积合理、非空），并把失败原因写入 [lastFailure]。
  /// 发布流水线若生成 `integrity.json`（路径 → sha256），本方法会自动升级为
  /// 逐项哈希比对。
  static Future<bool> verifyCritical() async {
    final targets = <String>[
      _backendLibName(),
      'ffmpeg${Platform.isWindows ? '.exe' : ''}',
      'ffprobe${Platform.isWindows ? '.exe' : ''}',
    ];
    try {
      final dirs = <String>{};
      final assets = await _assetsDir();
      if (assets != null) dirs.add(assets);
      // 后端库与 ffmpeg 通常与可执行文件同目录或其 data/ 子目录
      final exeDir = Directory(Platform.resolvedExecutable).parent;
      dirs
        ..add(exeDir.path)
        ..add('${exeDir.path}${_s}data');

      final manifest = await _loadManifest(exeDir.path);

      var missingCount = 0;
      final missingNames = <String>[];
      for (final name in targets) {
        File? found;
        for (final d in dirs) {
          final f = File('$d$_s$name');
          if (await f.exists()) {
            found = f;
            break;
          }
        }
        if (found == null) {
          // 内置 ffmpeg 允许缺失（用户可自行指定外部路径），仅记录，不直接失败
          missingCount++;  // [FIX M-6] 统计缺失数量，用于末尾语义判定
          missingNames.add(name);
          continue;
        }
        final len = await found.length();
        if (len == 0) {
          _setFailure('关键组件为空文件: $name');  // [FIX M-6] 仅在真正失败时写入
          return false;
        }
        // 有可信清单时做严格哈希比对
        final expected = manifest[found.uri.pathSegments.last];
        if (expected != null) {
          final actual = sha256.convert(await found.readAsBytes()).toString();
          if (actual != expected) {
            _setFailure('关键组件哈希不匹配: $name');  // [FIX M-6] 仅在真正失败时写入
            return false;
          }
        }
      }
      // [FIX M-6] 语义修正：三个关键组件「全部」缺失时关键校验应判失败。
      // 原实现会在循环里 continue 后返回 true，却留下失败串，调用方按返回值会误判
      // 为「关键组件 OK」。部分缺失（如仅 ffmpeg 缺失、用户已指定外部路径）仍视为通过。
      if (missingCount == targets.length) {
        _setFailure('关键组件全部缺失: ${missingNames.join('、')}');
        return false;
      }
      return true;
    } catch (e) {
      _setFailure('关键校验异常: $e');  // [FIX M-6]
      return false;
    }
  }

  /// 读取可选的 `integrity.json` 清单（{文件名: sha256}）。
  static Future<Map<String, String>> _loadManifest(String exeDir) async {
    try {
      final f = File('$exeDir${_s}integrity.json');
      if (!await f.exists()) return const {};
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return const {};
      final out = <String, String>{};
      raw.forEach((k, v) {
        if (v is String && v.length == 64) out['$k'] = v.toLowerCase();
      });
      return out;
    } catch (_) {
      return const {};
    }
  }

  static String _backendLibName() {
    if (Platform.isWindows) return 'ffmpegpp.dll';
    if (Platform.isMacOS) return 'libffmpegpp.dylib';
    return 'libffmpegpp.so';
  }
}
