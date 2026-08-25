import 'dart:async';
import 'dart:io';

import 'android_platform.dart';

/// 实时系统监控：CPU / 内存 / GPU 使用率
class SystemMonitor {
  double cpuPercent = 0;
  double ramUsedGb = 0;
  double ramTotalGb = 0;
  double ramPercent = 0;
  String gpuName = '';
  double gpuPercent = 0;

  Timer? _timer;
  bool _gpuNameCached = false;
  bool _busy = false;  // 防止 2s 周期内前一轮未完成时重叠执行

  // Linux CPU 上一次采样值
  int _prevCpuTotal = 0;
  int _prevCpuIdle = 0;

  void start() {
    _tick();
    // 首次采样只建立了 baseline（prev 值），CPU 百分比从第二次采样才有意义。
    // 立即再采一次，让 UI 首次渲染就能看到真实数值。
    Future.delayed(const Duration(milliseconds: 120), () => _tick());
    Future.delayed(const Duration(milliseconds: 400), () => _tick());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      if (Platform.isAndroid) {
        await _updateAndroid();
      } else {
        await Future.wait([_updateCpuRam(), _updateGpu()]);
      }
    } finally {
      _busy = false;
    }
  }

  /// Android：通过原生 MethodChannel 一次取回 CPU / 内存 / GPU（含 GPU 名称）。
  /// - 内存走 ActivityManager，所有 ROM 都可靠（dart:io 读 /proc/meminfo 在
  ///   部分 ROM 上会被 SELinux 拦截）；
  /// - CPU 走原生侧 /proc/stat 差值，GPU 走 sysfs 探测 + EGL 读型号；
  /// - 通道不可用（如热重载后旧进程）时回退到 /proc 读取，能读到什么算什么。
  Future<void> _updateAndroid() async {
    final stats = await AndroidPlatformBridge.systemStats();
    if (stats == null) {
      await _updateCpuRamLinux();
      return;
    }
    cpuPercent = stats['cpuPercent'] as double;
    ramUsedGb = stats['ramUsedGb'] as double;
    ramTotalGb = stats['ramTotalGb'] as double;
    ramPercent = (ramTotalGb > 0 && ramUsedGb >= 0)
        ? (ramUsedGb / ramTotalGb * 100).clamp(0, 100)
        : -1;
    gpuPercent = stats['gpuPercent'] as double;
    final name = stats['gpuName'] as String;
    if (name.isNotEmpty) gpuName = name;
  }

  Future<void> _updateCpuRam() async {
    if (Platform.isWindows) {
      await _updateCpuRamWindows();
    } else if (Platform.isMacOS) {
      await _updateCpuRamMacOS();
    } else {
      await _updateCpuRamLinux();
    }
  }

  Future<void> _updateGpu() async {
    // Android 无 nvidia-smi/lspci，每次尝试都白启动一个失败进程；直接跳过
    if (Platform.isAndroid) return;
    if (Platform.isWindows) {
      await _updateGpuWindows();
    } else if (Platform.isMacOS) {
      await _updateGpuMacOS();
    } else {
      await _updateGpuLinux();
    }
  }

  // ── Windows ──

  Future<void> _updateCpuRamWindows() async {
    try {
      // 合并 CPU + 内存为一次 powershell 调用（原来每次 2 个进程，每 2 秒一次）
      final result = await Process.run('powershell', ['-NoProfile', '-Command',
        r'$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Maximum).Maximum; $os = Get-CimInstance Win32_OperatingSystem; Write-Output "$cpu,$($os.FreePhysicalMemory),$($os.TotalVisibleMemorySize)"'], runInShell: true);
      final parts = result.stdout.toString().trim().split(',');
      if (parts.length >= 3) {
        cpuPercent = double.tryParse(parts[0]) ?? 0;
        final freeKB = double.tryParse(parts[1]) ?? 0;
        final totalKB = double.tryParse(parts[2]) ?? 0;
        if (totalKB > 0) {
          ramTotalGb = totalKB / 1024 / 1024;
          ramUsedGb = (totalKB - freeKB) / 1024 / 1024;
          ramPercent = ramUsedGb / ramTotalGb * 100;
        }
      }
    } catch (_) {}
  }

  Future<void> _updateGpuWindows() async {
    try {
      final result = await Process.run('powershell', ['-NoProfile', '-Command',
        r'(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | Where-Object { $_.Name -like "*3D*" } | Measure-Object -Property UtilizationPercentage -Maximum).Maximum'], runInShell: true);
      gpuPercent = double.tryParse(result.stdout.toString().trim()) ?? 0;

      if (!_gpuNameCached) {
        final nameResult = await Process.run('powershell', ['-NoProfile', '-Command',
          r'(Get-CimInstance Win32_VideoController).Name'], runInShell: true);
        final name = nameResult.stdout.toString().trim();
        if (name.isNotEmpty) {
          gpuName = name.split('\n').first.trim();
          _gpuNameCached = true;
        }
      }
    } catch (_) {}
  }

  // ── Linux ──

  Future<void> _updateCpuRamLinux() async {
    // CPU 与内存独立容错：部分 Android ROM 用 SELinux 拦截 /proc/stat，
    // 不能让 CPU 读取失败把本可正常读取的 /proc/meminfo 也拖成 -1。
    await _readCpuLinux();
    await _readRamLinux();
  }

  Future<void> _readCpuLinux() async {
    try {
      // CPU: 解析 /proc/stat
      final statContent = await File('/proc/stat').readAsString();
      final cpuLine = statContent.split('\n').firstWhere((l) => l.startsWith('cpu '), orElse: () => '');
      if (cpuLine.isNotEmpty) {
        final parts = cpuLine.split(RegExp(r'\s+')).skip(1).map((s) => int.tryParse(s) ?? 0).toList();
        if (parts.length >= 4) {
          final total = parts.fold(0, (a, b) => a + b);
          final idle = parts[3];
          final totalDiff = total - _prevCpuTotal;
          final idleDiff = idle - _prevCpuIdle;
          if (totalDiff > 0 && _prevCpuTotal > 0) {
            cpuPercent = ((totalDiff - idleDiff) / totalDiff * 100).clamp(0, 100);
          }
          _prevCpuTotal = total;
          _prevCpuIdle = idle;
        }
      }
    } catch (_) {
      // 读取失败（Android 上 /proc/stat 可能被 SELinux 拦截）：
      // 标记 -1，UI 显示 "--" 而非误导性的 0%。
      cpuPercent = -1;
    }
  }

  Future<void> _readRamLinux() async {
    try {
      // 内存: 解析 /proc/meminfo
      final memContent = await File('/proc/meminfo').readAsString();
      double totalKB = 0, availKB = 0;
      for (final line in memContent.split('\n')) {
        if (line.startsWith('MemTotal:')) {
          totalKB = double.tryParse(line.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        } else if (line.startsWith('MemAvailable:')) {
          availKB = double.tryParse(line.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        }
      }
      if (totalKB > 0) {
        ramTotalGb = totalKB / 1024 / 1024;
        ramUsedGb = (totalKB - availKB) / 1024 / 1024;
        if (ramUsedGb < 0) ramUsedGb = 0;
        ramPercent = ramUsedGb / ramTotalGb * 100;
      } else {
        // /proc/meminfo 读取失败（部分 ROM/SELinux 限制）：标记不可用
        ramTotalGb = -1;
        ramUsedGb = -1;
      }
    } catch (_) {
      ramTotalGb = -1;
      ramUsedGb = -1;
    }
  }

  Future<void> _updateGpuLinux() async {
    try {
      // 尝试 nvidia-smi
      final result = await Process.run('nvidia-smi', [
        '--query-gpu=utilization.gpu,name',
        '--format=csv,noheader,nounits',
      ]);
      if (result.exitCode == 0) {
        final line = result.stdout.toString().trim().split('\n').first;
        final parts = line.split(',').map((s) => s.trim()).toList();
        if (parts.isNotEmpty) {
          gpuPercent = double.tryParse(parts[0]) ?? 0;
        }
        if (!_gpuNameCached && parts.length > 1) {
          gpuName = parts[1];
          _gpuNameCached = true;
        }
        return;
      }
    } catch (_) {}

    // nvidia-smi 不可用时，尝试读取 sysfs
    if (!_gpuNameCached) {
      try {
        final result = await Process.run('lspci', []);
        if (result.exitCode == 0) {
          for (final line in result.stdout.toString().split('\n')) {
            if (line.contains('VGA') || line.contains('3D controller')) {
              gpuName = line.split(':').last.trim();
              _gpuNameCached = true;
              break;
            }
          }
        }
      } catch (_) {}
    }
  }

  // ── macOS ──

  Future<void> _updateCpuRamMacOS() async {
    try {
      final result = await Process.run('top', ['-l', '1', '-n', '0', '-s', '0']);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        // CPU usage: parse "CPU usage: X% user, Y% sys, Z% idle"
        final cpuMatch = RegExp(r'(\d+\.?\d*)% idle').firstMatch(output);
        if (cpuMatch != null) {
          cpuPercent = (100.0 - (double.tryParse(cpuMatch.group(1)!) ?? 0)).clamp(0.0, 100.0).toDouble();
        }
        // Memory: parse "PhysMem: XXG used (YYM wired, ZZM compressor), AAG unused."
        final memMatch = RegExp(r'PhysMem:\s+(\d+\.?\d*)\w?\s+used.*?(\d+\.?\d*)\w?\s+unused').firstMatch(output);
        if (memMatch != null) {
          ramUsedGb = double.tryParse(memMatch.group(1)!) ?? 0;
          final unused = double.tryParse(memMatch.group(2)!) ?? 0;
          ramTotalGb = ramUsedGb + unused;
          if (ramTotalGb > 0) ramPercent = ramUsedGb / ramTotalGb * 100;
        }
      }
    } catch (_) {}
  }

  Future<void> _updateGpuMacOS() async {
    if (_gpuNameCached) return;
    try {
      final result = await Process.run('system_profiler', ['SPDisplaysDataType']);
      if (result.exitCode == 0) {
        final match = RegExp(r'Chipset Model:\s*(.+)').firstMatch(result.stdout.toString());
        if (match != null) {
          gpuName = match.group(1)!.trim();
          _gpuNameCached = true;
        }
      }
    } catch (_) {}
  }
}
