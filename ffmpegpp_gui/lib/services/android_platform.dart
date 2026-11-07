import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../platform/app_platform.dart';

/// Android 原生能力桥接（通过 MainActivity 中的 MethodChannel 实现）：
/// - nativeLibraryDir：APK 内置 native 库目录
///   （libffmpegpp.so 后端动态库 + libffmpeg.so / libffprobe.so 可执行文件）
/// - wallpaperColors：系统壁纸颜色（Monet 动态取色的种子色）
///
/// ffmpeg/ffprobe 以「动态 PIE（ET_DYN，带 PT_INTERP → /system/bin/linker64）」
/// 打包在 jniLibs 里，安装时由 PackageManager 解压到 nativeLibraryDir（SELinux
/// 标签 apk_data_file，允许 app exec）。这是 Android 10+（targetSdk ≥ 29）上
/// 唯一允许非特权应用执行二进制文件的目录。
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

  /// 发送「任务完成」系统通知。
  ///
  /// 澎湃 OS（HyperOS 3）上会自动以「小米超级岛」的形态展示；其它 ROM
  /// 退化为普通系统通知。原生侧见 `HyperOsIsland.kt`（含能力判定与
  /// `miui.focus.param` 组装）。失败静默 —— 通知从来不是关键路径。
  static Future<void> notifyTaskDone({
    required String title,
    required String body,
    required bool success,
  }) async {
    if (!isAndroidPlatform) return;
    try {
      await _channel.invokeMethod('notifyTaskDone', {
        'title': title,
        'body': body,
        'success': success,
      });
    } catch (_) {}
  }

  /// 超级岛能力状态：`{islandSupported, focusProtocolVersion, hasFocusPermission}`。
  /// 非 Android 或查询失败返回 null。
  static Future<Map<String, Object?>?> islandStatus() async {
    if (!isAndroidPlatform) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('islandStatus');
      return raw;
    } catch (_) {
      return null;
    }
  }

  /// ColorOS 流体云能力状态：`{colorOs, colorOsVersion, intentShareAvailable}`。
  /// 非 Android 或查询失败返回 null。原生侧见 `ColorOsFluidCloud.kt`。
  static Future<Map<String, Object?>?> fluidCloudStatus() async {
    if (!isAndroidPlatform) return null;
    try {
      return await _channel.invokeMapMethod<String, Object?>('fluidCloudStatus');
    } catch (_) {
      return null;
    }
  }

  /// 创建/刷新 ColorOS 流体云进度卡（设置项「允许将进度展示在流体云上」）。
  ///
  /// 调用方负责节流（见 `services/fluid_cloud_progress.dart`：≥1s + ≥2% 合并）；
  /// 创卡失败（无权限 / 开关关闭 / Provider 不可达）返回 false，静默放弃，
  /// 绝不影响任务本身。
  static Future<bool?> fluidCloudProgress({
    required String filename,
    required int progress,
  }) async {
    if (!isAndroidPlatform) return null;
    try {
      return await _channel.invokeMethod<bool>('fluidCloudProgress', {
        'filename': filename,
        'progress': progress,
      });
    } catch (_) {
      return null;
    }
  }

  /// 销毁流体云进度卡（队列空闲时调用；无卡时原生侧直接成功）。
  static Future<void> fluidCloudEnd() async {
    if (!isAndroidPlatform) return;
    try {
      await _channel.invokeMethod('fluidCloudEnd');
    } catch (_) {}
  }

  /// 创建/刷新小米「超级岛」进度通知（设置项「允许将进度展示在超级岛上」）。
  ///
  /// 调用方负责节流（见 `services/island_progress.dart`：≥1s + ≥2% 合并）；
  /// 发送失败（系统太旧 / 通知被拒）返回 false，静默放弃，绝不影响任务本身。
  static Future<bool?> islandProgress({
    required String filename,
    required int progress,
  }) async {
    if (!isAndroidPlatform) return null;
    try {
      return await _channel.invokeMethod<bool>('islandProgress', {
        'filename': filename,
        'progress': progress,
      });
    } catch (_) {
      return null;
    }
  }

  /// 销毁超级岛进度通知（队列空闲时调用；没发过卡时原生侧 cancel 也无害）。
  static Future<void> islandEnd() async {
    if (!isAndroidPlatform) return;
    try {
      await _channel.invokeMethod('islandEnd');
    } catch (_) {}
  }

  /// 发送一条「测试通知」，按当前系统自动选路，返回走了哪条：
  /// `'island'`（澎湃 OS 超级岛）/ `'fluidcloud'`（ColorOS 流体云）/
  /// `'notification'`（普通系统通知）/ `'unsupported'`（系统太旧或被拒绝）/
  /// `null`（非 Android 或调用失败）。
  ///
  /// ⚠️ 返回值只代表「选了哪条路」，不代表通知一定显示 —— MIUI/澎湃 OS 上
  /// 应用没进通知白名单或自启动白名单时会被静默丢弃，UI 侧据此给引导。
  static Future<String?> testNotification() async {
    if (!isAndroidPlatform) return null;
    try {
      return await _channel.invokeMethod<String>('testNotification');
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
  /// 背景：早前 ffmpeg/ffprobe 用 -static-pie 编成无 PT_INTERP 的静态 PIE，
  /// fork+exec 会在内核层直接 SIGSEGV(-11)（Android 7+ 要求可执行文件必须带
  /// PT_INTERP → /system/bin/linker64）。现已在 build_ffmpeg.sh 去掉 -static-pie、
  /// 改为动态 PIE，nativeLibraryDir 原路径即可 exec；本复制仅作为个别 ROM
  /// 意外拦截时的兜底。复制失败（如 IO 错误）返回 null；调用方应继续使用
  /// nativeLibraryDir 原路径并记录实际生效路径。
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

  /// 系统资源占用（CPU / 内存 / GPU），由原生侧采集：
  /// 内存走 ActivityManager（所有 ROM 可靠）；CPU 走 /proc/stat 差值；
  /// GPU 占用走 sysfs 探测、GPU 名称走临时 EGL 上下文。
  /// 数值型字段不可用时为 -1（UI 显示 "--"）；非 Android / 调用失败返回 null。
  static Future<Map<String, dynamic>?> systemStats() async {
    if (!isAndroidPlatform) return null;
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('systemStats');
      if (map == null) return null;
      double d(String k) {
        final v = map[k];
        return v is num ? v.toDouble() : -1.0;
      }
      return {
        'cpuPercent': d('cpuPercent'),
        'ramUsedGb': d('ramUsedGb'),
        'ramTotalGb': d('ramTotalGb'),
        'gpuPercent': d('gpuPercent'),
        'gpuName': map['gpuName']?.toString() ?? '',
      };
    } catch (_) {
      return null;
    }
  }
}
