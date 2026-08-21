import 'dart:io';
import 'package:archive/archive.dart';
import 'shell_open.dart';

const _ffmpegLanzouUrl = 'https://wwbrq.lanzouv.com/iTF9n3sb937c';
const _ffprobeLanzouUrl = 'https://wwbrq.lanzouv.com/itEOt3t5yogh';

class FfmpegInstaller {
  static String get _appDir => Directory(Platform.resolvedExecutable).parent.path;
  static String get ffmpegPath => Platform.isWindows
      ? '$_appDir${Platform.pathSeparator}ffmpeg.exe'
      : '$_appDir${Platform.pathSeparator}ffmpeg';
  static String get ffprobePath => Platform.isWindows
      ? '$_appDir${Platform.pathSeparator}ffprobe.exe'
      : '$_appDir${Platform.pathSeparator}ffprobe';

  static bool get isInstalled => File(ffmpegPath).existsSync() && File(ffprobePath).existsSync();

  /// 解析实际可用的 ffmpeg 可执行路径（供 UI 层的预览/缩略图等本地调用使用）。
  /// 优先级：用户配置的 [configured] 路径 → 程序目录内置二进制 → PATH 上的 `ffmpeg`。
  /// 之前各处硬编码 `'ffmpeg'`，导致通过「内置安装」装好 FFmpeg、但没装进 PATH 的用户，
  /// 缩略图/预览/截取全部静默失败。
  /// Android 上无 PATH 概念：AppState 初始化时把内置 ffmpeg 路径注入 [configuredFfmpeg]。
  static String configuredFfmpeg = '';
  static String resolveFfmpeg({String? configured}) {
    final cfg = (configured ?? configuredFfmpeg).trim();
    if (cfg.isNotEmpty && File(cfg).existsSync()) return cfg;
    if (File(ffmpegPath).existsSync()) return ffmpegPath;
    return 'ffmpeg';
  }

  static Future<bool> checkSystemFfmpeg() async {
    try {
      final r = await Process.run('ffmpeg', ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // ── Linux/macOS 包管理器安装 ──

  static (String, List<String>) _detectPackageManager() {
    if (Platform.isMacOS) {
      if (File('/opt/homebrew/bin/brew').existsSync() || File('/usr/local/bin/brew').existsSync()) {
        return ('brew', ['install', 'ffmpeg']);
      }
      throw Exception('未检测到 Homebrew，请先安装: https://brew.sh');
    }
    if (File('/usr/bin/apt').existsSync()) return ('apt', ['install', '-y', 'ffmpeg']);
    if (File('/usr/bin/dnf').existsSync()) return ('dnf', ['install', '-y', 'ffmpeg']);
    if (File('/usr/bin/pacman').existsSync()) return ('pacman', ['-S', '--noconfirm', 'ffmpeg']);
    throw Exception('未检测到支持的包管理器 (apt/dnf/pacman)');
  }

  static Future<void> installViaPackageManager({
    required void Function(String status) onStatus,
    required void Function(double progress) onProgress,
  }) async {
    final (cmd, args) = _detectPackageManager();
    onStatus('正在通过 $cmd 安装 FFmpeg...');
    onProgress(0.1);

    late Process process;
    if (Platform.isMacOS) {
      process = await Process.start(cmd, args);
    } else {
      // pkexec 并非所有发行版都预装（Ubuntu 23.10+/Debian 12+），失败时回退到 sudo
      try {
        process = await Process.start('pkexec', [cmd, ...args]);
      } catch (_) {
        try {
          process = await Process.start('sudo', [cmd, ...args]);
        } catch (_) {
          throw Exception('需要 root 权限安装 FFmpeg，但未找到 pkexec 或 sudo。手动安装: sudo $cmd ${args.join(' ')}');
        }
      }
    }

    process.stdout.transform(const SystemEncoding().decoder).listen((line) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) onStatus(trimmed);
    });

    process.stderr.transform(const SystemEncoding().decoder).listen((line) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) onStatus(trimmed);
    });

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw Exception('$cmd 安装失败 (exit code: $exitCode)\n手动安装: sudo $cmd ${args.join(' ')}');
    }

    onProgress(0.8);
    onStatus('正在验证...');
    final ok = await checkSystemFfmpeg();
    if (!ok) {
      throw Exception('安装完成但 FFmpeg 验证失败');
    }
    onStatus('安装完成！');
    onProgress(1.0);
  }

  // ── Winget 安装 ──

  static Future<void> installViaWinget({
    required void Function(String status) onStatus,
    required void Function(double progress) onProgress,
    required void Function(bool slow) onSpeedWarning,
  }) async {
    onStatus('正在通过 winget 安装 FFmpeg...');
    onProgress(0.1);

    final process = await Process.start('winget', [
      'install', 'Gyan.FFmpeg', '--accept-source-agreements', '--accept-package-agreements',
    ], runInShell: true);

    final sw = Stopwatch()..start();
    var progressVal = 0.1;

    process.stdout.transform(const SystemEncoding().decoder).listen((line) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) onStatus(trimmed);
      final m = RegExp(r'(\d+)%').firstMatch(trimmed);
      if (m != null) {
        progressVal = int.parse(m.group(1)!) / 100;
        onProgress(progressVal);
      }
    });

    process.stderr.transform(const SystemEncoding().decoder).listen((line) {
      if (line.trim().isNotEmpty) onStatus(line.trim());
    });

    Future.delayed(const Duration(seconds: 30), () {
      if (sw.isRunning && progressVal < 0.3) onSpeedWarning(true);
    });

    final exitCode = await process.exitCode;
    sw.stop();

    if (exitCode == 0) {
      onStatus('winget 安装完成');
      onProgress(1.0);
    } else {
      throw Exception('winget 安装失败 (exit code: $exitCode)');
    }
  }

  // ── 蓝奏云（浏览器下载 + 手动导入）──

  static Future<void> openLanzouInBrowser({
    required void Function(String status) onStatus,
  }) async {
    onStatus('正在打开浏览器下载 ffmpeg...');
    await _openUrl(_ffmpegLanzouUrl);
    await Future.delayed(const Duration(seconds: 2));
    onStatus('正在打开浏览器下载 ffprobe...');
    await _openUrl(_ffprobeLanzouUrl);
    onStatus('已打开浏览器，请手动下载两个压缩包后点击"导入"');
  }

  static Future<void> _openUrl(String url) => ShellOpen.url(url);

  static Future<void> importFromZips({
    required String ffmpegZipPath,
    required String ffprobeZipPath,
    required void Function(String status) onStatus,
    required void Function(double progress) onProgress,
  }) async {
    onStatus('正在解压 ffmpeg...');
    onProgress(0.3);
    final ffmpegExeName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final ffprobeExeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    await _extractExeFromZip(ffmpegZipPath, ffmpegExeName, ffmpegPath);
    onStatus('正在解压 ffprobe...');
    onProgress(0.7);
    await _extractExeFromZip(ffprobeZipPath, ffprobeExeName, ffprobePath);
    // 验证提取的二进制是否可正常运行
    onStatus('正在验证...');
    onProgress(0.9);
    if (!await verifyInstalled()) {
      uninstall();
      throw Exception('提取的 FFmpeg 二进制无法正常运行，已删除');
    }
    onStatus('安装完成！');
    onProgress(1.0);
  }

  static Future<void> _extractExeFromZip(String zipPath, String targetName, String destPath) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      // 解压炸弹防护：拒绝超大的解压条目（ffmpeg 二进制合理上限 512MB）
      if (file.isFile && file.size > 512 * 1024 * 1024) {
        throw Exception('ZIP 条目过大 (${file.name}): ${(file.size / 1024 / 1024).toStringAsFixed(0)}MB');
      }
      if (file.isFile && file.name.toLowerCase().endsWith(targetName.toLowerCase())) {
        // 安全检查：拒绝包含路径穿越的 ZIP 条目
        if (file.name.contains('..')) {
          throw Exception('ZIP 条目包含不安全路径: ${file.name}');
        }
        final content = file.content as List<int>;
        await File(destPath).writeAsBytes(content);
        // POSIX 平台（macOS/Linux）：提取的二进制需要可执行权限，
        // 否则运行 ffmpeg -version 会 Permission denied。
        if (!Platform.isWindows) {
          await Process.run('chmod', ['+x', destPath]);
        }
        // 提取后验证：文件大小应大于 1MB（合理的 ffmpeg 二进制下限）
        final extractedSize = content.length;
        if (extractedSize < 1024 * 1024) {
          await File(destPath).delete();
          throw Exception('$targetName 文件大小异常 ($extractedSize 字节)，已拒绝');
        }
        return;
      }
    }
    throw Exception('ZIP 中未找到 $targetName');
  }

  /// 验证已安装的 ffmpeg/ffprobe 是否可正常运行
  static Future<bool> verifyInstalled() async {
    try {
      final ffResult = await Process.run(ffmpegPath, ['-version']);
      final fpResult = await Process.run(ffprobePath, ['-version']);
      return ffResult.exitCode == 0 && fpResult.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static void uninstall() {
    try { if (File(ffmpegPath).existsSync()) File(ffmpegPath).deleteSync(); } catch (_) {}
    try { if (File(ffprobePath).existsSync()) File(ffprobePath).deleteSync(); } catch (_) {}
  }
}
