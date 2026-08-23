import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../platform/app_platform.dart';

/// Android 原生能力桥接（通过 MainActivity 中的 MethodChannel 实现）：
/// - nativeLibraryDir：APK 内置 native 库目录（libffmpegpp.so 后端动态库所在）
/// - prepareBundledTool：从 assets 复制 ffmpeg/ffprobe 并 setExecutable
/// - wallpaperColors：系统壁纸颜色（Monet 动态取色的种子色）
///
/// ⚠️ ffmpeg/ffprobe 是静态可执行二进制，不能走 jniLibs：Android 安装器
/// 会把 .so 当共享库做 ELF 校验，ET_EXEC 静态二进制可能不被解压，导致
/// 子进程 exec 报 127。因此改成 assets 打包，由原生侧流式复制到应用文档
/// 目录并 setExecutable，返回副本路径供 C++ 后端与 UI 本地子进程调用。
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

  /// 内置 ffmpeg 可执行文件路径。ffmpeg 以「assets/ffmpeg」随 APK 打包
  /// （静态可执行文件不能走 jniLibs：Android 安装器对 .so 做 ELF 校验，
  /// ET_EXEC 静态二进制可能不被解压到 nativeLibraryDir，导致 exit 127）。
  /// 由原生侧从 assets 流式复制到应用文档目录并 setExecutable。失败返回 null。
  static Future<String?> bundledFfmpegPath() async {
    return _prepareFromAsset('ffmpeg', 'ffmpeg');
  }

  /// 内置 ffprobe 可执行文件路径（assets/ffprobe）。
  static Future<String?> bundledFfprobePath() async {
    return _prepareFromAsset('ffprobe', 'ffprobe');
  }

  /// 从 APK assets 复制内置工具到可执行目录并设置可执行位。
  /// 每次都重设可执行位，杜绝「首启复制/加可执行失败后缓存了不可执行副本」
  /// 的顽固 127（command not found / permission denied）。
  static Future<String?> _prepareFromAsset(String assetName, String name) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final binDir = Directory('${docsDir.path}${Platform.pathSeparator}ffmpegpp_bin');
      await binDir.create(recursive: true);
      final dest = File('${binDir.path}${Platform.pathSeparator}$name');
      final ok = await _prepareBundledTool(assetName, dest.path);
      return ok == true ? dest.path : null;
    } catch (_) {
      return null;
    }
  }

  /// 原生从 assets 复制内置工具并设置可执行位（Android 专用）。
  static Future<bool?> _prepareBundledTool(String assetName, String destPath) async {
    if (!isAndroidPlatform) return null;
    try {
      return await _channel.invokeMethod<bool>('prepareBundledTool', {
        'assetName': assetName,
        'destPath': destPath,
      });
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
