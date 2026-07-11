import 'dart:async';
import 'dart:io';

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

  // Linux CPU 上一次采样值
  int _prevCpuTotal = 0;
  int _prevCpuIdle = 0;

  void start() {
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    await Future.wait([_updateCpuRam(), _updateGpu()]);
  }

  Future<void> _updateCpuRam() async {
    if (Platform.isWindows) {
      await _updateCpuRamWindows();
    } else {
      await _updateCpuRamLinux();
    }
  }

  Future<void> _updateGpu() async {
    if (Platform.isWindows) {
      await _updateGpuWindows();
    } else {
      await _updateGpuLinux();
    }
  }

  // ── Windows ──

  Future<void> _updateCpuRamWindows() async {
    try {
      final result = await Process.run('wmic', ['cpu', 'get', 'loadpercentage', '/value'], runInShell: true);
      for (final line in result.stdout.toString().split('\n')) {
        if (line.contains('LoadPercentage=')) {
          cpuPercent = double.tryParse(line.split('=').last.trim()) ?? 0;
        }
      }

      final ramResult = await Process.run('wmic', ['OS', 'get', 'FreePhysicalMemory,TotalVisibleMemorySize', '/value'], runInShell: true);
      double freeKB = 0, totalKB = 0;
      for (final line in ramResult.stdout.toString().split('\n')) {
        if (line.contains('FreePhysicalMemory=')) {
          freeKB = double.tryParse(line.split('=').last.trim()) ?? 0;
        }
        if (line.contains('TotalVisibleMemorySize=')) {
          totalKB = double.tryParse(line.split('=').last.trim()) ?? 0;
        }
      }
      if (totalKB > 0) {
        ramTotalGb = totalKB / 1024 / 1024;
        ramUsedGb = (totalKB - freeKB) / 1024 / 1024;
        ramPercent = ramUsedGb / ramTotalGb * 100;
      }
    } catch (_) {}
  }

  Future<void> _updateGpuWindows() async {
    try {
      final result = await Process.run('wmic', ['path', 'win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine', 'where', 'name like \'%3D\'', 'get', 'utilizationpercentage', '/value'], runInShell: true);
      double maxGpu = 0;
      for (final line in result.stdout.toString().split('\n')) {
        if (line.contains('UtilizationPercentage=')) {
          final val = double.tryParse(line.split('=').last.trim()) ?? 0;
          if (val > maxGpu) maxGpu = val;
        }
      }
      gpuPercent = maxGpu;

      if (!_gpuNameCached) {
        final nameResult = await Process.run('wmic', ['path', 'win32_VideoController', 'get', 'name', '/value'], runInShell: true);
        for (final line in nameResult.stdout.toString().split('\n')) {
          if (line.contains('Name=') && !line.contains('Name=Node')) {
            gpuName = line.split('=').last.trim();
            _gpuNameCached = true;
            break;
          }
        }
      }
    } catch (_) {}
  }

  // ── Linux ──

  Future<void> _updateCpuRamLinux() async {
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
        ramPercent = ramUsedGb / ramTotalGb * 100;
      }
    } catch (_) {}
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
}
