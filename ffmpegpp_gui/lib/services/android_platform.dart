import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../platform/app_platform.dart';

/// Android 原生能力桥接（通过 MainActivity 中的 MethodChannel 实现）：
/// - nativeLibraryDir：APK 内置 native 库目录
///   （libffmpegpp.so 后端动态库 + libffmpeg.so / libffprobe.so 可执行文件）
/// - wallpaperColors：系统壁纸颜色（Monet 动态取色的种子色）
///
/// ffmpeg/ffprobe 以「静态 PIE（ET_DYN，-static-pie）」打包在 jniLibs 里，
/// 安装时由 PackageManager 解压到 nativeLibraryDir（SELinux 标签 apk_data_file，
/// 允许 app exec）。这是 Android 10+（targetSdk ≥ 29）上唯一允许非特权应用
/// 执行二进制文件的目录（codeCacheDir / filesDir 均被 SELinux W^X 策略阻止）。
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

  /// 内置 ffmpeg 可执行文件路径：nativeLibraryDir/libffmpeg.so。
  /// 文件由 PackageManager 在安装时从 jniLibs 解压到此目录，无需运行时复制。
  /// 失败返回 null。
  static Future<String?> bundledFfmpegPath() => _bundledToolPath('libffmpeg.so');

  /// 内置 ffprobe 可执行文件路径：nativeLibraryDir/libffprobe.so。
  /// 文件由 PackageManager 在安装时从 jniLibs 解压到此目录，无需运行时复制。
  /// 失败返回 null。
  static Future<String?> bundledFfprobePath() => _bundledToolPath('libffprobe.so');

  /// 获取 nativeLibraryDir 中的工具路径，验证文件存在。
  /// 返回最终的可执行路径，失败返回 null。
  static Future<String?> _bundledToolPath(String soName) async {
    if (!isAndroidPlatform) return null;
    try {
      final libDir = await nativeLibraryDir();
      if (libDir == null || libDir.isEmpty) return null;
      final path = '$libDir${Platform.pathSeparator}$soName';
      if (await File(path).exists()) {
        return path;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 把 nativeLibraryDir 中的可执行工具（如 libffprobe.so / libffmpeg.so）
  /// 复制到应用私有二进制目录（filesDir/ffmpegpp_bin/）并 chmod 0755。
  ///
  /// 背景：MIUI / EMUI / ColorOS 等国产 ROM 会对 jniLibs 解压目录
  /// （nativeLibraryDir，SELinux 标签 apk_data_file）上的静态 PIE ELF 做
  /// 额外限制：直接 fork+exec 会触发 SIGSEGV(-11)。把二进制复制到
  /// filesDir（标签 app_data_file）的私有子目录后，可以在该目录下正常
  /// fork+exec 而不被拦截。这是 FFmpeg-Android / ffmpeg-kit 等主流方案
  /// 在 ROM 兼容上通用的兜底手段。
  ///
  /// 复制失败（如 IO 错误）返回 null；调用方应继续使用 nativeLibraryDir
  /// 原路径尝试，并在日志中告知用户实际生效的是哪条路径。
  static Future<String?> ensureExecutableInAppDir(String nativePath, {String? targetName}) async {
    if (!isAndroidPlatform || nativePath.isEmpty) return null;
    try {
      final src = File(nativePath);
      if (!await src.exists()) return null;

      final filesDir = await getApplicationSupportDirectory();
      final binDir = Directory('${filesDir.path}${Platform.pathSeparator}ffmpegpp_bin');
      if (!await binDir.exists()) await binDir.create(recursive: true);

      final name = targetName ??
          nativePath.split(RegExp(r'[\\/]')).last;
      final dest = File('${binDir.path}${Platform.pathSeparator}$name');

      // 已存在且大小一致：跳过复制（加快冷启动）。
      if (await dest.exists()) {
        final srcLen = await src.length();
        final dstLen = await dest.length();
        if (srcLen == dstLen && srcLen > 0) {
          await _chmodExecutable(dest.path);
          return dest.path;
        }
      }

      await src.copy(dest.path);
      await _chmodExecutable(dest.path);
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  /// 在 Android 上将文件设为可执行。dart:io 的 `Process.run` 走 Runtime.exec，
  /// 默认遵循文件权限位；所以这里依赖 libc 的 chmod 系统调用。
  /// 若因 SELinux / 沙箱导致 chmod 失败，不影响后续调用 execvp 会用 ENOENT 报错。
  static Future<void> _chmodExecutable(String path) async {
    try {
      await Process.run('chmod', ['755', path]);
    } catch (_) {}
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

  /// 申请必要的媒体读取权限：存储（读取视频/音频/图片）。
  /// Android 13+ 用 READ_MEDIA_* 分区权限，旧版本用 READ_EXTERNAL_STORAGE。
  /// 返回仍未授予的权限列表（空 = 已全部授予）；非 Android 返回空列表。
  static Future<List<String>> requestMediaPermissions() async {
    if (!isAndroidPlatform) return const [];
    try {
      final res = await _channel.invokeMethod<List<dynamic>>('requestMediaPermissions');
      return res?.map((e) => e.toString()).toList() ?? const [];
    } catch (_) {
      return const [];
    }
  }
}
