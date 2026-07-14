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

class AppState extends ChangeNotifier {
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

  // ── Log entries ──
  final List<LogEntry> _logEntries = [];
  bool _logNotifyPending = false;
  List<LogEntry> get logEntries => List.unmodifiable(_logEntries);
  void addLog(String message, {String category = 'general'}) {
    _logEntries.add(LogEntry(timestamp: DateTime.now(), message: message, category: category));
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

  void _writeLogToFile(String message, String category) {
    try {
      final dir = Directory(config.logSavePath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final date = DateTime.now();
      final file = File('${dir.path}${Platform.pathSeparator}ffmpegpp_${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}.log');
      final ts = date.toIso8601String().substring(11, 23);
      file.writeAsStringSync('[$ts][$category] $message\n', mode: FileMode.append);
    } catch (_) {}
  }

  // ── FFmpeg features ──
  Map<String, List<String>> _ffmpegFeatures = {};
  Map<String, List<String>> get ffmpegFeatures => _ffmpegFeatures;
  bool get featuresDetected => _ffmpegFeatures.isNotEmpty;
  Future<void> queryFeatures() async {
    addLog('正在查询 FFmpeg 支持的功能...', category: 'info');
    final resp = await backend.queryFeatures();
    if (resp['success'] == true) {
      final data = resp['data'] as Map<String, dynamic>;
      _ffmpegFeatures = data.map((k, v) => MapEntry(k, (v as List).cast<String>()));
      addLog('功能查询完成: ${_ffmpegFeatures.keys.join(', ')}', category: 'info');
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
    _autoDetectLocalFfmpeg();
    recheckEnv();
    if (config.mcpEnabled) startMcpServer();
    _initialized = true;
    notifyListeners();
  }

  void _autoDetectLocalFfmpeg() {
    final exeDir = Directory(Platform.resolvedExecutable).parent.path;
    final ffmpegName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final ffprobeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    final localFfmpeg = File('$exeDir${Platform.pathSeparator}$ffmpegName');
    final localFfprobe = File('$exeDir${Platform.pathSeparator}$ffprobeName');
    bool changed = false;
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
    if (changed) {
      recheckEnv();
    }
  }

  void _setupLogListeners() {
    double _lastProgressLog = -1;
    // stdout messages (typed: progress, audit, error, etc.)
    pythonProcess.responses.listen((obj) {
      final t = obj['type'] as String? ?? '';
      if (t == 'progress') {
        final p = (obj['progress'] as num?)?.toDouble() ?? 0;
        final speed = obj['speed'] as String? ?? '';
        // 只在进度变化 >=5% 或转码完成时记录，避免刷屏
        if (p > 0 && (p - _lastProgressLog >= 5 || p >= 100)) {
          _lastProgressLog = p;
          addLog('进度: ${p.toStringAsFixed(0)}% $speed', category: 'progress');
        }
        if (p == 0) _lastProgressLog = 0;
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
      final timeMatch = RegExp(r'time=(\d{2}:\d{2}:\d{2})').firstMatch(line);
      final speedMatch = RegExp(r'speed=\s*([\d.]+)x').firstMatch(line);
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

    // 先全部加入列表（立即显示占位卡片），再逐个探测
    final entries = <VideoFile>[];
    for (final fp in filepaths) {
      final vf = VideoFile.fromFilepath(fp);
      _videos.add(vf);
      entries.add(vf);
    }
    notifyListeners();

    await _probeAll(entries);

    _probeCount--; notifyListeners();
  }

  Future<void> _probeAll(List<VideoFile> entries) async {
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

  Future<void> _probeOne(VideoFile vf) async {
    addLog('探测: ${vf.filename}', category: 'info');
    try {
      final resp = await backend.probe(vf.filepath);
      if (resp['success'] == true) {
        final info = resp['data'] as Map<String, dynamic>;
        final idx = _videos.indexWhere((v) => v.id == vf.id);
        if (idx >= 0) { _videos[idx] = VideoFile.fromProbeResult(vf.filepath, info, id: vf.id); _probeErrors.remove(vf.filepath); notifyListeners(); }
        addLog('探测成功: ${vf.filename}', category: 'ffmpeg');
        addLog('  编码: ${info['codec']} | 分辨率: ${info['resolution']} | 帧率: ${info['fps']}fps', category: 'ffmpeg');
        addLog('  时长: ${info['duration_str']} | 大小: ${(info['size_mb'] as num?)?.toStringAsFixed(1) ?? '?'}MB | 像素: ${info['pix_fmt']}', category: 'ffmpeg');
        addLog('  音频: ${info['audio_codec']} ${info['audio_channels']}ch ${info['audio_sample_rate']}Hz', category: 'ffmpeg');
        if (info['has_subtitles'] == true) addLog('  字幕: ${info['subtitle_count']} 轨道', category: 'ffmpeg');
        if (info['is_hdr'] == true) addLog('  HDR: 是', category: 'ffmpeg');
      } else { _probeErrors[vf.filepath] = resp['error'] as String? ?? 'Unknown'; notifyListeners(); addLog('探测失败: ${resp['error']}', category: 'error'); }
    } catch (e) { _probeErrors[vf.filepath] = 'Error: $e'; notifyListeners(); addLog('探测异常: $e', category: 'error'); }
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
      for (final item in c.items) ids.add(item.fileId);
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
    items.sort((a, b) {
      final va = _videos.where((v) => v.id == a.fileId).firstOrNull;
      final vb = _videos.where((v) => v.id == b.fileId).firstOrNull;
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
      id: 'task_${_tasks.length}_${DateTime.now().millisecondsSinceEpoch}',
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
    _tasks.add(TaskInfo(id: 'task_${_tasks.length}_${DateTime.now().millisecondsSinceEpoch}', videoId: videoId, filename: video.filename, inputPath: video.filepath, outputPath: out, config: cfg));
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
      final label = plans.length > 1 ? '${video.filename} [任务${i + 1}]' : video.filename;
      _tasks.add(TaskInfo(
        id: 'task_${_tasks.length}_${DateTime.now().millisecondsSinceEpoch}',
        videoId: video.id,
        filename: label,
        inputPath: video.filepath,
        outputPath: outputPath,
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
      id: 'task_${_tasks.length}_${DateTime.now().millisecondsSinceEpoch}',
      videoId: '',
      filename: filename,
      inputPath: inputPath,
      outputPath: outputPath,
      config: TranscodeConfig(),
      command: command.split(' '),
    ));
    notifyListeners();
  }

  void processSingleTask(String tid) {
    final limit = config.maxConcurrentTasks == 0 ? 999 : config.maxConcurrentTasks;
    if (_runningTaskIds.length >= limit) return;
    final i = _tasks.indexWhere((t) => t.id == tid);
    if (i < 0 || _tasks[i].status != TaskStatus.pending) return;
    final t = _tasks.removeAt(i); _tasks.insert(0, t);
    notifyListeners(); processNextTask();
  }

  void processAllTasks() { processNextTask(); }

  Future<void> processNextTask() async {
    final limit = config.maxConcurrentTasks == 0 ? 999 : config.maxConcurrentTasks;
    while (_runningTaskIds.length < limit) {
      final pi = _tasks.indexWhere((t) => t.status == TaskStatus.pending);
      if (pi < 0) break;
      final task = _tasks[pi];
      _runningTaskIds.add(task.id);
      _currentTaskId = task.id;
      _tasks[pi] = task.copyWith(status: TaskStatus.processing);
      notifyListeners();
      addLog('开始处理: ${task.filename}', category: 'info');
      addLog('输入: ${task.inputPath}', category: 'info');
      addLog('输出: ${task.outputPath}', category: 'info');
      _runTask(task).then((_) {
        _runningTaskIds.remove(task.id);
        if (_currentTaskId == task.id) _currentTaskId = null;
        if (_tasks.any((t) => t.status == TaskStatus.pending)) processNextTask();
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
        if (i >= 0) {
          _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: u.progress, elapsed: u.currentTime, remaining: u.remaining, speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame);
          notifyListeners();
        }
      }
    });

    Map<String, dynamic> resp;
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
    await sub.cancel();

    final fi = _tasks.indexWhere((t) => t.id == taskId);
    if (fi >= 0) {
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
        if (i >= 0) {
          _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: u.progress, elapsed: u.currentTime, remaining: u.remaining, speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame);
          notifyListeners();
        }
      }
    });

    // 自定义命令通过 transcode 接口发送，将命令拆分为 input/output/options
    // 解析命令提取 input 和 output 路径
    final cmdParts = task.command!;
    String inputPath = task.inputPath;
    String outputPath = task.outputPath;

    // 解析 -i 参数获取输入路径
    for (var i = 0; i < cmdParts.length; i++) {
      if (cmdParts[i] == '-i' && i + 1 < cmdParts.length) {
        inputPath = cmdParts[i + 1];
      }
    }
    // 最后一个非 - 开头的参数作为输出路径
    for (var i = cmdParts.length - 1; i >= 0; i--) {
      if (!cmdParts[i].startsWith('-')) {
        outputPath = cmdParts[i];
        break;
      }
    }

    // 使用 transcode 接口，但传入自定义命令选项
    final Map<String, dynamic> resp;
    resp = await backend.transcode(task.id, input: inputPath, output: outputPath, options: {
      'video_codec': 'copy',
      'audio_codec': 'copy',
      'overwrite': true,
      '_custom_command': cmdParts.join(' '),
    });

    await sub.cancel();

    final fi = _tasks.indexWhere((t) => t.id == taskId);
    if (fi >= 0) {
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
          for (final gc in group) {
            final p = gc.params;
            final loopParams = Map<String, dynamic>.from(p);
            // Rewrite output path
            final output = p['output'] as String? ?? '';
            if (output.isNotEmpty) {
              final newOutput = _loopPath(output, li + 1);
              pathMap[output] = newOutput;
              loopParams['output'] = newOutput;
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
        expandedCalls.add(call);
        ci2++;
      }
    }

    addLog('节点图任务: ${expandedCalls.length} 步', category: 'info');

    for (var ci = 0; ci < expandedCalls.length; ci++) {
      final call = expandedCalls[ci];
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
          if (i >= 0) {
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
        case 'audio_metadata':
          resp = await _runAudioMetadata(task.id, p);
          break;
        case 'concat':
          resp = await backend.concat(task.id,
              files: (p['files'] as List).cast<String>(),
              output: p['output'] as String,
              mode: p['mode'] as String? ?? 'copy',
              options: p['options'] as Map<String, dynamic>?);
          break;
        case 'image_sequence':
          resp = await backend.imageSequence(task.id,
              files: (p['files'] as List).cast<String>(),
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
      await sub.cancel();

      if (resp['success'] != true) {
        final fi2 = _tasks.indexWhere((t) => t.id == taskId);
        if (fi2 >= 0) {
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
    }

    final fi3 = _tasks.indexWhere((t) => t.id == taskId);
    if (fi3 >= 0) {
      final outFile = File(task.outputPath);
      final outSize = outFile.existsSync() ? outFile.lengthSync() : null;
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
      } else if (output.endsWith('.jpg') || output.endsWith('.jpeg') || output.endsWith('.webp')) {
        args.addAll(['-q:v', '${(100 - quality).clamp(0, 31) * 31 ~/ 100 + 1}']);
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

  Future<Map<String, dynamic>> _runImageRotate(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final mode = p['rotate_mode'] as String? ?? 'fixed';
    var angle = (p['angle'] as num?)?.toDouble() ?? 0;
    final randomMin = (p['random_min'] as num?)?.toDouble() ?? 0;
    final randomMax = (p['random_max'] as num?)?.toDouble() ?? 360;

    if (mode == 'random') {
      angle = randomMin + Random().nextDouble() * (randomMax - randomMin);
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
      factor = randomMin + Random().nextDouble() * (randomMax - randomMin);
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
      brightness = rangeMin + Random().nextDouble() * (rangeMax - rangeMin);
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
      strength = randomMin + Random().nextInt(randomMax - randomMin + 1);
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
      strength = randomMin + Random().nextDouble() * (randomMax - randomMin);
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
      strength = randomMin + Random().nextDouble() * (randomMax - randomMin);
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

    if (coverPath.isNotEmpty || lyricsContent != null || removeCover || removeLyrics) {
      if (coverPath.isNotEmpty) opts['cover_input'] = coverPath;
      if (lyricsContent != null) opts['metadata'] = {'lyrics': lyricsContent};
      if (removeCover) opts['remove_cover'] = true;
      if (removeLyrics) opts['remove_lyrics'] = true;
      return await backend.transcode(taskId, input: input, output: output, options: opts);
    }

    return {'success': true, 'data': {'output_path': output}};
  }

  static String _loopPath(String path, int iteration) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot < 0) return '${path}_loop_$iteration';
    return '${path.substring(0, lastDot)}_loop_$iteration${path.substring(lastDot)}';
  }

  void _cleanupTempFiles(List<BackendCall> cleanupCalls) {
    for (final c in cleanupCalls) {
      final path = c.params['path'] as String?;
      if (path != null) {
        try { File(path).deleteSync(); } catch (_) {}
      }
    }
  }

  void cancelProcessing() {
    backend.cancel();
    for (int i = 0; i < _tasks.length; i++) { if (_tasks[i].status == TaskStatus.processing) _tasks[i] = _tasks[i].copyWith(status: TaskStatus.cancelled); }
    _runningTaskIds.clear(); _currentTaskId = null; notifyListeners();
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
    _ffmpegVersion = env['data']?['ffmpeg_version'] as String? ?? '';
    if (_envOk) {
      addLog('FFmpeg 环境正常: $_ffmpegVersion', category: 'info');
      final path = env['data']?['ffmpeg_path'] as String?;
      if (path != null) addLog('  路径: $path', category: 'info');
    } else {
      addLog('FFmpeg 环境异常: ${env['error'] ?? '未知错误'}', category: 'error');
    }
    notifyListeners(); return env;
  }

  // ── MCP Server ──
  HttpServer? _mcpServer;
  bool get mcpRunning => _mcpServer != null;

  PipelineGraph? _currentPipelineGraph;
  void setCurrentPipeline(PipelineGraph g) { _currentPipelineGraph = g; }
  VoidCallback? mcpOnClearAll, mcpOnUndo, mcpOnRedo, mcpOnSave;
  void Function(String nodeId, Map<String, dynamic> params)? mcpOnModifyNode;

  Future<void> startMcpServer() async {
    if (_mcpServer != null) return;
    try {
      final port = config.mcpPort;
      _mcpServer = await HttpServer.bind(InternetAddress.anyIPv4, port);
      addLog('[MCP] 服务已启动，端口: $port', category: 'info');
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
    } catch (e) {
      addLog('[MCP] 启动失败: $e', category: 'error');
      _mcpServer = null;
      notifyListeners();
    }
  }

  Future<void> stopMcpServer() async {
    if (_mcpServer == null) return;
    await _mcpServer!.close();
    _mcpServer = null;
    addLog('[MCP] 服务已停止', category: 'info');
    notifyListeners();
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
              'serverInfo': {'name': 'ffmpegpp', 'version': '4.11.20'},
            },
          }));
        case 'tools/list':
          req.response.write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {'tools': _mcpToolsList()}}));
        case 'tools/call':
          final toolName = params['name'] as String? ?? '';
          final args = params['arguments'] as Map<String, dynamic>? ?? {};
          final (result, isError) = _mcpCallTool(toolName, args);
          req.response.write(jsonEncode({
            'jsonrpc': '2.0', 'id': id,
            'result': {'content': [{'type': 'text', 'text': result}], if (isError) 'isError': true},
          }));
        case 'resources/list':
          req.response.write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {'resources': _mcpResourcesList()}}));
        case 'resources/read':
          final uri = params['uri'] as String? ?? '';
          final result = _mcpReadResource(uri);
          req.response.write(jsonEncode({
            'jsonrpc': '2.0', 'id': id,
            'result': {'contents': [{'uri': uri, 'mimeType': 'application/json', 'text': result}]},
          }));
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
  ];

  List<Map<String, dynamic>> _mcpResourcesList() => [
    {'uri': 'pipeline://current', 'name': 'Current Pipeline', 'mimeType': 'application/json'},
    {'uri': 'videos://loaded', 'name': 'Loaded Videos', 'mimeType': 'application/json'},
  ];

  (String, bool) _mcpCallTool(String name, Map<String, dynamic> args) {
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
          final entries = Directory(path).listSync().take(50).map((e) {
            final s = e.statSync();
            return {'name': e.path.split('/').last, 'type': s.type == FileSystemEntityType.directory ? 'directory' : 'file', 'size': s.size};
          }).toList();
          return (jsonEncode(entries), false);
        } catch (e) { return ('Error: $e', true); }
      case 'read_file_info':
        final path = args['path'] as String? ?? '';
        try {
          final s = File(path).statSync();
          return (jsonEncode({'path': path, 'size': s.size, 'modified': s.modified.toIso8601String(), 'type': path.split('.').last}), false);
        } catch (e) { return ('Error: $e', true); }
      case 'modify_node_params':
        final nodeId = args['nodeId'] as String? ?? '';
        final params = args['params'] as Map<String, dynamic>? ?? {};
        if (mcpOnModifyNode == null) return ('Error: No editor open — open a pipeline editor first', true);
        mcpOnModifyNode!(nodeId, params);
        return ('Node $nodeId params updated', false);
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
      default: return ('Unknown tool: $name', true);
    }
  }

  String _mcpReadResource(String uri) {
    switch (uri) {
      case 'pipeline://current':
        return jsonEncode(_currentPipelineGraph?.toJson() ?? {'nodes': [], 'connections': []});
      case 'videos://loaded':
        return jsonEncode(videos.map((v) => {'id': v.id, 'filename': v.filename, 'format': v.format, 'size_mb': v.sizeMb, 'duration': v.duration, 'codec': v.codec, 'resolution': v.resolution}).toList());
      default: return '{"error": "Unknown resource: $uri"}';
    }
  }

  Future<void> toggleMcpServer(bool enable) async {
    await updateConfig((c) => c..mcpEnabled = enable);
    if (enable) {
      await startMcpServer();
    } else {
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
    await stopMcpServer();
    await pythonProcess.shutdown();
  }

  @override
  void dispose() { backend.dispose(); pythonProcess.dispose(); super.dispose(); }
}
