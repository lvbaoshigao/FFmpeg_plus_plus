import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../platform/app_platform.dart';

/// Android 原生能力桥接（通过 MainActivity 中的 MethodChannel 实现）：
/// - nativeLibraryDir：APK 内置 native 库目录（libffmpegpp.so / libffmpeg.so / libffprobe.so 所在）
/// - wallpaperColors：系统壁纸颜色（Monet 动态取色的种子色）
///
/// ⚠️ 可执行文件问题：Android 10+ 把 APK 解压出的 native 库目录挂载为 noexec，
/// 直接从 `nativeLibraryDir/libffmpeg.so` exec 会得到 EACCES。
/// 因此 [bundledFfmpegPath] / [bundledFfprobePath] 会把二进制复制到应用私有
/// 缓存目录（可执行）并 chmod +x，返回副本路径——C++ 后端与 UI 本地调用
/// 都以子进程方式执行该副本。
class AndroidPlatformBridge {
  static const MethodChannel _channel = MethodChannel('ffmpegpp/android');

  /// APK 内置 native 库目录。非 Android 或调用失败返回 null。
  static Future<String?> nativeLibraryDir() async {
    if (!isAndroidPlatform) return null;
    try {
      return await _channel.invokeMethod<String>('nativeLibraryDir');
    } catch (_) {
      return null;
    }
  }

  /// 内置 ffmpeg 可执行文件路径（jniLibs 中命名为 libffmpeg.so），
  /// 已复制到可执行目录并 chmod +x。失败返回 null。
  static Future<String?> bundledFfmpegPath() async {
    final dir = await nativeLibraryDir();
    if (dir == null) return null;
    return _ensureExecutableCopy('$dir/libffmpeg.so', 'ffmpeg');
  }

  /// 内置 ffprobe 可执行文件路径（jniLibs 中命名为 libffprobe.so），
  /// 已复制到可执行目录并 chmod +x。失败返回 null。
  static Future<String?> bundledFfprobePath() async {
    final dir = await nativeLibraryDir();
    if (dir == null) return null;
    return _ensureExecutableCopy('$dir/libffprobe.so', 'ffprobe');
  }

  /// 把 native 库目录中的可执行二进制复制到应用文档目录（保证可执行），
  /// 避免 Android 10+ noexec 导致的 exec 失败。用元数据文件判断是否需要重新复制
  /// （APK 升级后 nativeLibraryDir 路径会变，路径不一致即重新复制）。
  static Future<String?> _ensureExecutableCopy(String src, String name) async {
    try {
      final srcFile = File(src);
      if (!await srcFile.exists()) return null;
      // 使用应用文档目录（非 systemTemp），避免部分 ROM 的 cache 目录挂载为 noexec
      final docsDir = await getApplicationDocumentsDirectory();
      final binDir = Directory('${docsDir.path}${Platform.pathSeparator}ffmpegpp_bin');
      await binDir.create(recursive: true);
      final dest = File('${binDir.path}${Platform.pathSeparator}$name');
      final meta = File('${binDir.path}${Platform.pathSeparator}$name.meta');

      // 元数据记录源路径与大小：一致则复用副本，避免每次启动重新复制几十 MB
      try {
        if (await dest.exists() && await meta.exists()) {
          final metaText = (await meta.readAsString()).trim();
          final srcLen = await srcFile.length();
          if (metaText == '$src|$srcLen') return dest.path;
        }
      } catch (_) {}

      await dest.writeAsBytes(await srcFile.readAsBytes());
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', dest.path]);
      }
      await meta.writeAsString('$src|${await srcFile.length()}');
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  /// 把导入的媒体文件复制到应用文档目录（持久、app 私有、可执行/可读），
  /// 保留原扩展名，保证 ffprobe/fork 子进程能稳定读取。
  ///
  /// 背景：file_picker 在 Android 上会把 SAF 选中的 content:// 缓存到
  /// cacheDir/file_picker/...，该目录可被系统在存储压力下清空，部分 ROM 下
  /// 还可能出现子进程无法访问缓存目录的情况，导致 ffprobe 报「无法读取文件，
  /// 请检查路径或文件权限」。复制到应用文档目录彻底规避这一类权限问题。
  /// 复制失败时原样返回 [src]，让后续探测给出具体错误，而不静默丢弃文件。
  static Future<String> ensureReadableImport(String src) async {
    try {
      final srcFile = File(src);
      if (!await srcFile.exists()) return src;

      final docsDir = await getApplicationDocumentsDirectory();
      final importDir = Directory(
          '${docsDir.path}${Platform.pathSeparator}ffmpegpp_imports');
      await importDir.create(recursive: true);

      final name = src.split(RegExp(r'[\\/]')).last;
      final dot = name.lastIndexOf('.');
      final ext = (dot > 0 && dot < name.length - 1)
          ? name.substring(dot)
          : '';
      final stem =
          name.substring(0, dot > 0 ? dot : name.length);
      final safeStem = stem.replaceAll(RegExp(r'[^A-Za-z0-9\u4e00-\u9fa5]'), '_');
      final dest = File('${importDir.path}${Platform.pathSeparator}'
          '${safeStem}_${DateTime.now().millisecondsSinceEpoch}$ext');

      // 用 copy 而非 readAsBytes+writeAsBytes：大文件走流式拷贝，不占内存
      await srcFile.copy(dest.path);
      return dest.path;
    } catch (_) {
      return src;
    }
  }

  /// 系统壁纸主色（ARGB int），Android 8.1+ (API 27+) 可用。
  /// 非 Android / 低版本 / 调用失败返回 null（回退到用户主题色）。
  static Future<int?> wallpaperPrimaryColor() async {
    if (!isAndroidPlatform) return null;
    try {
      final map =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('wallpaperColors');
      final v = map?['primary'];
      return v is int ? v : null;
    } catch (_) {
      return null;
    }
  }
}
