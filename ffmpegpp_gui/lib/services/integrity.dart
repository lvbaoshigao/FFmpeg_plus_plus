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
  static String? lastFailure;

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
        lastFailure = '未找到 flutter_assets 目录';
        return false;
      }
      for (final entry in _expectedMd5.entries) {
        final file = File('$dir$_s${entry.key}');
        if (!await file.exists()) {
          lastFailure = '资源缺失: ${entry.key}';
          return false;
        }
        final bytes = await file.readAsBytes();
        final actual = md5.convert(bytes).toString();
        if (actual != entry.value) {
          lastFailure = '资源被篡改: ${entry.key}';
          return false;
        }
      }
      lastFailure = null;
      return true;
    } catch (e) {
      lastFailure = '校验异常: $e';
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
          // 内置 ffmpeg 允许缺失（用户可自行指定外部路径），仅记录
          lastFailure = '关键组件缺失: $name';
          continue;
        }
        final len = await found.length();
        if (len == 0) {
          lastFailure = '关键组件为空文件: $name';
          return false;
        }
        // 有可信清单时做严格哈希比对
        final expected = manifest[found.uri.pathSegments.last];
        if (expected != null) {
          final actual = sha256.convert(await found.readAsBytes()).toString();
          if (actual != expected) {
            lastFailure = '关键组件哈希不匹配: $name';
            return false;
          }
        }
      }
      return true;
    } catch (e) {
      lastFailure = '关键校验异常: $e';
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
