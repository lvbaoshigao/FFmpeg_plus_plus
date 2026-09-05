import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'android_platform.dart';
import 'gpu_info.dart';

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
  //
  // 内存/CPU 优化：此前每 2 秒启动 2 个 powershell.exe（CPU/内存 + GPU 各一，
  // 其中 GPU 的 CIM 查询单次要 1~3 秒）。每次 PowerShell 启动都是几十 MB 的
  // 子进程 + 秒级 CPU 占用，长期运行下是内存与电量的隐形大户。
  // 现在 CPU/内存直接走 kernel32 FFI（GetSystemTimes / GlobalMemoryStatusEx，
  // 微秒级、零子进程）；GPU 型号只在首次用一次 CIM 查询并缓存，占用率优先
  // 用 nvidia-smi（几十毫秒），拿不到时显示 "--"，不再每 2 秒空转一个慢查询。

  // CPU 时间基线（FILETIME 100ns 刻，自 1601 年起）
  int _wPrevIdle = 0;
  int _wPrevTotal = 0;

  // FFI 绑定（late final 惰性初始化：仅 Windows 路径首次访问时才加载
  // kernel32，其它平台构造 SystemMonitor 不会触发加载失败）
  late final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  late final int Function(Pointer<Int32>, Pointer<Int32>, Pointer<Int32>) _getSystemTimes =
      _kernel32.lookupFunction<
          Int32 Function(Pointer<Int32>, Pointer<Int32>, Pointer<Int32>),
          int Function(Pointer<Int32>, Pointer<Int32>, Pointer<Int32>)>(
          'GetSystemTimes');
  late final int Function(Pointer<_MemoryStatusEx>) _globalMemoryStatusEx =
      _kernel32.lookupFunction<
          Int32 Function(Pointer<_MemoryStatusEx>),
          int Function(Pointer<_MemoryStatusEx>)>(
          'GlobalMemoryStatusEx');

  /// FILETIME（2×DWORD）→ 100ns 刻度 64 位整数
  int _fileTime64(Pointer<Int32> p) =>
      (p[1].toUnsigned(32) << 32) | p[0].toUnsigned(32);

  Future<void> _updateCpuRamWindows() async {
    try {
      final idle = calloc<Int32>(2);
      final kernel = calloc<Int32>(2);
      final user = calloc<Int32>(2);
      try {
        if (_getSystemTimes(idle, kernel, user) == 0) return;
        final idleT = _fileTime64(idle);
        final totalT = _fileTime64(kernel) + _fileTime64(user);
        final dTotal = totalT - _wPrevTotal;
        final dIdle = idleT - _wPrevIdle;
        _wPrevIdle = idleT;
        _wPrevTotal = totalT;
        if (dTotal > 0 && _wPrevTotal > 0) {
          cpuPercent = (100.0 * (1 - dIdle / dTotal)).clamp(0.0, 100.0);
        }
      } finally {
        calloc.free(idle);
        calloc.free(kernel);
        calloc.free(user);
      }

      final ms = calloc<_MemoryStatusEx>();
      try {
        ms.ref.dwLength = sizeOf<_MemoryStatusEx>();
        if (_globalMemoryStatusEx(ms) != 0) {
          ramTotalGb = ms.ref.ullTotalPhys / 1073741824;
          ramUsedGb = (ms.ref.ullTotalPhys - ms.ref.ullAvailPhys) / 1073741824;
          ramPercent = ms.ref.dwMemoryLoad.toDouble();
        }
      } finally {
        calloc.free(ms);
      }
    } catch (_) {}
  }

  bool _gpuQueryUnavailable = false;

  Future<void> _updateGpuWindows() async {
    // GPU 型号：仅首次查询一次（GpuInfo 内部：nvidia-smi 优先，失败走一次
    // CIM；结果全局缓存，启动时的低配检测与这里共用同一次探测）
    if (!_gpuNameCached) {
      final name = await GpuInfo.detectName();
      if (name != null && name.isNotEmpty) {
        gpuName = name;
        _gpuNameCached = true;
      }
    }
    if (_gpuQueryUnavailable) {
      gpuPercent = -1; // UI 显示 "--"（非 NVIDIA 显卡或无 nvidia-smi）
      return;
    }
    try {
      final result = await Process.run('nvidia-smi',
          ['--query-gpu=utilization.gpu', '--format=csv,noheader,nounits']);
      if (result.exitCode == 0) {
        gpuPercent =
            double.tryParse(result.stdout.toString().trim().split('\n').first) ??
                -1;
      } else {
        // nvidia-smi 不存在/不可用：不再反复尝试，占用率显示 "--"
        _gpuQueryUnavailable = true;
        gpuPercent = -1;
      }
    } catch (_) {
      _gpuQueryUnavailable = true;
      gpuPercent = -1;
    }
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

/// Win32 MEMORYSTATUSEX 结构（kernel32!GlobalMemoryStatusEx）
final class _MemoryStatusEx extends Struct {
  @Int32()
  external int dwLength;
  @Uint16()
  external int dwMemoryLoad;
  @Uint64()
  external int ullTotalPhys;
  @Uint64()
  external int ullAvailPhys;
  @Uint64()
  external int ullTotalPageFile;
  @Uint64()
  external int ullAvailPageFile;
  @Uint64()
  external int ullTotalVirtual;
  @Uint64()
  external int ullAvailVirtual;
}
