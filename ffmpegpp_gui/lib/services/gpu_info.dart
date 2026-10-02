import 'dart:io';

/// GPU 型号探测 + 软件渲染判定。
///
/// 用途：启动时自动降级玻璃效果。BackdropFilter 高斯模糊依赖 GPU 光栅化，
/// 在软件渲染环境（llvmpipe / Microsoft Basic Render Driver / 远程桌面
/// 基础显示适配器）上整个 UI 会非常卡。检测到这类环境后自动把玻璃效果
/// 切到 'none'（无玻璃），保证流畅；用户可在设置中手动重新开启。
///
/// 探测策略（全部一次性 + 缓存，失败静默）：
///  - Windows：优先 nvidia-smi（~50ms，无 NVIDIA 时直接失败），
///    失败再走一次 CIM 查询（1~3s，后台执行不阻塞启动）
///  - Linux：glxinfo（未安装则放弃，不强制安装）
///  - macOS / 移动端：不探测（直接返回 null，保持现状）
class GpuInfo {
  GpuInfo._();

  static String? _cachedName;
  static Future<String?>? _inflight;

  /// GPU 型号名；探测不到返回 null
  static Future<String?> detectName() {
    final cached = _cachedName;
    if (cached != null) return Future.value(cached);
    final running = _inflight;
    if (running != null) return running;
    _inflight = _detect();
    return _inflight!;
  }

  static Future<String?> _detect() async {
    try {
      String? name;
      if (Platform.isWindows) {
        final nvidia = await Process.run(
            'nvidia-smi', ['--query-gpu=name', '--format=csv,noheader,nounits']);
        if (nvidia.exitCode == 0) {
          name = nvidia.stdout.toString().trim().split('\n').first;
        } else {
          final cim = await Process.run('powershell',
              ['-NoProfile', '-Command', r'(Get-CimInstance Win32_VideoController).Name']);
          if (cim.exitCode == 0) {
            name = cim.stdout.toString().trim().split('\n').first;
          }
        }
      } else if (Platform.isLinux) {
        final glx = await Process.run(
            'glxinfo', ['-B'],
            runInShell: true);
        final line = glx.stdout.toString().split('\n').firstWhere(
            (l) => l.contains('OpenGL renderer string'),
            orElse: () => '');
        name = line.split(':').last.trim();
      }
      // 空结果不缓存（下次启动可重试），避免临时故障永久屏蔽检测
      if (name != null && name.isNotEmpty) _cachedName = name;
      return name;
    } catch (_) {
      return null;
    }
  }

  /// 是否为软件/基础渲染器（玻璃模糊在这些环境下极慢，应自动降级）
  static bool isSoftwareRendered(String? name) {
    if (name == null || name.isEmpty) return false;
    final n = name.toLowerCase();
    return n.contains('basic render') ||
        n.contains('basic display adapter') ||
        n.contains('llvmpipe') ||
        n.contains('swrast') ||
        n.contains('microsoft remote desktop');
  }
}
