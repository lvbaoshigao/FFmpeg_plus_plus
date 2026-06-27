import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/models.dart';
import '../services/python_process.dart';
import '../services/backend_client.dart';
import '../services/config_service.dart';
import '../services/graph_executor.dart';

class AppState extends ChangeNotifier {
  final PythonProcessManager pythonProcess = PythonProcessManager();
  late final BackendClient backend = BackendClient(pythonProcess);
  final ConfigService configService = ConfigService();

  bool _envChecked = false, _envOk = false;
  String _ffmpegVersion = '', _initError = '';
  bool get envChecked => _envChecked;
  bool get envOk => _envOk;
  String get ffmpegVersion => _ffmpegVersion;
  String get initError => _initError;

  final List<VideoFile> _videos = [];
  List<VideoFile> get videos => List.unmodifiable(_videos);
  bool _probingVideos = false;
  bool get probingVideos => _probingVideos;
  final Map<String, String> _probeErrors = {};
  Map<String, String> get probeErrors => Map.unmodifiable(_probeErrors);

  final List<TaskInfo> _tasks = [];
  List<TaskInfo> get tasks => List.unmodifiable(_tasks);
  bool _processing = false;
  bool get processing => _processing;
  String? _currentTaskId;

  // ── Log entries ──
  final List<LogEntry> _logEntries = [];
  bool _logNotifyPending = false;
  List<LogEntry> get logEntries => List.unmodifiable(_logEntries);
  void addLog(String message, {String category = 'general'}) {
    _logEntries.add(LogEntry(timestamp: DateTime.now(), message: message, category: category));
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

  Future<void> init(String serverScript) async {
    debugPrint('[init] 1-configService.load');
    await configService.load();
    debugPrint('[init] 2-configService.load done');
    try {
      debugPrint('[init] 3-calling pythonProcess.start($serverScript)');
      await pythonProcess.start(serverScript);
      debugPrint('[init] 4-pythonProcess.start done, isRunning=${pythonProcess.isRunning}');
    } catch (e) {
      debugPrint('[init] 4-ERROR: $e');
      _initError = 'Python backend failed: $e';
      _envChecked = true; _envOk = false; notifyListeners(); return;
    }
    try {
      debugPrint('[init] 5-waiting for ready...');
      final ready = await pythonProcess.waitForReady(timeout: const Duration(seconds: 30));
      debugPrint('[init] 6-ready result: ${ready['type']}');
      if (ready['type'] != 'ready') {
        _initError = 'Backend not ready'; _envChecked = true; _envOk = false; notifyListeners(); return;
      }
    } catch (e) {
      debugPrint('[init] 6-ERROR: $e');
      _initError = 'Backend start failed: $e'; _envChecked = true; _envOk = false; notifyListeners(); return;
    }
    _envChecked = false; _envOk = false;
    notifyListeners();
    debugPrint('[init] 7-setup log listeners');
    _setupLogListeners();
    _autoDetectLocalFfmpeg();
  }

  void _autoDetectLocalFfmpeg() {
    final exeDir = Directory(Platform.resolvedExecutable).parent.path;
    final localFfmpeg = File('$exeDir${Platform.pathSeparator}ffmpeg.exe');
    final localFfprobe = File('$exeDir${Platform.pathSeparator}ffprobe.exe');
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
    _probingVideos = true; notifyListeners();
    addLog('添加 ${filepaths.length} 个文件', category: 'info');

    // 先全部加入列表（立即显示占位卡片），再逐个探测
    final entries = <VideoFile>[];
    for (final fp in filepaths) {
      final vf = VideoFile.fromFilepath(fp);
      _videos.add(vf);
      entries.add(vf);
    }
    notifyListeners();

    for (final vf in entries) {
      await _probeOne(vf);
    }

    _probingVideos = false; notifyListeners();
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
  void updateVideoConfig(String id, TranscodeConfig c) { final i = _videos.indexWhere((v) => v.id == id); if (i >= 0) { _videos[i] = _videos[i].copyWith(config: c); notifyListeners(); } }

  void updateVideoPipeline(String id, PipelineGraph graph) {
    final i = _videos.indexWhere((v) => v.id == id);
    if (i >= 0) {
      _videos[i] = _videos[i].copyWith(pipelineGraph: graph);
      notifyListeners();
    }
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
    if (out == video.filepath) { final be = fn.replaceAll(RegExp(r'\.[^.]+$'), ''); final ee = fn.split('.').last; out = '${dir}${be}_processed.$ee'; }
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
      final calls = GraphExecutor.buildBackendCalls(plan, video.filepath, outputPath);
      if (calls.isEmpty) continue;
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
    if (_processing) return;
    final i = _tasks.indexWhere((t) => t.id == tid);
    if (i < 0 || _tasks[i].status != TaskStatus.pending) return;
    final t = _tasks.removeAt(i); _tasks.insert(0, t);
    notifyListeners(); processNextTask();
  }

  void processAllTasks() { if (!_processing) processNextTask(); }

  Future<void> processNextTask() async {
    if (_processing) return;
    final pi = _tasks.indexWhere((t) => t.status == TaskStatus.pending);
    if (pi < 0) return;
    _processing = true; final task = _tasks[pi]; _currentTaskId = task.id;
    _tasks[pi] = task.copyWith(status: TaskStatus.processing); notifyListeners();
    addLog('开始处理: ${task.filename}', category: 'info');
    addLog('输入: ${task.inputPath}', category: 'info');
    addLog('输出: ${task.outputPath}', category: 'info');

    if (task.pipelineCalls != null && task.pipelineCalls!.isNotEmpty) {
      await _processPipelineTask(pi);
    } else {
      await _processLegacyTask(pi, task);
    }

    _processing = false; _currentTaskId = null;
    if (_tasks.any((t) => t.status == TaskStatus.pending)) processNextTask();
  }

  Future<void> _processLegacyTask(int pi, TaskInfo task) async {
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
      if (u.taskId == _currentTaskId) {
        final i = _tasks.indexWhere((t) => t.id == _currentTaskId);
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

    final fi = _tasks.indexWhere((t) => t.id == _currentTaskId);
    if (fi >= 0) {
      if (resp['success'] == true) {
        final d = resp['data'] as Map<String, dynamic>?;
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.completed, progress: 100, outputSize: d?['output_size'] as int?, duration: (d?['duration'] as num?)?.toDouble(), command: (d?['command'] as List?)?.cast<String>());
        addLog('任务完成: ${task.filename} (${d?['duration']}s)', category: 'info');
        final sz = d?['output_size'] as int?;
        if (sz != null) addLog('  输出大小: ${(sz / 1024 / 1024).toStringAsFixed(1)}MB', category: 'info');
        final cmd = (d?['command'] as List?)?.cast<String>();
        if (cmd != null) addLog('  命令: ${cmd.join(' ')}', category: 'ffmpeg');
      } else {
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.failed, error: resp['error'] as String?, logLines: (resp['data']?['log_lines'] as List?)?.cast<String>() ?? [], command: (resp['data']?['command'] as List?)?.cast<String>());
        addLog('任务失败: ${task.filename} - ${resp['error']}', category: 'error');
      }
      notifyListeners();
    }
  }

  Future<void> _processPipelineTask(int pi) async {
    final task = _tasks[pi];
    final calls = task.pipelineCalls!;
    final realCalls = calls.where((c) => c.action != '_cleanup').toList();
    final cleanupCalls = calls.where((c) => c.action == '_cleanup').toList();

    addLog('节点图任务: ${realCalls.length} 步', category: 'info');

    for (var ci = 0; ci < realCalls.length; ci++) {
      final call = realCalls[ci];
      final stepProgress = ci / realCalls.length;

      final fi = _tasks.indexWhere((t) => t.id == _currentTaskId);
      if (fi >= 0) {
        _tasks[fi] = _tasks[fi].copyWith(currentCallIndex: ci, progress: stepProgress * 100);
        notifyListeners();
      }

      addLog('步骤 ${ci + 1}/${realCalls.length}: ${call.action}', category: 'info');

      StreamSubscription<ProgressUpdate>? sub;
      sub = backend.progressStream.listen((u) {
        if (u.taskId == _currentTaskId) {
          final i = _tasks.indexWhere((t) => t.id == _currentTaskId);
          if (i >= 0) {
            final overallProgress = (stepProgress + u.progress / 100 / realCalls.length) * 100;
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
        default:
          resp = {'success': false, 'error': '未知动作: ${call.action}'};
      }
      await sub.cancel();

      if (resp['success'] != true) {
        final fi2 = _tasks.indexWhere((t) => t.id == _currentTaskId);
        if (fi2 >= 0) {
          _tasks[fi2] = _tasks[fi2].copyWith(
            status: TaskStatus.failed,
            error: '步骤 ${ci + 1} 失败: ${resp['error']}',
            logLines: (resp['data']?['log_lines'] as List?)?.cast<String>() ?? [],
            command: (resp['data']?['command'] as List?)?.cast<String>(),
          );
          addLog('步骤 ${ci + 1} 失败: ${resp['error']}', category: 'error');
          notifyListeners();
        }
        _cleanupTempFiles(cleanupCalls);
        return;
      }
      addLog('步骤 ${ci + 1} 完成', category: 'info');
    }

    final fi3 = _tasks.indexWhere((t) => t.id == _currentTaskId);
    if (fi3 >= 0) {
      final outFile = File(task.outputPath);
      final outSize = outFile.existsSync() ? outFile.lengthSync() : null;
      _tasks[fi3] = _tasks[fi3].copyWith(status: TaskStatus.completed, progress: 100, outputSize: outSize);
      addLog('任务完成: ${task.filename}', category: 'info');
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

      final args = <String>['ffmpeg', '-y'];
      if (startTime != null) args.addAll(['-ss', '$startTime']);
      args.addAll(['-i', input]);
      if (endTime != null) args.addAll(['-to', '${endTime - (startTime ?? 0)}']);
      args.addAll(['-vf', 'fps=$fps', '$outDir/frame_%06d.$fmt']);

      addLog('帧提取: ${args.join(' ')}', category: 'info');
      final result = await Process.run(args[0], args.sublist(1));
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
    _processing = false; _currentTaskId = null; notifyListeners();
  }

  void clearCompletedTasks() { _tasks.removeWhere((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed || t.status == TaskStatus.cancelled); notifyListeners(); }
  void removeTask(String id) { _tasks.removeWhere((t) => t.id == id); notifyListeners(); }
  void clearAllTasks() { if (!_processing) { _tasks.clear(); notifyListeners(); } }
  void toggleTaskExpanded(String tid) { final i = _tasks.indexWhere((t) => t.id == tid); if (i >= 0) { _tasks[i] = _tasks[i].copyWith(expanded: !_tasks[i].expanded); notifyListeners(); } }

  Future<void> toggleDarkMode(bool v) async { await configService.update((c) => c..darkMode = v); notifyListeners(); }
  Future<void> updateConfig(AppConfig Function(AppConfig) f) async { await configService.update(f); notifyListeners(); }

  Future<Map<String, dynamic>> recheckEnv() async {
    addLog('检测 FFmpeg 环境...', category: 'info');
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

  Future<void> shutdown() async { await pythonProcess.shutdown(); }

  @override
  void dispose() { backend.dispose(); pythonProcess.dispose(); super.dispose(); }
}
