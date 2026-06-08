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
    try {
      // 用 WMIC 查询 CPU 和内存
      final cpuResult = await Process.run('wmic', ['cpu', 'get', 'loadpercentage', '/value'], runInShell: true);
      final ramResult = await Process.run('wmic', ['OS', 'get', 'FreePhysicalMemory,TotalVisibleMemorySize', '/value'], runInShell: true);

      // 解析 CPU
      for (final line in cpuResult.stdout.toString().split('\n')) {
        if (line.contains('LoadPercentage=')) {
          final val = line.split('=').last.trim();
          cpuPercent = double.tryParse(val) ?? 0;
        }
      }

      // 解析内存 (KB → GB)
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

  Future<void> _updateGpu() async {
    try {
      // 用 WMIC 查询 GPU 负载
      final result = await Process.run('wmic', ['path', 'win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine', 'where', 'name like \'%3D\'', 'get', 'utilizationpercentage', '/value'], runInShell: true);
      double maxGpu = 0;
      for (final line in result.stdout.toString().split('\n')) {
        if (line.contains('UtilizationPercentage=')) {
          final val = double.tryParse(line.split('=').last.trim()) ?? 0;
          if (val > maxGpu) maxGpu = val;
        }
      }
      gpuPercent = maxGpu;

      // 获取 GPU 名称
      if (gpuName.isEmpty) {
        final nameResult = await Process.run('wmic', ['path', 'win32_VideoController', 'get', 'name', '/value'], runInShell: true);
        for (final line in nameResult.stdout.toString().split('\n')) {
          if (line.contains('Name=') && !line.contains('Name=Node')) {
            gpuName = line.split('=').last.trim();
            break;
          }
        }
      }
    } catch (_) {}
  }
}
