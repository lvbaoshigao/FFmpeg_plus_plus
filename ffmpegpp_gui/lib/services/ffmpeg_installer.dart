import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const _ffmpegLanzouUrl = 'https://wwbrq.lanzouv.com/iTF9n3sb937c';
const _ffprobeLanzouUrl = 'https://wwbrq.lanzouv.com/itEOt3t5yogh';

class FfmpegInstaller {
  static String get _appDir => Directory(Platform.resolvedExecutable).parent.path;
  static String get ffmpegPath => '$_appDir${Platform.pathSeparator}ffmpeg.exe';
  static String get ffprobePath => '$_appDir${Platform.pathSeparator}ffprobe.exe';

  static bool get isInstalled => File(ffmpegPath).existsSync() && File(ffprobePath).existsSync();

  static Future<bool> checkSystemFfmpeg() async {
    try {
      final r = await Process.run('ffmpeg', ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
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
    await Process.run('cmd', ['/c', 'start', '', _ffmpegLanzouUrl]);
    await Future.delayed(const Duration(seconds: 2));
    onStatus('正在打开浏览器下载 ffprobe...');
    await Process.run('cmd', ['/c', 'start', '', _ffprobeLanzouUrl]);
    onStatus('已打开浏览器，请手动下载两个压缩包后点击"导入"');
  }

  static Future<void> importFromZips({
    required String ffmpegZipPath,
    required String ffprobeZipPath,
    required void Function(String status) onStatus,
    required void Function(double progress) onProgress,
  }) async {
    onStatus('正在解压 ffmpeg...');
    onProgress(0.3);
    await _extractExeFromZip(ffmpegZipPath, 'ffmpeg.exe', ffmpegPath);
    onStatus('正在解压 ffprobe...');
    onProgress(0.7);
    await _extractExeFromZip(ffprobeZipPath, 'ffprobe.exe', ffprobePath);
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
      if (file.isFile && file.name.toLowerCase().endsWith(targetName.toLowerCase())) {
        // 安全检查：拒绝包含路径穿越的 ZIP 条目
        if (file.name.contains('..')) {
          throw Exception('ZIP 条目包含不安全路径: ${file.name}');
        }
        final content = file.content as List<int>;
        await File(destPath).writeAsBytes(content);
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
