import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../services/native_process.dart';
import '../services/backend_client.dart';
import '../services/config_service.dart';
import '../services/graph_executor.dart';
import '../services/ffmpeg_installer.dart';
import '../services/android_platform.dart';
import '../platform/app_platform.dart';

class AppState extends ChangeNotifier {
  /// 共享随机数生成器：避免随机参数生成时每处 new Random()，
  /// 否则同一毫秒内多次实例化会因时间种子相同而退化为固定偏移的伪随机序列。
  static final Random _rng = Random();
  final NativeProcessManager pythonProcess = NativeProcessManager();
  late final BackendClient backend = BackendClient(pythonProcess);
  final ConfigService configService = ConfigService();

  void Function(String filename, TaskStatus status)? onTaskFinished;

  bool _envChecked = false, _envOk = false;
  String _ffmpegVersion = '', _initError = '';
  bool get envChecked => _envChecked;
  bool get envOk => _envOk;
  String get ffmpegVersion => _ffmpegVersion;
  String get initError => _initError;

  final List<VideoFile> _videos = [];
  List<VideoFile> get videos => List.unmodifiable(_videos);
  int _probeCount = 0;
  bool get probingVideos => _probeCount > 0;
  final Map<String, String> _probeErrors = {};
  Map<String, String> get probeErrors => Map.unmodifiable(_probeErrors);

  final List<TaskInfo> _tasks = [];
  List<TaskInfo> get tasks => List.unmodifiable(_tasks);
  final Set<String> _runningTaskIds = {};
  bool get processing => _runningTaskIds.isNotEmpty;
  String? _currentTaskId;
  // 取消标记：cancelProcessing 置位后，正在途中的任务完成/失败回调不得覆盖
  // cancelled 状态，processNextTask 也不得继续拉取 pending 任务。
  bool _cancelRequested = false;
  // 单个任务取消：cancelTask 只取消指定任务（不触碰全局 _cancelRequested），
  // 多任务并发时其余任务继续执行。
  final Set<String> _cancelledTaskIds = {};
  // 每个任务正在运行的本地 ffmpeg 进程（供 cancelTask 只终止该任务名下的进程）
  final Map<String, List<Process>> _localProcessesByTask = {};

  // ── Log entries ──
  final List<LogEntry> _logEntries = [];
  // 日志内存上限：长任务期间 stderr 逐行入队会无界增长，超出后丢弃最旧
  static const int _maxLogEntries = 2000;
  bool _logNotifyPending = false;
  // 日志目录探测缓存（避免每条日志同步 existsSync/createSync）
  String? _logDirReadyFor;
  List<LogEntry> get logEntries => List.unmodifiable(_logEntries);
  void addLog(String message, {String category = 'general'}) {
    // 调试模式关闭时，仅保留 error 和 progress 类日志（不主动记录非关键日志）
    if (!config.debugMode && category != 'error' && category != 'progress') return;

    _logEntries.add(LogEntry(timestamp: DateTime.now(), message: message, category: category));
    if (_logEntries.length > _maxLogEntries) {
      _logEntries.removeRange(0, _logEntries.length - _maxLogEntries);
    }
    if (config.saveLogs && config.logSavePath.isNotEmpty) {
      _writeLogToFile(message, category);
    }
    // Progress logs notify immediately for real-time UI updates
    if (category == 'progress') {
      notifyListeners();
      return;
    }
    // Other logs batch via microtask to prevent UI blocking
    if (!_logNotifyPending) {
      _logNotifyPending = true;
      scheduleMicrotask(() {
        _logNotifyPending = false;
        notifyListeners();
      });
    }
  }
  void clearLogs() { _logEntries.clear(); notifyListeners(); }

  /// 日志文件串行化写入链（异步，避免阻塞 UI 且防止交错写坏文件）
  Future<void>? _logWriteInFlight;
  void _writeLogToFile(String message, String category) {
    try {
      final dir = Directory(config.logSavePath);
      // 目录存在性只需探测一次（路径变化时重新探测）
      if (_logDirReadyFor != config.logSavePath) {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        _logDirReadyFor = config.logSavePath;
      }
      final date = DateTime.now();
      final file = File('${dir.path}${Platform.pathSeparator}ffmpegpp_${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}.log');
      final ts = date.toIso8601String().substring(11, 23);
      final line = '[$ts][$category] $message\n';
      // 原 writeAsStringSync 每次打开-写入-关闭阻塞 UI；改为异步串行追加
      _logWriteInFlight = (_logWriteInFlight ?? Future<void>.value()).then((_) async {
        try {
          await file.writeAsString(line, mode: FileMode.append);
        } catch (_) {}
      });
    } catch (_) {
      // 目录创建失败等：重置缓存，下次重试
      _logDirReadyFor = null;
    }
  }

  // ── FFmpeg features ──
  Map<String, List<String>> _ffmpegFeatures = {};
  Map<String, List<String>> get ffmpegFeatures => _ffmpegFeatures;
  bool get featuresDetected => _ffmpegFeatures.isNotEmpty;
  Future<void> queryFeatures() async {
    addLog('正在查询 FFmpeg 支持的功能...', category: 'info');
    final resp = await backend.queryFeatures();
    if (resp['success'] == true) {
      final data = resp['data'];
      if (data is Map<String, dynamic>) {
        _ffmpegFeatures = data.map((k, v) => MapEntry(k, v is List ? v.whereType<String>().toList() : const <String>[]));
        addLog('功能查询完成: ${_ffmpegFeatures.keys.join(', ')}', category: 'info');
      } else {
        addLog('功能查询失败: 返回数据格式异常', category: 'error');
      }
    } else {
      addLog('功能查询失败: ${resp['error']}', category: 'error');
    }
    notifyListeners();
  }

  AppConfig get config => configService.config;
  bool get darkMode => config.darkMode;
  int _selectedNav = 0;
  int get selectedNav => _selectedNav;

  bool _initialized = false;
  bool get initialized => _initialized;

  Future<void> init(String serverScript) async {
    debugPrint('[init] 1-configService.load');
    await configService.load();
    debugPrint('[init] 2-configService.load done');
    notifyListeners(); // 让 UI 用上 config 里的主题
    try {
      debugPrint('[init] 3-calling pythonProcess.start($serverScript)');
      await pythonProcess.start(serverScript);
      debugPrint('[init] 4-pythonProcess.start done, isRunning=${pythonProcess.isRunning}');
    } catch (e) {
      debugPrint('[init] 4-ERROR: $e');
      _initError = 'Python backend failed: $e';
      _envChecked = true; _envOk = false; _initialized = true; notifyListeners(); return;
    }
    try {
      debugPrint('[init] 5-waiting for ready...');
      final ready = await pythonProcess.waitForReady(timeout: const Duration(seconds: 30));
      debugPrint('[init] 6-ready result: ${ready['type']}');
      if (ready['type'] != 'ready') {
        _initError = 'Backend not ready'; _envChecked = true; _envOk = false; _initialized = true; notifyListeners(); return;
      }
    } catch (e) {
      debugPrint('[init] 6-ERROR: $e');
      _initError = 'Backend start failed: $e'; _envChecked = true; _envOk = false; _initialized = true; notifyListeners(); return;
    }
    _envChecked = false; _envOk = false;
    notifyListeners();
    debugPrint('[init] 7-setup log listeners');
    _setupLogListeners();
    if (isAndroidPlatform) {
      await _setupAndroidBundledTools();
    } else {
      _autoDetectLocalFfmpeg();
    }
    recheckEnv();
    if (config.mcpEnabled) startMcpServer();
    _initialized = true;
    notifyListeners();
  }

  /// Android：ffmpeg/ffprobe 直接内置在 APK 中（jniLibs），
  /// 首次启动把它们的路径写入配置并告知 C++ 后端。
  Future<void> _setupAndroidBundledTools() async {
    final ffmpeg = await AndroidPlatformBridge.bundledFfmpegPath();
    final ffprobe = await AndroidPlatformBridge.bundledFfprobePath();
    debugPrint('[ffprobe] bundled ffmpeg=$ffmpeg ffprobe=$ffprobe');
    if (ffmpeg == null || ffprobe == null) {
      addLog('未找到内置 ffmpeg/ffprobe', category: 'error');
      debugPrint('[ffprobe] 未找到内置 ffmpeg/ffprobe（jniLibs 解压失败或原生通道不可用）');
      return;
    }

    // 自检可执行性：直接跑 -version，确认 nativeLibraryDir 中的静态二进制可用。
    // 这里有明确的 exit code，便于通过 logcat 定位 127（命令未找到）或 -11（SIGSEGV）之类的失败。
    try {
      final v = await Process.run(ffprobe, ['-version']);
      final firstLine = (v.stdout is String && (v.stdout as String).isNotEmpty)
          ? (v.stdout as String).split('\n').first
          : '<empty>';
      debugPrint('[ffprobe] -version exit=${v.exitCode} out=$firstLine');
      addLog('内置 FFprobe 自检 exit=${v.exitCode}',
          category: v.exitCode == 0 ? 'info' : 'error');
    } catch (e) {
      debugPrint('[ffprobe] -version error: $e');
      addLog('内置 FFprobe 自检异常: $e', category: 'error');
    }

    // Android 内置工具路径是权威值：无条件写入配置（覆盖可能残留的旧/失效路径）。
    await configService.update((c) => c
      ..ffmpegPath = ffmpeg
      ..ffprobePath = ffprobe);

    // 直接传刚解析出的本地路径，绝不依赖可能未更新的 config 字段。
    await backend.setPaths(
      ffmpeg: ffmpeg,
      ffprobe: ffprobe,
      tempDir: isAndroidPlatform ? Directory.systemTemp.path : null,
    );
    // 供 UI 层本地调用（缩略图/帧预览）解析内置 ffmpeg
    FfmpegInstaller.configuredFfmpeg = ffmpeg;
    addLog('已加载内置 FFmpeg: $ffmpeg', category: 'info');
    addLog('已加载内置 FFprobe: $ffprobe', category: 'info');
  }

  void _autoDetectLocalFfmpeg() {
    final ffmpegName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final ffprobeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    // macOS .app 包里可执行文件在 Contents/MacOS，但 ffmpeg 更可能随包放在
    // Contents/Frameworks 或 Contents/Resources；把这几处都找一遍，避免装了
    // 内置版却因为路径猜错而回退到 PATH（macOS 默认没有 ffmpeg）。
    final searchDirs = <String>{
      Directory(Platform.resolvedExecutable).parent.path,
      if (Platform.isMacOS) ...[
        '${Directory(Platform.resolvedExecutable).parent.parent.path}${Platform.pathSeparator}Frameworks',
        '${Directory(Platform.resolvedExecutable).parent.parent.path}${Platform.pathSeparator}Resources',
        '${Directory(Platform.resolvedExecutable).parent.parent.path}${Platform.pathSeparator}bin',
      ],
    };
    bool changed = false;
    for (final dir in searchDirs) {
      final localFfmpeg = File('$dir${Platform.pathSeparator}$ffmpegName');
      final localFfprobe = File('$dir${Platform.pathSeparator}$ffprobeName');
      if (localFfmpeg.existsSync()) {
        final cfgPath = config.ffmpegPath;
        if (cfgPath.isEmpty || !File(cfgPath).existsSync()) {
          config.ffmpegPath = localFfmpeg.path;
          addLog('自动检测到本地 ffmpeg: ${localFfmpeg.path}', category: 'info');
          changed = true;
        }
      }
      if (localFfprobe.existsSync()) {
        final cfgPath = config.ffprobePath;
        if (cfgPath.isEmpty || !File(cfgPath).existsSync()) {
          config.ffprobePath = localFfprobe.path;
          addLog('自动检测到本地 ffprobe: ${localFfprobe.path}', category: 'info');
          changed = true;
        }
      }
    }
    if (changed) {
      // 持久化自动检测结果（ffmpeg/ffprobe 路径）
      configService.update((c) => c
        ..ffmpegPath = (config.ffmpegPath.isNotEmpty ? config.ffmpegPath : c.ffmpegPath)
        ..ffprobePath = (config.ffprobePath.isNotEmpty ? config.ffprobePath : c.ffprobePath));
      recheckEnv();
    }
  }

  void _setupLogListeners() {
    double lastProgressLog = -1;
    // stdout messages (typed: progress, audit, error, etc.)
    pythonProcess.responses.listen((obj) {
      final t = obj['type'] as String? ?? '';
      if (t == 'progress') {
        final p = (obj['progress'] as num?)?.toDouble() ?? 0;
        final speed = obj['speed'] as String? ?? '';
        // 只在进度变化 >=5% 或转码完成时记录，避免刷屏
        if (p > 0 && (p - lastProgressLog >= 5 || p >= 100)) {
          lastProgressLog = p;
          addLog('进度: ${p.toStringAsFixed(0)}% $speed', category: 'progress');
        }
        if (p == 0) lastProgressLog = 0;
      } else if (t == 'audit') {
        final warnings = (obj['warnings'] as List?)?.join('; ') ?? '';
        addLog('审计: $warnings', category: 'error');
      } else if (t != 'ready') {
        addLog('$t: $obj', category: 'info');
      }
    });
    // stderr (ffmpeg output, simplified)
    pythonProcess.errors.listen((line) {
      // Skip ffmpeg header lines
      if (line.startsWith('ffmpeg version') || line.startsWith('  built with') ||
          line.startsWith('  configuration:') || line.startsWith('  libav') ||
          line.startsWith('  libsw') || line.trim().isEmpty) {
        return;
      }
      // Simplify progress lines
      final timeMatch = _stderrTimeRe.firstMatch(line);
      final speedMatch = _speedRe.firstMatch(line);
      if (timeMatch != null && speedMatch != null) {
        addLog('转码 ${timeMatch.group(1)} ${speedMatch.group(1)}x', category: 'progress');
        return;
      }
      addLog(line, category: 'ffmpeg');
    });
    // Initial log
    addLog('日志面板已就绪', category: 'info');
    addLog('后端模式: ${pythonProcess.isRunning ? "已连接" : "未连接"}', category: 'info');
  }

  void selectNav(int i) { _selectedNav = i; notifyListeners(); }

  Future<void> addVideos(List<String> filepaths) async {
    _probeCount++; notifyListeners();
    addLog('添加 ${filepaths.length} 个文件', category: 'info');

    // Android：file_picker 返回的是 cacheDir/file_picker/... 下的缓存路径，
    // 该目录可能被系统清空、部分 ROM 下 fork 出的 ffprobe 子进程也无法访问，
    // 从而报「无法读取文件，请检查路径或文件权限」。这里把每个导入文件复制到
    // 应用文档目录（持久 + app 私有 + 保留扩展名），保证 ffprobe/后续转码稳定读取。
    final entries = <VideoFile>[];
    for (final fp in filepaths) {
      String path = fp;
      if (isAndroidPlatform) {
        final copied = await AndroidPlatformBridge.ensureReadableImport(fp);
        if (copied != fp) {
          addLog('已复制到应用私有目录: $copied', category: 'info');
        }
        path = copied;
      }
      final vf = VideoFile.fromFilepath(path);
      _videos.add(vf);
      entries.add(vf);
    }
    notifyListeners();

    try {
      await _probeAll(entries);
    } finally {
      _probeCount--; notifyListeners();
    }
  }

  Future<void> _probeAll(List<VideoFile> entries) async {
    if (entries.isEmpty) return;
    final concurrency = config.probeThreads.clamp(1, 16);
    int idx = 0;
    await Future.wait(List.generate(concurrency.clamp(1, entries.length), (_) async {
      while (true) {
        final int ci = idx++;
        if (ci >= entries.length) break;
        await _probeOne(entries[ci]);
      }
    }));
  }

  int _probeNotifyCount = 0;
  bool _probeNotifyPending = false;

  void _scheduleProbeNotify() {
    _probeNotifyCount++;
    if (!_probeNotifyPending) {
      _probeNotifyPending = true;
      scheduleMicrotask(() {
        _probeNotifyPending = false;
        if (_probeNotifyCount > 0) {
          notifyListeners();
          _probeNotifyCount = 0;
        }
      });
    }
  }

  Future<void> _probeOne(VideoFile vf) async {
    addLog('探测: ${vf.filename}', category: 'info');
    try {
      final resp = await backend.probe(vf.filepath);
      if (resp['success'] == true) {
        final info = resp['data'] as Map<String, dynamic>;
        final idx = _videos.indexWhere((v) => v.id == vf.id);
        if (idx >= 0) {
          // 探测较慢时用户可能已改过该视频的配置/管线：合并时保留，避免被探测结果静默覆盖
          final prev = _videos[idx];
          _videos[idx] = VideoFile.fromProbeResult(vf.filepath, info, id: vf.id)
              .copyWith(config: prev.config, pipelineGraph: prev.pipelineGraph, pipelineMode: prev.pipelineMode);
          _probeErrors.remove(vf.filepath);
          _scheduleProbeNotify();
        }
        addLog('探测成功: ${vf.filename}', category: 'ffmpeg');
        addLog('  编码: ${info['codec']} | 分辨率: ${info['resolution']} | 帧率: ${info['fps']}fps', category: 'ffmpeg');
        addLog('  时长: ${info['duration_str']} | 大小: ${(info['size_mb'] as num?)?.toStringAsFixed(1) ?? '?'}MB | 像素: ${info['pix_fmt']}', category: 'ffmpeg');
        addLog('  音频: ${info['audio_codec']} ${info['audio_channels']}ch ${info['audio_sample_rate']}Hz', category: 'ffmpeg');
        if (info['has_subtitles'] == true) addLog('  字幕: ${info['subtitle_count']} 轨道', category: 'ffmpeg');
        if (info['is_hdr'] == true) addLog('  HDR: 是', category: 'ffmpeg');
      } else { _probeErrors[vf.filepath] = resp['error'] as String? ?? 'Unknown'; _scheduleProbeNotify(); addLog('探测失败: ${resp['error']}', category: 'error'); }
    } catch (e) { _probeErrors[vf.filepath] = 'Error: $e'; _scheduleProbeNotify(); addLog('探测异常: $e', category: 'error'); }
  }

  void removeVideo(String id) { _videos.removeWhere((v) => v.id == id); notifyListeners(); }
  void clearAllVideos() { _videos.clear(); notifyListeners(); }
  void updateVideoConfig(String id, TranscodeConfig c) { final i = _videos.indexWhere((v) => v.id == id); if (i >= 0) { _videos[i] = _videos[i].copyWith(config: c); notifyListeners(); } }

  void updateVideoPipeline(String id, PipelineGraph graph) {
    final i = _videos.indexWhere((v) => v.id == id);
    if (i >= 0) {
      _videos[i] = _videos[i].copyWith(pipelineGraph: graph);
      notifyListeners();
    }
  }

  // ── 容器管理 ──

  final List<FileContainer> _containers = [];
  List<FileContainer> get containers => List.unmodifiable(_containers);

  Set<String> get _containerFileIds {
    final ids = <String>{};
    for (final c in _containers) {
      for (final item in c.items) {
        ids.add(item.fileId);
      }
    }
    return ids;
  }

  List<VideoFile> get standaloneVideos {
    final cIds = _containerFileIds;
    return _videos.where((v) => !cIds.contains(v.id)).toList();
  }

  Future<void> addContainer(String name, List<String> filepaths) async {
    if (filepaths.isEmpty) return;
    _probeCount++; notifyListeners();
    final entries = <VideoFile>[];
    for (final fp in filepaths) {
      final vf = VideoFile.fromFilepath(fp);
      _videos.add(vf);
      entries.add(vf);
    }
    final items = List.generate(entries.length, (i) => ContainerItem(fileId: entries[i].id, index: i + 1));
    _containers.add(FileContainer(id: const Uuid().v4(), name: name, items: items));
    notifyListeners();
    await _probeAll(entries);
    _probeCount--; notifyListeners();
    addLog('创建容器 "$name"，${entries.length} 个文件', category: 'info');
  }

  /// 创建空容器（不含任何文件，用户可稍后手动添加）
  void addEmptyContainer(String name) {
    _containers.add(FileContainer(id: const Uuid().v4(), name: name));
    notifyListeners();
    addLog('创建空容器 "$name"', category: 'info');
  }

  Future<void> addContainerFromFolder(String dirPath) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    final exts = {...kImageExts, 'mp4', 'mkv', 'mov', 'avi', 'webm', 'flv', 'wmv', 'ts', 'mpg', 'mpeg', 'm4v', '3gp', 'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'ac3'};
    final files = dir.listSync().whereType<File>().where((f) {
      final ext = f.path.split('.').last.toLowerCase();
      return exts.contains(ext);
    }).map((f) => f.path).toList()..sort();
    if (files.isEmpty) return;
    final name = dirPath.split('/').last.split('\\').last;
    await addContainer(name, files);
  }

  void removeContainer(String containerId) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    final container = _containers[idx];
    for (final item in container.items) {
      _videos.removeWhere((v) => v.id == item.fileId);
    }
    _containers.removeAt(idx);
    notifyListeners();
  }

  Future<void> addFilesToContainer(String containerId, List<String> filepaths) async {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0 || filepaths.isEmpty) return;
    _probeCount++; notifyListeners();
    final container = _containers[idx];
    final baseIndex = container.items.isEmpty ? 1 : container.items.map((i) => i.index).reduce(max) + 1;
    final entries = <VideoFile>[];
    for (var i = 0; i < filepaths.length; i++) {
      final vf = VideoFile.fromFilepath(filepaths[i]);
      _videos.add(vf);
      entries.add(vf);
      container.items.add(ContainerItem(fileId: vf.id, index: baseIndex + i));
    }
    notifyListeners();
    await _probeAll(entries);
    _probeCount--; notifyListeners();
  }

  void removeFileFromContainer(String containerId, String fileId) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    _containers[idx].items.removeWhere((i) => i.fileId == fileId);
    _videos.removeWhere((v) => v.id == fileId);
    notifyListeners();
  }

  void sortContainerBy(String containerId, ContainerSortMode mode) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    final container = _containers[idx];
    final items = container.items;
    // 排序比较器内按 fileId 查 _videos，先建一次 Map 索引，避免 O(n²) 线性扫描
    final byId = <String, VideoFile>{for (final v in _videos) v.id: v};
    items.sort((a, b) {
      final va = byId[a.fileId];
      final vb = byId[b.fileId];
      if (va == null || vb == null) return 0;
      return switch (mode) {
        ContainerSortMode.name => va.filename.toLowerCase().compareTo(vb.filename.toLowerCase()),
        ContainerSortMode.size => va.sizeMb.compareTo(vb.sizeMb),
        ContainerSortMode.duration => va.duration.compareTo(vb.duration),
        ContainerSortMode.custom => a.index.compareTo(b.index),
      };
    });
    for (var i = 0; i < items.length; i++) { items[i].index = i + 1; }
    addLog('容器排序: ${mode.name}，${items.length} 个文件', category: 'info');
    notifyListeners();
  }

  void updateContainerItemIndex(String containerId, String fileId, int newIndex) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    final item = _containers[idx].items.where((i) => i.fileId == fileId).firstOrNull;
    if (item != null) { item.index = newIndex; notifyListeners(); }
  }

  void updateContainerPipeline(String containerId, PipelineGraph graph) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    _containers[idx].pipelineGraph = graph;
    notifyListeners();
  }

  void renameContainer(String containerId, String newName) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    _containers[idx].name = newName;
    notifyListeners();
  }

  void reorderContainerItem(String containerId, int oldIdx, int newIdx) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    final container = _containers[idx];
    final sorted = container.sortedItems;
    if (oldIdx < 0 || oldIdx >= sorted.length || newIdx < 0 || newIdx >= sorted.length) return;
    final item = sorted.removeAt(oldIdx);
    sorted.insert(newIdx, item);
    container.items = sorted;
    container.reindex();
    notifyListeners();
  }

  void swapContainerItems(String containerId, int idxA, int idxB) {
    final ci = _containers.indexWhere((c) => c.id == containerId);
    if (ci < 0) return;
    final container = _containers[ci];
    final a = container.items.where((i) => i.index == idxA).firstOrNull;
    final b = container.items.where((i) => i.index == idxB).firstOrNull;
    if (a == null || b == null) return;
    a.index = idxB;
    b.index = idxA;
    notifyListeners();
  }

  void addContainerTasks(String containerId, {int? targetIndex}) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    final container = _containers[idx];
    if (container.pipelineGraph.nodes.isEmpty) {
      addLog('容器 "${container.name}" 没有配置节点图', category: 'error');
      return;
    }

    // Check if graph contains merge nodes (concat/imageToVideo)
    final graph = container.pipelineGraph;
    final hasConcatNode = graph.nodes.any((n) => n.type == PipelineStepType.concatMedia);
    final hasImgSeqNode = graph.nodes.any((n) => n.type == PipelineStepType.imageToVideo);

    if (hasConcatNode || hasImgSeqNode) {
      _addContainerMergeTask(container, hasConcatNode ? PipelineStepType.concatMedia : PipelineStepType.imageToVideo);
      return;
    }

    // Standard: per-file processing
    final items = targetIndex != null
        ? container.items.where((i) => i.index == targetIndex).toList()
        : container.sortedItems;
    for (final item in items) {
      final video = _videos.where((v) => v.id == item.fileId).firstOrNull;
      if (video == null || !video.parsed) continue;
      final graphCopy = container.pipelineGraph.copy();
      final tempVideo = video.copyWith(pipelineGraph: graphCopy);
      _addTasksFromGraph(tempVideo);
    }
  }

  void _addContainerMergeTask(FileContainer container, PipelineStepType mergeType) {
    final node = container.pipelineGraph.nodes.firstWhere((n) => n.type == mergeType);
    final p = node.params;
    final orderMode = p['order_mode'] as String? ?? 'index';

    // Resolve file order
    List<ContainerItem> orderedItems;
    if (orderMode == 'manual') {
      final manualOrder = p['manual_order'] as String? ?? '';
      final indices = manualOrder.split(',').map((s) => int.tryParse(s.trim())).whereType<int>().toList();
      orderedItems = indices.map((i) => container.items.where((item) => item.index == i).firstOrNull).whereType<ContainerItem>().toList();
    } else {
      orderedItems = container.sortedItems;
    }

    final files = orderedItems
        .map((item) => _videos.where((v) => v.id == item.fileId).firstOrNull)
        .whereType<VideoFile>()
        .where((v) => v.parsed)
        .map((v) => v.filepath)
        .toList();

    if (files.isEmpty) {
      addLog('容器内没有已解析的文件', category: 'error');
      return;
    }

    // Build output path
    final outDir = config.defaultOutputDir.isNotEmpty
        ? config.defaultOutputDir
        : files.first.replaceAll(RegExp(r'[^\\/]+$'), '');
    final dir = outDir.endsWith('/') || outDir.endsWith('\\') ? outDir : '$outDir${Platform.pathSeparator}';

    List<BackendCall> calls;
    String outputPath;

    if (mergeType == PipelineStepType.concatMedia) {
      final mode = p['mode'] as String? ?? 'copy';
      final ext = files.first.split('.').last;
      outputPath = '$dir${container.name}_merged.$ext';
      calls = [BackendCall(action: 'concat', params: {'files': files, 'output': outputPath, 'mode': mode})];
    } else {
      final fps = (p['framerate'] as num?)?.toDouble() ?? 30.0;
      final fmt = p['output_format'] as String? ?? 'mp4';
      final codec = p['video_codec'] as String? ?? 'h264';
      outputPath = '$dir${container.name}_sequence.$fmt';
      calls = [BackendCall(action: 'image_sequence', params: {
        'files': files, 'output': outputPath, 'framerate': fps,
        'options': {'video_codec': codec, 'gpu': 'CPU'},
      })];
    }

    _tasks.add(TaskInfo(
      id: 'task_${const Uuid().v4()}',
      videoId: container.id,
      filename: '${container.name} (${mergeType == PipelineStepType.concatMedia ? "合并" : "图片→视频"})',
      inputPath: files.first,
      outputPath: outputPath,
      config: TranscodeConfig(),
      pipelineCalls: calls,
    ));
    notifyListeners();
    addLog('创建合并任务: ${container.name}, ${files.length} 个文件', category: 'info');
  }

  void addTask(String videoId) {
    final idx = _videos.indexWhere((v) => v.id == videoId);
    if (idx < 0) return;
    final video = _videos[idx];

    if (video.pipelineGraph.nodes.isNotEmpty) {
      _addTasksFromGraph(video);
      return;
    }

    final cfg = video.config;
    final ext = cfg.outputFormat == 'keep' ? video.filepath.split('.').last : cfg.outputFormat;
    final base = video.filename.replaceAll(RegExp(r'\.[^.]+$'), '');
    String fn = cfg.namingMode == 'keep' ? '$base.$ext' : cfg.namingMode == 'suffix' ? '$base${cfg.namingValue}.$ext' : '${cfg.namingValue}.$ext';
    String dir = config.defaultOutputDir.isNotEmpty ? config.defaultOutputDir : video.filepath.replaceAll(RegExp(r'[^\\/]+$'), '');
    if (!dir.endsWith('/') && !dir.endsWith('\\')) dir = '$dir${Platform.pathSeparator}';
    var out = '$dir$fn';
    if (out == video.filepath) { final be = fn.replaceAll(RegExp(r'\.[^.]+$'), ''); final ee = fn.split('.').last; out = '$dir${be}_processed.$ee'; }
    _tasks.add(TaskInfo(id: 'task_${const Uuid().v4()}', videoId: videoId, filename: video.filename, inputPath: video.filepath, outputPath: out, config: cfg));
    notifyListeners();
  }

  void _addTasksFromGraph(VideoFile video) {
    final plans = GraphExecutor.resolvePlans(video.pipelineGraph);
    if (plans.isEmpty) {
      addLog('节点图中未找到完整的 源文件→输出 任务', category: 'error');
      return;
    }
    for (var i = 0; i < plans.length; i++) {
      final plan = plans[i];
      final outputPath = GraphExecutor.resolveOutputPath(plan, video, config);
      var calls = GraphExecutor.buildBackendCalls(plan, video.filepath, outputPath);
      // 如果节点图没有处理步骤（只有源文件→输出），创建一个默认的转码任务
      if (calls.isEmpty) {
        calls = [BackendCall(
          action: '_file_copy',
          params: {
            'input': video.filepath,
            'output': outputPath,
          },
        )];
      }
      // 末步为帧提取(all/range)时，真实输出是帧目录而非文件路径，供完成态尺寸统计与"打开输出"
      var effectiveOutput = outputPath;
      for (final c in calls) {
        if (c.action == 'extract_frames_range' || c.action == 'extract_frames_all') {
          effectiveOutput = c.params['output_dir'] as String? ?? effectiveOutput;
        }
      }
      final label = plans.length > 1 ? '${video.filename} [任务${i + 1}]' : video.filename;
      _tasks.add(TaskInfo(
        id: 'task_${const Uuid().v4()}',
        videoId: video.id,
        filename: label,
        inputPath: video.filepath,
        outputPath: effectiveOutput,
        config: TranscodeConfig(),
        pipelineCalls: calls,
      ));
    }
    notifyListeners();
  }

  /// 从命令页面添加自定义 FFmpeg 命令任务
  void addCustomTask({
    required String inputPath,
    required String outputPath,
    required String command,
    required String filename,
  }) {
    _tasks.add(TaskInfo(
      id: 'task_${const Uuid().v4()}',
      videoId: '',
      filename: filename,
      inputPath: inputPath,
      outputPath: outputPath,
      config: TranscodeConfig(),
      // 引号感知分词（原 command.split(' ') 会把 `-i "my file.mp4"` 拆坏）
      command: _splitCommandQuoted(command),
    ));
    notifyListeners();
  }

  /// 命令行分词：支持单/双引号包裹的空格（与后端 parser::splitCommand 一致）。
  static List<String> _splitCommandQuoted(String cmd) {
    final tokens = <String>[];
    final current = StringBuffer();
    bool inQuote = false;
    String quoteChar = '';
    for (var i = 0; i < cmd.length; i++) {
      final c = cmd[i];
      if (inQuote) {
        if (c == quoteChar) {
          inQuote = false;
        } else {
          current.write(c);
        }
      } else if (c == '"' || c == '\'') {
        inQuote = true;
        quoteChar = c;
      } else if (c == ' ' || c == '\t') {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
      } else {
        current.write(c);
      }
    }
    if (current.isNotEmpty) tokens.add(current.toString());
    return tokens;
  }

  /// join 时重新给含空格的 token 加引号，保证后端 splitCommand 能还原（否则引号信息丢失）。
  static String _quoteToken(String t) {
    if (t.contains(' ') || t.contains('\t')) {
      return '"${t.replaceAll('"', r'\"')}"';
    }
    return t;
  }

  void processSingleTask(String tid) {
    final limit = config.maxConcurrentTasks == 0 ? 999 : config.maxConcurrentTasks;
    if (_runningTaskIds.length >= limit) return;
    final i = _tasks.indexWhere((t) => t.id == tid);
    if (i < 0 || _tasks[i].status != TaskStatus.pending) return;
    _cancelRequested = false;
    _cancelledTaskIds.remove(tid);
    final t = _tasks.removeAt(i); _tasks.insert(0, t);
    notifyListeners(); processNextTask();
  }

  void processAllTasks() { _cancelRequested = false; processNextTask(); }

  Future<void> processNextTask() async {
    if (_cancelRequested) return;
    final limit = config.maxConcurrentTasks == 0 ? 999 : config.maxConcurrentTasks;
    while (_runningTaskIds.length < limit) {
      if (_cancelRequested) break;
      final pi = _tasks.indexWhere((t) => t.status == TaskStatus.pending);
      if (pi < 0) break;
      final task = _tasks[pi];
      _cancelledTaskIds.remove(task.id);
      _runningTaskIds.add(task.id);
      _currentTaskId = task.id;
      _tasks[pi] = task.copyWith(status: TaskStatus.processing);
      notifyListeners();
      addLog('开始处理: ${task.filename}', category: 'info');
      addLog('输入: ${task.inputPath}', category: 'info');
      addLog('输出: ${task.outputPath}', category: 'info');
      // catchError 必不可少：后端调用一旦抛异常/超时，没有它 .then 永不执行，
      // task id 会永远滞留在 _runningTaskIds、processing 恒为 true，队列卡死。
      _runTask(task).then((_) {
        _runningTaskIds.remove(task.id);
        if (_currentTaskId == task.id) _currentTaskId = null;
        if (!_cancelRequested && _tasks.any((t) => t.status == TaskStatus.pending)) {
          processNextTask();
        }
      }).catchError((Object e, StackTrace st) {
        _runningTaskIds.remove(task.id);
        if (_currentTaskId == task.id) _currentTaskId = null;
        final fi = _tasks.indexWhere((t) => t.id == task.id);
        // 已取消的任务保持 cancelled，不被异常覆盖为 failed
        if (fi >= 0 && !_cancelRequested && _tasks[fi].status == TaskStatus.processing) {
          _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.failed, error: '处理异常: $e');
          notifyListeners();
        }
        if (!_cancelRequested && _tasks.any((t) => t.status == TaskStatus.pending)) {
          processNextTask();
        }
      });
    }
  }

  Future<void> _runTask(TaskInfo task) async {
    final pi = _tasks.indexWhere((t) => t.id == task.id);
    if (pi < 0) return;
    if (task.pipelineCalls != null && task.pipelineCalls!.isNotEmpty) {
      await _processPipelineTask(task.id);
    } else if (task.command != null && task.command!.isNotEmpty) {
      await _processCustomCommand(task.id, task);
    } else {
      await _processLegacyTask(task.id, task);
    }
  }

  Future<void> _processLegacyTask(String taskId, TaskInfo task) async {
    final c = task.config;
    addLog('编码器: ${c.videoCodec}, GPU: ${c.gpu}, 预设: ${c.preset}', category: 'info');
    if (c.crf != null) addLog('  CRF: ${c.crf}', category: 'info');
    if (c.videoBitrate != null) addLog('  视频码率: ${c.videoBitrate}kbps', category: 'info');
    if (c.resolutionW != null) addLog('  分辨率: ${c.resolutionW}x${c.resolutionH}', category: 'info');
    if (c.framerate != null) addLog('  帧率: ${c.framerate}fps', category: 'info');
    addLog('  音频: ${c.audioCodec} ${c.audioBitrate ?? '默认'}kbps ${c.audioChannels ?? '原始'}ch', category: 'info');
    if (c.subtitleEnabled) addLog('  字幕: ${c.subtitleSource} ${c.subtitleFile ?? '内嵌#${c.subtitleIndex}'}', category: 'info');
    if (c.startTime != null || c.endTime != null) addLog('  截取: ${c.startTime ?? 0}s - ${c.endTime ?? '末尾'}', category: 'info');

    StreamSubscription<ProgressUpdate>? sub;
    sub = backend.progressStream.listen((u) {
      if (u.taskId == taskId) {
        final i = _tasks.indexWhere((t) => t.id == taskId);
        // 已取消/已完成/已失败的任务不再被进度消息改回 processing
        if (i >= 0 && _tasks[i].status == TaskStatus.processing) {
          _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: u.progress, elapsed: u.currentTime, remaining: u.remaining, speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame);
          notifyListeners();
        }
      }
    });

    Map<String, dynamic> resp;
    try {
      if (task.config.subtitleEnabled) {
        resp = await backend.subtitle(task.id, input: task.inputPath, output: task.outputPath, subtitleOptions: {
          'source': task.config.subtitleSource,
          if (task.config.subtitleFile != null) 'subtitle_file': task.config.subtitleFile,
          'subtitle_index': task.config.subtitleIndex,
          if (task.config.subtitleIndex2 != null) 'subtitle_index2': task.config.subtitleIndex2,
          'style': {
            'font_name': task.config.subtitleFontName,
            'font_size': task.config.subtitleFontSize,
            'font_color': task.config.subtitleFontColor,
            'outline_width': task.config.subtitleOutlineWidth,
            'outline_color': task.config.subtitleOutlineColor,
          },
        }, videoOptions: task.config.toBackendOptions());
      } else {
        resp = await backend.transcode(task.id, input: task.inputPath, output: task.outputPath, options: task.config.toBackendOptions());
      }
    } finally {
      // 无论成功、失败还是异常都必须取消订阅，否则泄漏且回调会继续改动任务状态
      await sub.cancel();
    }

    final fi = _tasks.indexWhere((t) => t.id == taskId);
    // 取消后若用户重新开始（_cancelRequested 复位），旧任务在途响应不得把 cancelled 改回终态
    if (fi >= 0 && !_cancelRequested && _tasks[fi].status == TaskStatus.processing) {
      if (resp['success'] == true) {
        final d = resp['data'] as Map<String, dynamic>?;
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.completed, progress: 100, outputSize: d?['output_size'] as int?, duration: (d?['duration'] as num?)?.toDouble(), command: (d?['command'] as List?)?.cast<String>());
        addLog('任务完成: ${task.filename} (${d?['duration']}s)', category: 'info');
        final sz = d?['output_size'] as int?;
        if (sz != null) addLog('  输出大小: ${(sz / 1024 / 1024).toStringAsFixed(1)}MB', category: 'info');
        final cmd = (d?['command'] as List?)?.cast<String>();
        if (cmd != null) addLog('  命令: ${cmd.join(' ')}', category: 'ffmpeg');
        onTaskFinished?.call(task.filename, TaskStatus.completed);
      } else {
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.failed, error: resp['error'] as String?, logLines: (resp['data']?['log_lines'] as List?)?.cast<String>() ?? [], command: (resp['data']?['command'] as List?)?.cast<String>());
        addLog('任务失败: ${task.filename} - ${resp['error']}', category: 'error');
        onTaskFinished?.call(task.filename, TaskStatus.failed);
      }
      notifyListeners();
    }
  }

  /// 处理用户自定义 FFmpeg 命令任务
  Future<void> _processCustomCommand(String taskId, TaskInfo task) async {
    addLog('自定义命令: ${task.command!.join(' ')}', category: 'info');

    StreamSubscription<ProgressUpdate>? sub;
    sub = backend.progressStream.listen((u) {
      if (u.taskId == taskId) {
        final i = _tasks.indexWhere((t) => t.id == taskId);
        // 已取消/已完成/已失败的任务不再被进度消息改回 processing
        if (i >= 0 && _tasks[i].status == TaskStatus.processing) {
          _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: u.progress, elapsed: u.currentTime, remaining: u.remaining, speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame);
          notifyListeners();
        }
      }
    });

    // 自定义命令：input/output 已在 addCustomTask 时解析好（含引号分词），
    // 这里直接把命令全文交给后端 custom_command 执行
    // （原来再 split(' ') 解析一遍会覆盖正确路径，且 _custom_command 后端根本不处理）
    final cmdParts = task.command!;
    // 含空格的路径需重新加引号，否则 join 后后端 splitCommand 会把路径拆开
    final commandText = cmdParts.map(_quoteToken).join(' ');
    final Map<String, dynamic> resp;
    try {
      resp = await backend.customCommand(task.id,
          command: commandText,
          input: task.inputPath,
          output: task.outputPath);
    } finally {
      await sub.cancel();
    }

    final fi = _tasks.indexWhere((t) => t.id == taskId);
    // 取消后若用户重新开始（_cancelRequested 复位），旧任务在途响应不得把 cancelled 改回终态
    if (fi >= 0 && !_cancelRequested && _tasks[fi].status == TaskStatus.processing) {
      if (resp['success'] == true) {
        final d = resp['data'] as Map<String, dynamic>?;
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.completed, progress: 100, outputSize: d?['output_size'] as int?, duration: (d?['duration'] as num?)?.toDouble(), command: (d?['command'] as List?)?.cast<String>());
        addLog('任务完成: ${task.filename} (${d?['duration']}s)', category: 'info');
        onTaskFinished?.call(task.filename, TaskStatus.completed);
      } else {
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.failed, error: resp['error'] as String?, logLines: (resp['data']?['log_lines'] as List?)?.cast<String>() ?? [], command: (resp['data']?['command'] as List?)?.cast<String>());
        addLog('任务失败: ${task.filename} - ${resp['error']}', category: 'error');
        onTaskFinished?.call(task.filename, TaskStatus.failed);
      }
      notifyListeners();
    }
  }

  Future<void> _processPipelineTask(String taskId) async {
    final ti = _tasks.indexWhere((t) => t.id == taskId);
    if (ti < 0) return;
    final task = _tasks[ti];
    final calls = task.pipelineCalls!;
    final realCalls = calls.where((c) => c.action != '_cleanup').toList();
    final cleanupCalls = calls.where((c) => c.action == '_cleanup').toList();

    // Expand loop calls: duplicate entire consecutive groups with matching loopCount
    final expandedCalls = <BackendCall>[];
    // 循环中间迭代的产物（_loop_N）需要清理；最后迭代输出保持原路径，
    // 使后续步骤 input / 任务的最终 outputPath 都指向真实存在的文件
    final loopCleanupPaths = <String>[];
    var ci2 = 0;
    while (ci2 < realCalls.length) {
      final call = realCalls[ci2];
      if (call.loopCount > 1) {
        // Collect all consecutive calls with the same loopCount
        final group = <BackendCall>[call];
        var j = ci2 + 1;
        while (j < realCalls.length && realCalls[j].loopCount == call.loopCount) {
          group.add(realCalls[j]);
          j++;
        }
        // Duplicate the entire group N times, rewriting input/output paths
        for (var li = 0; li < call.loopCount; li++) {
          final pathMap = <String, String>{}; // old path -> new loop path
          final isLastIter = li == call.loopCount - 1;
          for (final gc in group) {
            final p = gc.params;
            final loopParams = Map<String, dynamic>.from(p);
            // Rewrite output path
            final output = p['output'] as String? ?? '';
            if (output.isNotEmpty) {
              final newOutput = isLastIter ? output : _loopPath(output, li + 1);
              pathMap[output] = newOutput;
              loopParams['output'] = newOutput;
              if (!isLastIter) loopCleanupPaths.add(newOutput);
            }
            // 帧提取输出目录（range/all）也要随循环迭代改写，避免各迭代写进同一目录
            final outputDir = p['output_dir'] as String? ?? '';
            if (outputDir.isNotEmpty) {
              final newOutputDir = isLastIter ? outputDir : _loopPath(outputDir, li + 1);
              loopParams['output_dir'] = newOutputDir;
              if (!isLastIter) loopCleanupPaths.add(newOutputDir);
            }
            // Rewrite input path if it was a previous step's output in this group
            final input = p['input'] as String? ?? '';
            if (input.isNotEmpty && pathMap.containsKey(input)) {
              loopParams['input'] = pathMap[input]!;
            }
            expandedCalls.add(BackendCall(action: gc.action, params: loopParams));
          }
        }
        ci2 = j;
      } else {
        // 拷贝参数以允许运行时改写（如 extract_audio 改扩展名后修正下游 input），不污染原任务快照
        expandedCalls.add(BackendCall(action: call.action, params: Map<String, dynamic>.from(call.params), loopCount: call.loopCount, loopMode: call.loopMode));
        ci2++;
      }
    }
    // 循环中间产物与正常临时文件一起清理（成功/失败路径都会执行 _cleanupTempFiles）
    for (final path in loopCleanupPaths) {
      cleanupCalls.add(BackendCall(action: '_cleanup', params: {'path': path}));
    }

    addLog('节点图任务: ${expandedCalls.length} 步', category: 'info');

    // 记录上一步"实际"产物路径：extract_audio 等可能运行时改扩展名，下游 input 需要跟随
    String? pendingActualOutput;
    for (var ci = 0; ci < expandedCalls.length; ci++) {
      // 取消后不再执行后续步骤（本地 Process.run 步骤无法被 kill，必须靠这里停下）
      if (_cancelRequested || _cancelledTaskIds.contains(taskId)) break;
      final call = expandedCalls[ci];
      // 上一步产物被运行时改写时，修正紧邻下一步的 input（仅当它确实消费了上一步 output）
      if (ci > 0 && pendingActualOutput != null) {
        final inp = call.params['input'];
        final prevOut = expandedCalls[ci - 1].params['output'];
        if (inp is String && inp == prevOut) {
          call.params['input'] = pendingActualOutput;
        }
        pendingActualOutput = null;
      }
      final stepProgress = ci / expandedCalls.length;

      final fi = _tasks.indexWhere((t) => t.id == taskId);
      if (fi >= 0) {
        _tasks[fi] = _tasks[fi].copyWith(currentCallIndex: ci, progress: stepProgress * 100);
        notifyListeners();
      }

      addLog('步骤 ${ci + 1}/${expandedCalls.length}: ${call.action}', category: 'info');

      StreamSubscription<ProgressUpdate>? sub;
      sub = backend.progressStream.listen((u) {
        if (u.taskId == taskId) {
          final i = _tasks.indexWhere((t) => t.id == taskId);
          // 已取消/已完成/已失败的任务不再被进度消息改回 processing
          if (i >= 0 && _tasks[i].status == TaskStatus.processing) {
            final overallProgress = (stepProgress + u.progress / 100 / expandedCalls.length) * 100;
            _tasks[i] = _tasks[i].copyWith(
              status: TaskStatus.processing,
              progress: overallProgress.clamp(0, 100),
              elapsed: u.currentTime, remaining: u.remaining,
              speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame,
            );
            notifyListeners();
          }
        }
      });

      Map<String, dynamic> resp;
      final p = call.params;
      try {
      switch (call.action) {
        case 'transcode':
          resp = await backend.transcode(task.id,
              input: p['input'] as String, output: p['output'] as String,
              options: p['options'] as Map<String, dynamic>);
          break;
        case 'subtitle':
          resp = await backend.subtitle(task.id,
              input: p['input'] as String, output: p['output'] as String,
              subtitleOptions: p['subtitle_options'] as Map<String, dynamic>,
              videoOptions: p['video_options'] as Map<String, dynamic>?);
          break;
        case 'extract_frame':
          resp = await backend.extractFrame(task.id,
              input: p['input'] as String, output: p['output'] as String,
              time: (p['time'] as num).toDouble());
          break;
        case 'extract_frames_range':
        case 'extract_frames_all':
          resp = await _runFrameExtraction(p);
          break;
        case 'image_convert':
          resp = await _runImageConvert(p);
          break;
        case 'image_crop':
          resp = await _runImageCrop(p);
          break;
        case 'image_rotate':
          resp = await _runImageRotate(p);
          break;
        case 'image_scale':
          resp = await _runImageScale(p);
          break;
        case 'image_brightness':
          resp = await _runImageBrightness(p);
          break;
        case 'image_noise':
          resp = await _runImageNoise(p);
          break;
        case 'image_sharpen':
          resp = await _runImageSharpen(p);
          break;
        case 'image_denoise':
          resp = await _runImageDenoise(p);
          break;
        case 'image_channel_extract':
          resp = await _runImageChannelExtract(p);
          break;
        case 'video_crop':
          resp = await _runVideoCrop(taskId, p);
          break;
        case 'extract_audio':
          resp = await _runExtractAudio(taskId, p);
          break;
        case 'audio_metadata':
          resp = await _runAudioMetadata(task.id, p);
          break;
        case 'concat':
          var files = (p['files'] as List?)?.cast<String>() ?? const <String>[];
          if (files.isEmpty) files = await _resolveMergeFiles(p['input'] as String?);
          resp = await backend.concat(task.id,
              files: files,
              output: p['output'] as String,
              mode: p['mode'] as String? ?? 'copy',
              options: p['options'] as Map<String, dynamic>?);
          break;
        case 'image_sequence':
          var files = (p['files'] as List?)?.cast<String>() ?? const <String>[];
          if (files.isEmpty) files = await _resolveMergeFiles(p['input'] as String?);
          resp = await backend.imageSequence(task.id,
              files: files,
              output: p['output'] as String,
              framerate: (p['framerate'] as num?)?.toDouble() ?? 30.0,
              options: p['options'] as Map<String, dynamic>?);
          break;
        case '_file_copy':
          resp = await _runFileCopy(p);
          break;
        default:
          resp = {'success': false, 'error': '未知动作: ${call.action}'};
      }
      } catch (e) {
        // 异常路径也要清理中间文件（原实现被上层 catchError 吞掉后泄漏全部临时文件）
        _cleanupTempFiles(cleanupCalls);
        rethrow;
      } finally {
        // 任何分支（含异常）都必须取消订阅，防止泄漏
        await sub.cancel();
      }

      if (resp['success'] != true) {
        final fi2 = _tasks.indexWhere((t) => t.id == taskId);
        if (fi2 >= 0 && !_cancelRequested && _tasks[fi2].status == TaskStatus.processing) {
          _tasks[fi2] = _tasks[fi2].copyWith(
            status: TaskStatus.failed,
            error: '步骤 ${ci + 1} 失败: ${resp['error']}',
            logLines: (resp['data']?['log_lines'] as List?)?.cast<String>() ?? [],
            command: (resp['data']?['command'] as List?)?.cast<String>(),
          );
          addLog('步骤 ${ci + 1} 失败: ${resp['error']}', category: 'error');
          onTaskFinished?.call(task.filename, TaskStatus.failed);
          notifyListeners();
        }
        _cleanupTempFiles(cleanupCalls);
        return;
      }
      addLog('步骤 ${ci + 1} 完成', category: 'info');
      final actualOut = resp['_actual_output'];
      if (actualOut is String && actualOut.isNotEmpty) {
        pendingActualOutput = actualOut;
      }
    }

    final fi3 = _tasks.indexWhere((t) => t.id == taskId);
    if (fi3 >= 0 && !_cancelRequested && _tasks[fi3].status == TaskStatus.processing) {
      int? outSize;
      if (FileSystemEntity.isDirectorySync(task.outputPath)) {
        try {
          outSize = Directory(task.outputPath).listSync().whereType<File>().fold<int>(0, (sum, f) => sum + f.lengthSync());
        } catch (_) {}
      } else if (FileSystemEntity.isFileSync(task.outputPath)) {
        try {
          outSize = File(task.outputPath).lengthSync();
        } catch (_) {}
      }
      _tasks[fi3] = _tasks[fi3].copyWith(status: TaskStatus.completed, progress: 100, outputSize: outSize);
      addLog('任务完成: ${task.filename}', category: 'info');
      onTaskFinished?.call(task.filename, TaskStatus.completed);
      notifyListeners();
    }

    _cleanupTempFiles(cleanupCalls);
  }

  Future<Map<String, dynamic>> _runFrameExtraction(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final outDir = p['output_dir'] as String;
    final fps = (p['fps'] as num?)?.toDouble() ?? 1.0;
    final fmt = p['format'] as String? ?? 'png';
    final startTime = p['start_time'] as double?;
    final endTime = p['end_time'] as double?;

    try {
      final dir = Directory(outDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final args = <String>['-y'];
      if (startTime != null) args.addAll(['-ss', '$startTime']);
      args.addAll(['-i', input]);
      if (endTime != null) args.addAll(['-to', '${endTime - (startTime ?? 0)}']);
      args.addAll(['-vf', 'fps=$fps', '$outDir/frame_%06d.$fmt']);

      addLog('帧提取: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0) {
        final count = dir.listSync().where((f) => f.path.endsWith('.$fmt')).length;
        addLog('帧提取完成: $count 帧 → $outDir', category: 'info');
        return {'success': true, 'data': {'output_path': outDir, 'frame_count': count}};
      } else {
        return {'success': false, 'error': '帧提取失败: ${(result.stderr as String).split('\n').last}'};
      }
    } catch (e) {
      return {'success': false, 'error': '帧提取异常: $e'};
    }
  }

  String get _ffmpegBin {
    final p = config.ffmpegPath;
    return (p.isNotEmpty && File(p).existsSync()) ? p : 'ffmpeg';
  }

  Future<Map<String, dynamic>> _runImageConvert(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final quality = (p['quality'] as num?)?.toInt() ?? 95;
    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final args = <String>['-y', '-i', input];
      if (output.endsWith('.ico')) {
        args.addAll(['-vf', 'scale=256:256:force_original_aspect_ratio=decrease']);
      } else if (output.endsWith('.jpg') || output.endsWith('.jpeg')) {
        // JPEG(mjpeg)：-q:v 2–31，值越小质量越好；quality 0(最差)→100(最佳) 线性映射，
        // 避免原写法把 quality≤69 全部压到 10（质量滑杆中低档几乎失效）。
        final qscale = (31 - quality.clamp(0, 100) * 29 / 100).round().clamp(2, 31);
        args.addAll(['-q:v', '$qscale']);
      } else if (output.endsWith('.webp')) {
        // WebP(libwebp) 的 quality 是 0–100 且「越大越好」，与 mjpeg 的 -q:v 尺度相反；
        // 原代码把 webp 混进 jpg 用 -q:v，导致 webp 质量被压到极低。这里用 -quality 直接映射。
        args.addAll(['-quality', '${quality.clamp(0, 100)}']);
      }
      args.add(output);
      addLog('图片转换: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片转换完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('图片转换失败: $errMsg', category: 'error');
        return {'success': false, 'error': '图片转换失败: $errMsg'};
      }
    } catch (e) {
      addLog('图片转换异常: $e', category: 'error');
      return {'success': false, 'error': '图片转换异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runImageCrop(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final cropW = (p['crop_w'] as num?)?.toInt() ?? 0;
    final cropH = (p['crop_h'] as num?)?.toInt() ?? 0;
    final cropX = (p['crop_x'] as num?)?.toInt() ?? 0;
    final cropY = (p['crop_y'] as num?)?.toInt() ?? 0;

    if (cropW <= 0 || cropH <= 0) {
      return {'success': false, 'error': '裁剪尺寸无效 (${cropW}x$cropH)'};
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final cropFilter = 'crop=$cropW:$cropH:$cropX:$cropY';
      final args = <String>['-y', '-i', input, '-vf', cropFilter, output];
      addLog('图片裁剪: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片裁剪完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('图片裁剪失败: $errMsg', category: 'error');
        return {'success': false, 'error': '图片裁剪失败: $errMsg'};
      }
    } catch (e) {
      addLog('图片裁剪异常: $e', category: 'error');
      return {'success': false, 'error': '图片裁剪异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runVideoCrop(String taskId, Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final cropW = (p['crop_w'] as num?)?.toInt() ?? 0;
    final cropH = (p['crop_h'] as num?)?.toInt() ?? 0;
    final cropX = (p['crop_x'] as num?)?.toInt() ?? 0;
    final cropY = (p['crop_y'] as num?)?.toInt() ?? 0;

    if (cropW <= 0 || cropH <= 0) {
      return {'success': false, 'error': '裁剪尺寸无效 (${cropW}x$cropH)'};
    }

    try {
      final totalDuration = await _probeDuration(input);
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final cropFilter = 'crop=$cropW:$cropH:$cropX:$cropY';
      final args = <String>['-y', '-i', input, '-vf', cropFilter, '-c:a', 'copy', output];
      addLog('视频裁剪: $_ffmpegBin ${args.join(' ')}', category: 'info');
      return await _runFfmpegWithProgress(taskId, args, '视频裁剪', totalDuration: totalDuration);
    } catch (e) {
      addLog('视频裁剪异常: $e', category: 'error');
      return {'success': false, 'error': '视频裁剪异常: $e'};
    }
  }

  String get _ffprobeBin {
    final p = config.ffprobePath;
    return (p.isNotEmpty && File(p).existsSync()) ? p : 'ffprobe';
  }

  // source codec → compatible output formats for copy mode
  static const _codecCompatFormats = <String, Set<String>>{
    'aac': {'m4a', 'mp4', 'mkv', 'mov', 'mka'},
    'mp3': {'mp3', 'mkv', 'mka'},
    'flac': {'flac', 'mkv', 'mka', 'ogg'},
    'vorbis': {'ogg', 'mkv', 'mka', 'webm'},
    'opus': {'ogg', 'mkv', 'mka', 'webm'},
    'pcm_s16le': {'wav', 'mkv', 'mka'},
    'ac3': {'mkv', 'mka', 'mp4', 'mov'},
    'eac3': {'mkv', 'mka', 'mp4', 'mov'},
    'dts': {'mkv', 'mka'},
    'truehd': {'mkv', 'mka'},
  };
  // source codec → best default output format for copy mode
  static const _codecDefaultFormat = <String, String>{
    'aac': 'm4a', 'mp3': 'mp3', 'flac': 'flac', 'vorbis': 'ogg',
    'opus': 'ogg', 'pcm_s16le': 'wav', 'ac3': 'mka', 'eac3': 'mka',
    'dts': 'mka', 'truehd': 'mka',
  };

  Future<String?> _probeAudioCodec(String input) async {
    try {
      final result = await Process.run(_ffprobeBin, [
        '-v', 'quiet', '-select_streams', 'a:0',
        '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', input,
      ]);
      if (result.exitCode == 0) {
        final codec = (result.stdout as String).trim().split('\n').first.trim();
        if (codec.isNotEmpty) return codec;
      }
    } catch (_) {}
    return null;
  }

  Future<double?> _probeDuration(String input) async {
    try {
      final result = await Process.run(_ffprobeBin, [
        '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0', input,
      ]);
      if (result.exitCode == 0) {
        return double.tryParse((result.stdout as String).trim());
      }
    } catch (_) {}
    return null;
  }

  static final _ffmpegTimeRe = RegExp(r'time=(\d+):(\d+):(\d+)\.(\d+)');
  static final _speedRe = RegExp(r'speed=\s*([\d.]+)x');
  // 旧后端 stderr 进度行正则（static final，避免每行重新编译）
  static final _stderrTimeRe = RegExp(r'time=(\d{2}:\d{2}:\d{2})');

  /// 当前正在运行的本地 ffmpeg 进程集合（供 cancelProcessing 终止）。
  /// 用 Set 而非单字段：maxConcurrentTasks>1 时多个本地任务并发，单字段会被覆盖。
  final Set<Process> _localFfmpegProcesses = {};

  /// 按"完整行"解析进度：原实现直接对网络分块 firstMatch，
  /// `time=` 跨 chunk 边界时进度会漏更新。
  void _parseFfmpegProgressLine(String taskId, String line, double? totalDuration) {
    if (line.isEmpty) return;
    final m = _ffmpegTimeRe.firstMatch(line);
    if (m != null && totalDuration != null && totalDuration > 0) {
      final frac = m.group(4)!;
      final t = int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!) + int.parse(frac) / pow(10, frac.length);
      final pct = (t / totalDuration * 100).clamp(0, 99.9);
      final sm = _speedRe.firstMatch(line);
      final speed = sm != null ? '${sm.group(1)}x' : '';
      final i = _tasks.indexWhere((tk) => tk.id == taskId);
      if (i >= 0) {
        _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: pct.toDouble(), speed: speed);
        notifyListeners();
      }
    }
  }

  Future<Map<String, dynamic>> _runFfmpegWithProgress(String taskId, List<String> args, String label, {double? totalDuration}) async {
    Process? process;
    try {
      process = await Process.start(_ffmpegBin, args);
      _localFfmpegProcesses.add(process);
      _localProcessesByTask.putIfAbsent(taskId, () => []).add(process);
      final stderrBuf = StringBuffer();
      final lineBuf = StringBuffer();
      process.stderr.transform(utf8.decoder).listen((chunk) {
        stderrBuf.write(chunk);
        lineBuf.write(chunk);
        final text = lineBuf.toString();
        int start = 0;
        int nl;
        while ((nl = text.indexOf('\n', start)) >= 0) {
          _parseFfmpegProgressLine(taskId, text.substring(start, nl), totalDuration);
          start = nl + 1;
        }
        // 保留未完成的行（可能跨 chunk）
        lineBuf.clear();
        if (start < text.length) lineBuf.write(text.substring(start));
      });
      process.stdout.drain<void>();
      final exitCode = await process.exitCode;
      final stderr = stderrBuf.toString().trim();
      final output = args.last;
      if (exitCode == 0 && File(output).existsSync()) {
        addLog('$label完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('$label失败: $errMsg', category: 'error');
        return {'success': false, 'error': '$label失败: $errMsg'};
      }
    } catch (e) {
      addLog('$label异常: $e', category: 'error');
      return {'success': false, 'error': '$label异常: $e'};
    } finally {
      _localFfmpegProcesses.remove(process);
      final taskProcs = _localProcessesByTask[taskId];
      if (taskProcs != null) {
        taskProcs.remove(process);
        if (taskProcs.isEmpty) _localProcessesByTask.remove(taskId);
      }
    }
  }

  Future<Map<String, dynamic>> _runExtractAudio(String taskId, Map<String, dynamic> p) async {
    final input = p['input'] as String;
    var output = p['output'] as String;
    var codec = p['audio_codec'] as String? ?? 'copy';
    final startTime = p['start_time'] as num?;
    final endTime = p['end_time'] as num?;

    try {
      final sourceCodec = await _probeAudioCodec(input);
      final totalDuration = await _probeDuration(input);
      addLog('源音频编码: ${sourceCodec ?? "未知"}', category: 'info');

      final outExt = output.split('.').last.toLowerCase();

      if (codec == 'copy' && sourceCodec != null) {
        final compat = _codecCompatFormats[sourceCodec];
        if (compat != null && compat.contains(outExt)) {
          addLog('copy 模式: $sourceCodec → $outExt (兼容)', category: 'info');
        } else {
          final bestFmt = _codecDefaultFormat[sourceCodec] ?? 'mka';
          addLog('copy 模式: $sourceCodec 不兼容 $outExt, 自动切换为 $bestFmt', category: 'warning');
          output = output.replaceAll(RegExp(r'\.[^.]+$'), '.$bestFmt');
        }
      } else if (codec == 'copy') {
        output = output.replaceAll(RegExp(r'\.[^.]+$'), '.mka');
        addLog('copy 模式: 未知源编码, 使用 mka 容器', category: 'warning');
      }

      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final args = <String>['-y'];
      if (startTime != null) args.addAll(['-ss', startTime.toString()]);
      if (endTime != null) {
        // -ss 和 -to 都在 -i 前时，两者均作用于输入文件时间轴（绝对时间），
        // -to 不是相对 seek 点，因此直接传绝对 endTime。
        // 若需 -to 相对 seek，必须把 -to 移到 -i 之后。
        final toVal = endTime;
        args.addAll(['-to', toVal.toString()]);
      }
      args.addAll(['-i', input, '-vn', '-sn', '-acodec', codec, output]);
      // 同时修正对应的 clipDuration 计算
      addLog('提取音频: $_ffmpegBin ${args.join(' ')}', category: 'info');

      // 当 startTime 和 endTime 都在 -i 前时，clipDuration 是 endTime - startTime
      // 当只有 startTime 时，clipDuration = totalDuration - startTime
      // 当只有 endTime 时，clipDuration = endTime
      final clipDuration = (startTime != null && endTime != null)
          ? (endTime - startTime).toDouble()
          : (startTime != null && totalDuration != null)
              ? (totalDuration - startTime).toDouble()
              : (endTime?.toDouble() ?? totalDuration ?? 0.0);
      final result = await _runFfmpegWithProgress(taskId, args, '提取音频', totalDuration: clipDuration);
      // 供调度循环把运行时改写的扩展名传播给下游步骤的 input
      if (result['success'] == true) result['_actual_output'] = output;
      return result;
    } catch (e) {
      addLog('提取音频异常: $e', category: 'error');
      return {'success': false, 'error': '提取音频异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runImageRotate(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final mode = p['rotate_mode'] as String? ?? 'fixed';
    var angle = (p['angle'] as num?)?.toDouble() ?? 0;
    final randomMin = (p['random_min'] as num?)?.toDouble() ?? 0;
    final randomMax = (p['random_max'] as num?)?.toDouble() ?? 360;

    if (mode == 'random') {
      angle = randomMin + _rng.nextDouble() * (randomMax - randomMin);
      addLog('图片旋转: 随机角度 ${angle.toStringAsFixed(1)}°', category: 'info');
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      String vf;
      if (angle == 90) {
        vf = 'transpose=1';
      } else if (angle == 180) {
        vf = 'transpose=1,transpose=1';
      } else if (angle == 270) {
        vf = 'transpose=2';
      } else {
        final radians = angle * pi / 180;
        vf = 'rotate=$radians:ow=rotw($radians):oh=roth($radians):c=black@0';
      }
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('图片旋转: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片旋转完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('图片旋转失败: $errMsg', category: 'error');
        return {'success': false, 'error': '图片旋转失败: $errMsg'};
      }
    } catch (e) {
      addLog('图片旋转异常: $e', category: 'error');
      return {'success': false, 'error': '图片旋转异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runImageScale(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final mode = p['scale_mode'] as String? ?? 'fixed';
    var factor = (p['scale_factor'] as num?)?.toDouble() ?? 1.0;
    final randomMin = (p['random_min'] as num?)?.toDouble() ?? 0.5;
    final randomMax = (p['random_max'] as num?)?.toDouble() ?? 2.0;

    if (mode == 'random') {
      factor = randomMin + _rng.nextDouble() * (randomMax - randomMin);
      addLog('图片缩放: 随机系数 ${factor.toStringAsFixed(2)}', category: 'info');
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final vf = 'scale=trunc(iw*$factor/2)*2:trunc(ih*$factor/2)*2';
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('图片缩放: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片缩放完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('图片缩放失败: $errMsg', category: 'error');
        return {'success': false, 'error': '图片缩放失败: $errMsg'};
      }
    } catch (e) {
      addLog('图片缩放异常: $e', category: 'error');
      return {'success': false, 'error': '图片缩放异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runImageBrightness(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final mode = p['brightness_mode'] as String? ?? 'fixed';
    var brightness = (p['brightness'] as num?)?.toDouble() ?? 0.0;
    final rangeMin = (p['range_min'] as num?)?.toDouble() ?? -0.5;
    final rangeMax = (p['range_max'] as num?)?.toDouble() ?? 0.5;

    if (mode == 'range') {
      brightness = rangeMin + _rng.nextDouble() * (rangeMax - rangeMin);
      addLog('图片亮度: 随机值 ${brightness.toStringAsFixed(2)}', category: 'info');
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final vf = 'eq=brightness=$brightness';
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('图片亮度: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片亮度调整完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('图片亮度调整失败: $errMsg', category: 'error');
        return {'success': false, 'error': '图片亮度调整失败: $errMsg'};
      }
    } catch (e) {
      addLog('图片亮度调整异常: $e', category: 'error');
      return {'success': false, 'error': '图片亮度调整异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runImageNoise(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final mode = p['noise_mode'] as String? ?? 'fixed';
    var strength = (p['noise_strength'] as num?)?.toInt() ?? 50;
    final noiseType = p['noise_type'] as String? ?? 't';
    final randomMin = (p['random_min'] as num?)?.toInt() ?? 10;
    final randomMax = (p['random_max'] as num?)?.toInt() ?? 100;

    if (mode == 'random') {
      // randomMax < randomMin 时 nextInt 抛异常，先夹取保证范围合法
      final lo = randomMin < randomMax ? randomMin : randomMax;
      final hi = randomMax > randomMin ? randomMax : randomMin;
      strength = lo + _rng.nextInt(hi - lo + 1);
      addLog('图片噪声: 随机强度 $strength', category: 'info');
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final vf = 'noise=alls=$strength:allf=$noiseType';
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('图片噪声: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片噪声添加完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('图片噪声添加失败: $errMsg', category: 'error');
        return {'success': false, 'error': '图片噪声添加失败: $errMsg'};
      }
    } catch (e) {
      addLog('图片噪声添加异常: $e', category: 'error');
      return {'success': false, 'error': '图片噪声添加异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runImageSharpen(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final mode = p['sharpen_mode'] as String? ?? 'fixed';
    var strength = (p['sharpen_strength'] as num?)?.toDouble() ?? 1.0;
    final randomMin = (p['random_min'] as num?)?.toDouble() ?? 0.5;
    final randomMax = (p['random_max'] as num?)?.toDouble() ?? 3.0;

    if (mode == 'random') {
      strength = randomMin + _rng.nextDouble() * (randomMax - randomMin);
      addLog('图片锐化: 随机强度 ${strength.toStringAsFixed(2)}', category: 'info');
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final vf = 'unsharp=5:5:$strength:5:5:0';
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('图片锐化: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片锐化完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('图片锐化失败: $errMsg', category: 'error');
        return {'success': false, 'error': '图片锐化失败: $errMsg'};
      }
    } catch (e) {
      addLog('图片锐化异常: $e', category: 'error');
      return {'success': false, 'error': '图片锐化异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runImageDenoise(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final method = p['denoise_method'] as String? ?? 'hqdn3d';
    final mode = p['denoise_mode'] as String? ?? 'fixed';
    var strength = (p['denoise_strength'] as num?)?.toDouble() ?? 4.0;
    final randomMin = (p['random_min'] as num?)?.toDouble() ?? 1.0;
    final randomMax = (p['random_max'] as num?)?.toDouble() ?? 10.0;

    if (mode == 'random') {
      strength = randomMin + _rng.nextDouble() * (randomMax - randomMin);
      addLog('图片降噪: 随机强度 ${strength.toStringAsFixed(2)}', category: 'info');
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      String vf;
      if (method == 'hqdn3d') {
        vf = 'hqdn3d=$strength:$strength';
      } else {
        vf = 'nlmeans=s=$strength';
      }
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('图片降噪: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片降噪完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('图片降噪失败: $errMsg', category: 'error');
        return {'success': false, 'error': '图片降噪失败: $errMsg'};
      }
    } catch (e) {
      addLog('图片降噪异常: $e', category: 'error');
      return {'success': false, 'error': '图片降噪异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runImageChannelExtract(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final channel = p['channel'] as String? ?? 'r';
    final method = p['extract_method'] as String? ?? 'isolate';

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      String vf;
      if (method == 'isolate') {
        vf = 'extractplanes=$channel';
      } else {
        // colorize method
        switch (channel) {
          case 'r':
            vf = 'colorchannelmixer=rr=1:rg=0:rb=0:gr=0:gg=0:gb=0:br=0:bg=0:bb=0';
            break;
          case 'g':
            vf = 'colorchannelmixer=rr=0:rg=0:rb=0:gr=0:gg=1:gb=0:br=0:bg=0:bb=0';
            break;
          case 'b':
            vf = 'colorchannelmixer=rr=0:rg=0:rb=0:gr=0:gg=0:gb=0:br=0:bg=0:bb=1';
            break;
          default:
            vf = 'colorchannelmixer=rr=1:rg=0:rb=0:gr=0:gg=0:gb=0:br=0:bg=0:bb=0';
        }
      }
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('通道提取: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('通道提取完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        final stderr = (result.stderr as String).trim();
        final lastLines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final errMsg = lastLines.length > 3 ? lastLines.sublist(lastLines.length - 3).join('; ') : stderr;
        addLog('通道提取失败: $errMsg', category: 'error');
        return {'success': false, 'error': '通道提取失败: $errMsg'};
      }
    } catch (e) {
      addLog('通道提取异常: $e', category: 'error');
      return {'success': false, 'error': '通道提取异常: $e'};
    }
  }


  Future<Map<String, dynamic>> _runFileCopy(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      await File(input).copy(output);
      addLog('直接复制: $input → $output', category: 'info');
      return {'success': true, 'data': {'output_path': output}};
    } catch (e) {
      addLog('文件复制失败: $e', category: 'error');
      return {'success': false, 'error': '文件复制失败: $e'};
    }
  }

  Future<Map<String, dynamic>> _runAudioMetadata(String taskId, Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final coverPath = p['cover_path'] as String? ?? '';
    final lyricsPath = p['lyrics_path'] as String? ?? '';
    final removeCover = p['remove_cover'] as bool? ?? false;
    final removeLyrics = p['remove_lyrics'] as bool? ?? false;

    String? lyricsContent;
    if (lyricsPath.isNotEmpty) {
      try { lyricsContent = await File(lyricsPath).readAsString(); } catch (_) {}
    }

    final opts = <String, dynamic>{
      'video_codec': 'none',
      'audio_codec': 'copy',
      'overwrite': true,
    };

    if (coverPath.isNotEmpty) opts['cover_input'] = coverPath;
    if (lyricsContent != null) opts['metadata'] = {'lyrics': lyricsContent};
    if (removeCover) opts['remove_cover'] = true;
    if (removeLyrics) opts['remove_lyrics'] = true;
    // 即使无元数据改动仍执行 copy 透传，保证输出文件真实存在，下游链路不断链。
    return await backend.transcode(taskId, input: input, output: output, options: opts);
  }

  static String _loopPath(String path, int iteration) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot < 0) return '${path}_loop_$iteration';
    return '${path.substring(0, lastDot)}_loop_$iteration${path.substring(lastDot)}';
  }

  /// 合并/图片序列步骤的多文件解析：输入是目录（如上一步抽帧生成的帧目录）时列出其中文件，
  /// 是文件时作为单元素列表；均不匹配时返回空列表，由后端给出明确错误。
  Future<List<String>> _resolveMergeFiles(String? input) async {
    if (input == null || input.isEmpty) return const <String>[];
    final dir = Directory(input);
    if (dir.existsSync()) {
      final files = dir.listSync().whereType<File>().map((f) => f.path).toList();
      files.sort();
      return files;
    }
    if (File(input).existsSync()) return [input];
    return const <String>[];
  }

  void _cleanupTempFiles(List<BackendCall> cleanupCalls) {
    for (final c in cleanupCalls) {
      final path = c.params['path'] as String?;
      if (path != null) {
        try {
          if (Directory(path).existsSync()) {
            Directory(path).deleteSync(recursive: true);
          } else {
            File(path).deleteSync();
          }
        } catch (_) {}
      }
    }
  }

  void cancelProcessing() {
    // 设置取消标记，阻止 processNextTask 继续拉取队列里剩余的 pending 任务；
    // 否则正在跑的 .then 回调回来后看到还有 pending 任务就会立刻重启队列，
    // 「停止所有」就失效了。
    _cancelRequested = true;
    // 携带任务 id 集合：后端 worker 处理这些任务前会直接跳过
    // （否则「停止所有」后，C++ 单线程 worker 仍会执行队列中剩余任务）
    final ids = _tasks
        .where((t) => t.status == TaskStatus.processing || t.status == TaskStatus.pending)
        .map((t) => t.id)
        .toList();
    backend.cancel(ids);
    // 终止本地直接启动的 ffmpeg 进程（video_crop/extract_audio 等不走 C++ 后端）
    for (final p in _localFfmpegProcesses.toList()) {
      try { p.kill(); } catch (_) {}
    }
    for (int i = 0; i < _tasks.length; i++) {
      final st = _tasks[i].status;
      if (st == TaskStatus.processing || st == TaskStatus.pending) {
        _tasks[i] = _tasks[i].copyWith(status: TaskStatus.cancelled);
      }
    }
    _runningTaskIds.clear(); _currentTaskId = null; notifyListeners();
  }

  /// 只取消单个任务：其余 pending/processing 任务继续，不影响全局取消标记。
  void cancelTask(String taskId) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i < 0) return;
    final st = _tasks[i].status;
    if (st != TaskStatus.processing && st != TaskStatus.pending) return;
    // 标记"该任务被取消"，让 pipeline 循环与在途回调不再把它写成终态
    _cancelledTaskIds.add(taskId);
    // 通知后端跳过该任务（若仍在队列/未开始）
    backend.cancel([taskId]);
    // 终止该任务名下本地直接启动的 ffmpeg 进程（帧提取/音频提取/裁剪等）
    final procs = _localProcessesByTask[taskId];
    if (procs != null) {
      for (final p in procs.toList()) {
        try { p.kill(); } catch (_) {}
      }
    }
    // 从运行序列移除，释放 slots 让队列继续拉取下一个 pending 任务
    _runningTaskIds.remove(taskId);
    if (_currentTaskId == taskId) _currentTaskId = null;
    _tasks[i] = _tasks[i].copyWith(status: TaskStatus.cancelled);
    notifyListeners();
    if (!_cancelRequested && _tasks.any((t) => t.status == TaskStatus.pending)) {
      processNextTask();
    }
  }

  void clearCompletedTasks() { _tasks.removeWhere((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed || t.status == TaskStatus.cancelled); notifyListeners(); }
  void removeTask(String id) { _tasks.removeWhere((t) => t.id == id); notifyListeners(); }
  void clearAllTasks() { if (!processing) { _tasks.clear(); notifyListeners(); } }
  void toggleTaskExpanded(String tid) { final i = _tasks.indexWhere((t) => t.id == tid); if (i >= 0) { _tasks[i] = _tasks[i].copyWith(expanded: !_tasks[i].expanded); notifyListeners(); } }

  Future<void> toggleDarkMode(bool v) async { await configService.update((c) => c..darkMode = v); notifyListeners(); }
  Future<void> updateConfig(AppConfig Function(AppConfig) f) async { await configService.update(f); notifyListeners(); }

  Future<Map<String, dynamic>> recheckEnv() async {
    addLog('检测 FFmpeg 环境...', category: 'info');
    await backend.setPaths(ffmpeg: config.ffmpegPath, ffprobe: config.ffprobePath);
    final env = await backend.checkEnv();
    _envChecked = true; _envOk = env['success'] == true && (env['data']?['all_ok'] as bool? ?? false);
    // C++ handleCheckEnv 返回嵌套结构：data.ffmpeg.version / data.ffmpeg.path
    final ffmpegInfo = env['data']?['ffmpeg'] as Map<String, dynamic>?;
    _ffmpegVersion = ffmpegInfo?['version'] as String? ?? '';
    if (_envOk) {
      addLog('FFmpeg 环境正常: $_ffmpegVersion', category: 'info');
      final path = ffmpegInfo?['path'] as String?;
      if (path != null && path.isNotEmpty) addLog('  路径: $path', category: 'info');
    } else {
      addLog('FFmpeg 环境异常: ${env['error'] ?? '未知错误'}', category: 'error');
    }
    notifyListeners(); return env;
  }

  // ── MCP Server ──
  HttpServer? _mcpServer;
  bool get mcpRunning => _mcpServer != null;
  String? mcpError;
  // 非回环监听（暴露到局域网）时要求的访问令牌；回环为 null（无需令牌）
  String? _mcpToken;
  String? get mcpToken => _mcpToken;

  PipelineGraph? _currentPipelineGraph;
  void setCurrentPipeline(PipelineGraph g) { _currentPipelineGraph = g; }
  VoidCallback? mcpOnClearAll, mcpOnUndo, mcpOnRedo, mcpOnSave;
  bool Function(String nodeId, Map<String, dynamic> params)? mcpOnModifyNode;
  String Function(String type, double x, double y)? mcpOnAddNode;
  String Function(String gateType, double x, double y)? mcpOnAddGate;
  void Function(String nodeId)? mcpOnDeleteNode;
  bool Function(String fromId, String toId)? mcpOnConnect;
  bool Function(String connId)? mcpOnDisconnect;
  List<Map<String, dynamic>> Function()? mcpOnListNodes;
  List<Map<String, dynamic>> Function()? mcpOnListConnections;

  Future<bool> startMcpServer() async {
    if (_mcpServer != null) return true;
    try {
      final port = config.mcpPort;
      // 监听地址：默认仅回环（本机安全），用户可在设置中改为 0.0.0.0 暴露到局域网
      final host = config.mcpHost.isEmpty ? '127.0.0.1' : config.mcpHost;
      const loopbackHosts = {'127.0.0.1', 'localhost', '::1'};
      final isLoopback = loopbackHosts.contains(host);
      final addr = host == '0.0.0.0' ? InternetAddress.anyIPv4 : InternetAddress(host);
      // 暴露到局域网时必须校验 Bearer token，否则任何人都可枚举本机文件系统
      _mcpToken = isLoopback ? null : _generateMcpToken();
      _mcpServer = await HttpServer.bind(addr, port);
      mcpError = null;
      if (isLoopback) {
        addLog('[MCP] 服务已启动 (仅本机)，端口: $port', category: 'info');
      } else {
        addLog('[MCP] 服务已启动 (监听 $host:$port)，访问令牌: $_mcpToken — 请勿泄露', category: 'warning');
      }
      _mcpServer!.listen((req) {
        _handleMcpRequest(req);
      }, onError: (e) {
        addLog('[MCP] 连接错误: $e', category: 'error');
      }, onDone: () {
        addLog('[MCP] 服务已停止', category: 'info');
        _mcpServer = null;
        notifyListeners();
      });
      notifyListeners();
      return true;
    } catch (e) {
      final msg = e is SocketException ? '端口 ${config.mcpPort} 被占用' : '$e';
      mcpError = msg;
      addLog('[MCP] 启动失败: $msg', category: 'error');
      _mcpServer = null;
      notifyListeners();
      return false;
    }
  }

  Future<void> stopMcpServer() async {
    if (_mcpServer == null) return;
    await _mcpServer!.close();
    _mcpServer = null;
    addLog('[MCP] 服务已停止', category: 'info');
    notifyListeners();
  }

  String _generateMcpToken() {
    final rand = Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final buf = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buf.write(alphabet[rand.nextInt(alphabet.length)]);
    }
    return buf.toString();
  }

  void _handleMcpRequest(HttpRequest req) async {
    addLog('[MCP] ${req.method} ${req.uri.path}', category: 'info');
    if (req.method != 'POST') {
      req.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.contentType = ContentType.json
        ..write('{"jsonrpc":"2.0","error":{"code":-32600,"message":"Only POST allowed"}}');
      await req.response.close();
      return;
    }
    // 非回环监听时校验访问令牌，防止局域网内未授权枚举文件系统
    final token = _mcpToken;
    if (token != null) {
      final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
      final xToken = req.headers.value('x-mcp-token') ?? '';
      final provided = xToken.isNotEmpty
          ? xToken
          : (auth.startsWith('Bearer ') ? auth.substring(7) : '');
      if (provided != token) {
        addLog('[MCP] 拒绝未授权请求 (${req.connectionInfo?.remoteAddress})', category: 'warning');
        req.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.contentType = ContentType.json
          ..write('{"jsonrpc":"2.0","error":{"code":-32000,"message":"Unauthorized: missing or invalid x-mcp-token header"}}');
        await req.response.close();
        return;
      }
    }
    try {
      final body = await utf8.decoder.bind(req).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final id = json['id'];
      final method = json['method'] as String? ?? '';
      final params = json['params'] as Map<String, dynamic>? ?? {};
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json;
      switch (method) {
        case 'initialize':
          req.response.write(jsonEncode({
            'jsonrpc': '2.0', 'id': id,
            'result': {
              'protocolVersion': '2024-11-05',
              'capabilities': {'tools': {}, 'resources': {}},
              'serverInfo': {'name': 'ffmpegpp', 'version': '5.0.0-beta2'},
            },
          }));
          break;
        case 'tools/list':
          req.response.write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {'tools': _mcpToolsList()}}));
          break;
        case 'tools/call':
          final toolName = params['name'] as String? ?? '';
          final args = params['arguments'] as Map<String, dynamic>? ?? {};
          final (result, isError) = await _mcpCallTool(toolName, args);
          req.response.write(jsonEncode({
            'jsonrpc': '2.0', 'id': id,
            'result': {'content': [{'type': 'text', 'text': result}], if (isError) 'isError': true},
          }));
          break;
        case 'resources/list':
          req.response.write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {'resources': _mcpResourcesList()}}));
          break;
        case 'resources/read':
          final uri = params['uri'] as String? ?? '';
          final result = _mcpReadResource(uri);
          req.response.write(jsonEncode({
            'jsonrpc': '2.0', 'id': id,
            'result': {'contents': [{'uri': uri, 'mimeType': 'application/json', 'text': result}]},
          }));
          break;
        default:
          req.response.write(jsonEncode({
            'jsonrpc': '2.0', 'id': id,
            'error': {'code': -32601, 'message': 'Method not found: $method'},
          }));
      }
      await req.response.close();
    } catch (e) {
      addLog('[MCP] Error: $e', category: 'error');
      req.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write('{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}');
      await req.response.close();
    }
  }

  List<Map<String, dynamic>> _mcpToolsList() => [
    {'name': 'clear_all', 'description': 'Clear all nodes from canvas', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'undo', 'description': 'Undo last action', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'redo', 'description': 'Redo last action', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'save', 'description': 'Save current pipeline', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'list_directory', 'description': 'List files in a directory (read-only)', 'inputSchema': {'type': 'object', 'properties': {'path': {'type': 'string', 'description': 'Directory path'}}, 'required': ['path']}},
    {'name': 'read_file_info', 'description': 'Get file metadata (read-only)', 'inputSchema': {'type': 'object', 'properties': {'path': {'type': 'string', 'description': 'File path'}}, 'required': ['path']}},
    {'name': 'modify_node_params', 'description': 'Modify node parameters', 'inputSchema': {'type': 'object', 'properties': {'nodeId': {'type': 'string'}, 'params': {'type': 'object'}}, 'required': ['nodeId', 'params']}},
    {'name': 'error_check', 'description': 'Check pipeline for logical errors', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'add_node', 'description': 'Add a processing node to the pipeline canvas. Returns new node ID.', 'inputSchema': {'type': 'object', 'properties': {'type': {'type': 'string', 'description': 'Node type', 'enum': PipelineStepType.values.map((t) => t.name).toList()}, 'x': {'type': 'number', 'description': 'X position (default 200)'}, 'y': {'type': 'number', 'description': 'Y position (default 200)'}}, 'required': ['type']}},
    {'name': 'delete_node', 'description': 'Delete a node by ID (also removes its connections)', 'inputSchema': {'type': 'object', 'properties': {'nodeId': {'type': 'string'}}, 'required': ['nodeId']}},
    {'name': 'connect_nodes', 'description': 'Connect two nodes (from output to input)', 'inputSchema': {'type': 'object', 'properties': {'fromNodeId': {'type': 'string'}, 'toNodeId': {'type': 'string'}}, 'required': ['fromNodeId', 'toNodeId']}},
    {'name': 'disconnect_nodes', 'description': 'Remove a connection by ID', 'inputSchema': {'type': 'object', 'properties': {'connectionId': {'type': 'string'}}, 'required': ['connectionId']}},
    {'name': 'list_nodes', 'description': 'List all nodes in the current pipeline with their IDs, types, params and positions', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'list_connections', 'description': 'List all connections in the current pipeline', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'get_node_types', 'description': 'List all available node types', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'probe_video', 'description': 'Probe a video file and return its metadata (codec, resolution, duration, etc.)', 'inputSchema': {'type': 'object', 'properties': {'filepath': {'type': 'string'}}, 'required': ['filepath']}},
    {'name': 'list_tasks', 'description': 'List all tasks with their status, progress and details', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'cancel_tasks', 'description': 'Cancel all running tasks', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'list_containers', 'description': 'List all media containers with id, name, file count and pipeline node count (read-only)', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'get_container_pipeline', 'description': 'Get the pipeline graph JSON of a container (read-only)', 'inputSchema': {'type': 'object', 'properties': {'containerId': {'type': 'string', 'description': 'Container id from list_containers'}}, 'required': ['containerId']}},
    {'name': 'list_standalone_videos', 'description': 'List videos that are not inside any container (read-only)', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'add_gate', 'description': 'Add a logic gate node (and/or/not/nand/nor/const1/const0/time_trigger) to the canvas. Returns new node ID.', 'inputSchema': {'type': 'object', 'properties': {'type': {'type': 'string', 'description': 'Gate type: and, or, not, nand, nor, const1, const0, time_trigger'}, 'x': {'type': 'number', 'description': 'X position (default 200)'}, 'y': {'type': 'number', 'description': 'Y position (default 200)'}}, 'required': ['type']}},
    {'name': 'set_gate_params', 'description': 'Set logic gate parameters (e.g. tt_date/tt_start/tt_end for time_trigger)', 'inputSchema': {'type': 'object', 'properties': {'nodeId': {'type': 'string'}, 'params': {'type': 'object'}}, 'required': ['nodeId', 'params']}},
    {'name': 'get_gate_types', 'description': 'List all available logic gate types (read-only)', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'get_graph_stats', 'description': 'Get canvas statistics: node count, gate count, connection count (read-only)', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'read_logs', 'description': 'Read recent application logs (read-only)', 'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'get_task_info', 'description': 'Get detailed info of a specific task by ID', 'inputSchema': {'type': 'object', 'properties': {'taskId': {'type': 'string', 'description': 'Task ID from list_tasks'}}, 'required': ['taskId']}},
    {'name': 'rename_node', 'description': 'Set a custom name for a node on the canvas', 'inputSchema': {'type': 'object', 'properties': {'nodeId': {'type': 'string'}, 'name': {'type': 'string', 'description': 'New custom name'}}, 'required': ['nodeId', 'name']}},
  ];

  List<Map<String, dynamic>> _mcpResourcesList() => [
    {'uri': 'pipeline://current', 'name': 'Current Pipeline', 'mimeType': 'application/json'},
    {'uri': 'videos://loaded', 'name': 'Loaded Videos', 'mimeType': 'application/json'},
    {'uri': 'tasks://all', 'name': 'Task Queue', 'mimeType': 'application/json'},
  ];

  Future<(String, bool)> _mcpCallTool(String name, Map<String, dynamic> args) async {
    // 写操作需在设置里开启 MCP 写入权限（默认只读，防止未经授权的修改）
    const writeTools = {'clear_all', 'undo', 'redo', 'save', 'modify_node_params', 'add_node', 'delete_node', 'connect_nodes', 'disconnect_nodes', 'cancel_tasks', 'add_gate', 'set_gate_params', 'rename_node'};
    if (writeTools.contains(name) && !config.mcpAllowWrite) {
      return ('Error: MCP write access is disabled — enable "Allow write" in Settings → AI', true);
    }
    switch (name) {
      case 'clear_all':
        if (mcpOnClearAll == null) return ('Error: No editor open — open a pipeline editor first', true);
        mcpOnClearAll!();
        return ('Canvas cleared', false);
      case 'undo':
        if (mcpOnUndo == null) return ('Error: No editor open — open a pipeline editor first', true);
        mcpOnUndo!();
        return ('Undo executed', false);
      case 'redo':
        if (mcpOnRedo == null) return ('Error: No editor open — open a pipeline editor first', true);
        mcpOnRedo!();
        return ('Redo executed', false);
      case 'save':
        if (mcpOnSave == null) return ('Error: No editor open — open a pipeline editor first', true);
        mcpOnSave!();
        return ('Save executed', false);
      case 'list_directory':
        final path = args['path'] as String? ?? '.';
        try {
          // 异步遍历，避免在 UI isolate 同步 listSync/statSync 卡界面
          final entries = <Map<String, dynamic>>[];
          await for (final e in Directory(path).list().take(50)) {
            FileSystemEntityType t;
            try { t = await FileSystemEntity.type(e.path); } catch (_) { t = FileSystemEntityType.notFound; }
            int size = 0;
            if (t != FileSystemEntityType.directory) {
              try { size = await File(e.path).length(); } catch (_) {}
            }
            entries.add({'name': e.uri.pathSegments.last, 'type': t == FileSystemEntityType.directory ? 'directory' : 'file', 'size': size});
          }
          return (jsonEncode(entries), false);
        } catch (e) { return ('Error: $e', true); }
      case 'read_file_info':
        final path = args['path'] as String? ?? '';
        try {
          final s = await File(path).stat();
          return (jsonEncode({'path': path, 'size': s.size, 'modified': s.modified.toIso8601String(), 'type': path.split('.').last}), false);
        } catch (e) { return ('Error: $e', true); }
      case 'modify_node_params':
        final nodeId = args['nodeId'] as String? ?? '';
        final params = args['params'] as Map<String, dynamic>? ?? {};
        if (mcpOnModifyNode == null) return ('Error: No editor open — open a pipeline editor first', true);
        if (mcpOnModifyNode!(nodeId, params)) {
          return ('Node $nodeId params updated', false);
        }
        return ('Error: node $nodeId not found on canvas', true);
      case 'error_check':
        if (_currentPipelineGraph == null) return ('Error: No pipeline loaded — open a pipeline editor first', true);
        final g = _currentPipelineGraph!;
        final errors = <String>[];
        if (!g.nodes.any((n) => n.type == PipelineStepType.start)) errors.add('Missing start node');
        if (!g.nodes.any((n) => n.type == PipelineStepType.output)) errors.add('Missing output node');
        final connectedIds = <String>{};
        for (final c in g.connections) { connectedIds.add(c.fromNodeId); connectedIds.add(c.toNodeId); }
        for (final n in g.nodes) {
          if (!connectedIds.contains(n.id) && g.nodes.length > 1) errors.add('Disconnected: ${n.type.name} (${n.id.substring(0, 8)})');
        }
        return (errors.isEmpty ? 'No errors found' : errors.join('; '), false);
      case 'add_node':
        if (mcpOnAddNode == null) return ('Error: No editor open', true);
        final typeName = args['type'] as String? ?? '';
        final x = (args['x'] as num?)?.toDouble() ?? 200;
        final y = (args['y'] as num?)?.toDouble() ?? 200;
        try {
          final nodeId = mcpOnAddNode!(typeName, x, y);
          return ('Node added: $nodeId (type: $typeName)', false);
        } catch (e) { return ('Error: $e', true); }
      case 'delete_node':
        if (mcpOnDeleteNode == null) return ('Error: No editor open', true);
        final nodeId = args['nodeId'] as String? ?? '';
        try { mcpOnDeleteNode!(nodeId); return ('Node $nodeId deleted', false); }
        catch (e) { return ('Error: $e', true); }
      case 'connect_nodes':
        if (mcpOnConnect == null) return ('Error: No editor open', true);
        final fromId = args['fromNodeId'] as String? ?? '';
        final toId = args['toNodeId'] as String? ?? '';
        final ok = mcpOnConnect!(fromId, toId);
        return ok ? ('Connected $fromId → $toId', false) : ('Error: Connection failed (invalid nodes or already connected)', true);
      case 'disconnect_nodes':
        if (mcpOnDisconnect == null) return ('Error: No editor open', true);
        final connId = args['connectionId'] as String? ?? '';
        final ok = mcpOnDisconnect!(connId);
        return ok ? ('Connection $connId removed', false) : ('Error: Connection not found', true);
      case 'list_nodes':
        if (mcpOnListNodes == null) return ('Error: No editor open', true);
        return (jsonEncode(mcpOnListNodes!()), false);
      case 'list_connections':
        if (mcpOnListConnections == null) return ('Error: No editor open', true);
        return (jsonEncode(mcpOnListConnections!()), false);
      case 'get_node_types':
        final types = PipelineStepType.values.map((t) => {'name': t.name, 'label': PipelineStep(id: '', type: t).labelEn}).toList();
        return (jsonEncode(types), false);
      case 'probe_video':
        final path = args['filepath'] as String? ?? '';
        if (path.isEmpty) return ('Error: filepath required', true);
        try {
          final resp = await backend.probe(path);
          if (resp['success'] == true) {
            return (jsonEncode(resp['data'] ?? resp), false);
          }
          return ('Error: ${resp['error'] ?? 'probe failed'}', true);
        } catch (e) { return ('Error: $e', true); }
      case 'list_tasks':
        final taskList = tasks.map((t) => {
          'id': t.id, 'filename': t.filename, 'status': t.status.name,
          'progress': t.progress.toStringAsFixed(1),
          'elapsed': t.elapsed, 'remaining': t.remaining,
          'speed': t.speed, if (t.error != null) 'error': t.error,
        }).toList();
        return (jsonEncode(taskList), false);
      case 'cancel_tasks':
        cancelProcessing();
        return ('All running tasks cancelled', false);
      case 'list_containers':
        return (jsonEncode(_containers.map((c) => {
          'id': c.id,
          'name': c.name,
          'fileCount': c.fileCount,
          'nodeCount': c.pipelineGraph.nodes.length,
          'connectionCount': c.pipelineGraph.connections.length,
          'files': c.sortedItems.map((i) => i.fileId).toList(),
        }).toList()), false);
      case 'get_container_pipeline':
        final cid = args['containerId'] as String? ?? '';
        final ci = _containers.indexWhere((c) => c.id == cid);
        if (ci < 0) return ('Error: container not found: $cid', true);
        return (jsonEncode(_containers[ci].pipelineGraph.toJson()), false);
      case 'list_standalone_videos':
        return (jsonEncode(standaloneVideos.map((v) => {
          'id': v.id, 'filename': v.filename, 'format': v.format,
          'size_mb': v.sizeMb, 'duration': v.duration, 'codec': v.codec,
          'resolution': v.resolution,
        }).toList()), false);
      case 'add_gate':
        if (mcpOnAddGate == null) return ('Error: No editor open', true);
        final gateType = args['type'] as String? ?? '';
        final gx = (args['x'] as num?)?.toDouble() ?? 200;
        final gy = (args['y'] as num?)?.toDouble() ?? 200;
        try {
          final nodeId = mcpOnAddGate!(gateType, gx, gy);
          return ('Gate added: $nodeId (type: $gateType)', false);
        } catch (e) { return ('Error: $e', true); }
      case 'set_gate_params':
        if (mcpOnModifyNode == null) return ('Error: No editor open', true);
        final nodeId = args['nodeId'] as String? ?? '';
        final params = args['params'] as Map<String, dynamic>? ?? {};
        if (mcpOnModifyNode!(nodeId, params)) {
          return ('Gate $nodeId params updated', false);
        }
        return ('Error: node $nodeId not found', true);
      case 'get_gate_types':
        final types = LogicGateType.values.map((t) => t.name).toList();
        return (jsonEncode(types), false);
      case 'get_graph_stats':
        if (_currentPipelineGraph == null) return (jsonEncode({'nodes': 0, 'gates': 0, 'connections': 0}), false);
        final g = _currentPipelineGraph!;
        return (jsonEncode({
          'nodes': g.nodes.length,
          'gates': g.nodes.where((n) => n.isGate).length,
          'connections': g.connections.length,
          'start': g.nodes.where((n) => n.type == PipelineStepType.start).length,
          'output': g.nodes.where((n) => n.type == PipelineStepType.output).length,
        }), false);
      case 'read_logs':
        final recent = _logEntries.length > 30 ? _logEntries.sublist(_logEntries.length - 30) : _logEntries;
        return (jsonEncode(recent.map((l) => {
          'time': '${l.timestamp.hour.toString().padLeft(2, '0')}:${l.timestamp.minute.toString().padLeft(2, '0')}',
          'message': l.message,
          'category': l.category,
        }).toList()), false);
      case 'get_task_info':
        final taskId = args['taskId'] as String? ?? '';
        final task = _tasks.where((t) => t.id == taskId).firstOrNull;
        if (task == null) return ('Error: Task not found: $taskId', true);
        return (jsonEncode({
          'id': task.id, 'filename': task.filename, 'status': task.status.name,
          'progress': task.progress.toStringAsFixed(1),
          'inputPath': task.inputPath, 'outputPath': task.outputPath,
          if (task.error != null) 'error': task.error,
        }), false);
      case 'rename_node':
        if (mcpOnModifyNode == null) return ('Error: No editor open', true);
        final nid = args['nodeId'] as String? ?? '';
        final name = args['name'] as String? ?? '';
        if (mcpOnModifyNode!(nid, {'node_name': name})) {
          return ('Node $nid renamed to "$name"', false);
        }
        return ('Error: node $nid not found', true);
      default: return ('Unknown tool: $name', true);
    }
  }

  String _mcpReadResource(String uri) {
    switch (uri) {
      case 'pipeline://current':
        return jsonEncode(_currentPipelineGraph?.toJson() ?? {'nodes': [], 'connections': []});
      case 'videos://loaded':
        return jsonEncode(videos.map((v) => {'id': v.id, 'filename': v.filename, 'format': v.format, 'size_mb': v.sizeMb, 'duration': v.duration, 'codec': v.codec, 'resolution': v.resolution}).toList());
      case 'tasks://all':
        return jsonEncode(tasks.map((t) => {'id': t.id, 'filename': t.filename, 'status': t.status.name, 'progress': t.progress, 'elapsed': t.elapsed, 'remaining': t.remaining}).toList());
      default: return '{"error": "Unknown resource: $uri"}';
    }
  }

  Future<void> toggleMcpServer(bool enable) async {
    await updateConfig((c) => c..mcpEnabled = enable);
    if (enable) {
      await startMcpServer();
    } else {
      mcpError = null;
      await stopMcpServer();
    }
  }

  // ── AI Logging ──
  void logAiRequest(String userMessage) {
    addLog('[AI] 用户: $userMessage', category: 'info');
  }

  void logAiResponse(String response, {bool error = false}) {
    final preview = response.length > 200 ? '${response.substring(0, 200)}...' : response;
    addLog('[AI] ${error ? '错误' : '回复'}: $preview', category: error ? 'error' : 'info');
  }

  void logAiGraphApplied(int nodeCount, int connectionCount) {
    addLog('[AI] 已应用节点图: $nodeCount 个节点, $connectionCount 条连接', category: 'info');
  }

  Future<void> shutdown() async {
    // 配置写盘是防抖的，退出前必须强制落盘，否则最后一次修改会丢失
    await configService.flush();
    await stopMcpServer();
    await pythonProcess.shutdown();
  }

  @override
  void dispose() { configService.dispose(); backend.dispose(); pythonProcess.dispose(); super.dispose(); }
}
