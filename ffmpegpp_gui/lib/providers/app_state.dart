import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import '../services/python_process.dart';
import '../services/backend_client.dart';
import '../services/config_service.dart';

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

  String? _aiGeneratedCommand;
  String? get aiGeneratedCommand => _aiGeneratedCommand;
  void setAICommand(String cmd) { _aiGeneratedCommand = cmd; notifyListeners(); }

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
  }

  void selectNav(int i) { _selectedNav = i; notifyListeners(); }

  Future<void> addVideos(List<String> filepaths) async {
    _probingVideos = true; notifyListeners();
    addLog('添加 ${filepaths.length} 个文件', category: 'info');
    for (final fp in filepaths) {
      final vf = VideoFile.fromFilepath(fp); _videos.add(vf); notifyListeners();
      addLog('探测: ${vf.filename}', category: 'info');
      try {
        final resp = await backend.probe(fp);
        if (resp['success'] == true) {
          final info = resp['data'] as Map<String, dynamic>;
          final idx = _videos.indexWhere((v) => v.id == vf.id);
          if (idx >= 0) { _videos[idx] = VideoFile.fromProbeResult(fp, info, id: vf.id); _probeErrors.remove(fp); notifyListeners(); }
          addLog('探测成功: ${vf.filename} (${info['resolution']})', category: 'ffmpeg');
        } else { _probeErrors[fp] = resp['error'] as String? ?? 'Unknown'; notifyListeners(); addLog('探测失败: ${resp['error']}', category: 'error'); }
      } catch (e) { _probeErrors[fp] = 'Error: $e'; notifyListeners(); addLog('探测异常: $e', category: 'error'); }
    }
    _probingVideos = false; notifyListeners();
  }

  void removeVideo(String id) { _videos.removeWhere((v) => v.id == id); notifyListeners(); }
  void updateVideoConfig(String id, TranscodeConfig c) { final i = _videos.indexWhere((v) => v.id == id); if (i >= 0) { _videos[i] = _videos[i].copyWith(config: c); notifyListeners(); } }

  void addTask(String videoId) {
    final idx = _videos.indexWhere((v) => v.id == videoId);
    if (idx < 0) return;
    final video = _videos[idx]; final cfg = video.config;
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
    addLog('编码器: ${task.config.videoCodec}, GPU: ${task.config.gpu}', category: 'info');

    if (config.aiEnabled) {
      addLog('AI 已启用，开始生成命令...', category: 'info');
      final cmd = await _generateAICommand(task);
      if (cmd == null) {
        addLog('AI 命令生成失败，跳过任务', category: 'error');
        _tasks[pi] = _tasks[pi].copyWith(status: TaskStatus.failed, error: 'AI generation failed. Check API config or disable AI.');
        _processing = false; _currentTaskId = null; notifyListeners(); return;
      }
      _aiGeneratedCommand = cmd;
      addLog('AI 命令生成成功: $cmd', category: 'info');
    } else {
      addLog('AI 未启用，使用默认编码参数', category: 'info');
    }

    StreamSubscription<ProgressUpdate>? sub;
    sub = backend.progressStream.listen((u) {
      debugPrint('[Progress] taskId=${u.taskId} current=$_currentTaskId progress=${u.progress}');
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
      } else {
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.failed, error: resp['error'] as String?, logLines: (resp['data']?['log_lines'] as List?)?.cast<String>() ?? [], command: (resp['data']?['command'] as List?)?.cast<String>());
        addLog('任务失败: ${task.filename} - ${resp['error']}', category: 'error');
      }
      notifyListeners();
    }
    _processing = false; _currentTaskId = null;
    if (_tasks.any((t) => t.status == TaskStatus.pending)) processNextTask();
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
    final env = await backend.checkEnv();
    _envChecked = true; _envOk = env['success'] == true && (env['data']?['all_ok'] as bool? ?? false);
    _ffmpegVersion = env['data']?['ffmpeg_version'] as String? ?? '';
    notifyListeners(); return env;
  }

  Future<String?> _generateAICommand(TaskInfo task) async {
    final c = config;
    if (c.aiEndpoint.isEmpty || c.aiKey.isEmpty) return null;
    addLog('AI 请求: ${c.aiModel} → ${c.aiEndpoint}', category: 'info');
    String p = c.aiPrompt
        .replaceAll('{input}', task.inputPath).replaceAll('{output}', task.outputPath)
        .replaceAll('{video_codec}', task.config.videoCodec).replaceAll('{gpu}', task.config.gpu)
        .replaceAll('{resolution}', '${task.config.resolutionW ?? 'none'}x${task.config.resolutionH ?? 'none'}')
        .replaceAll('{bitrate}', '${task.config.videoBitrate}').replaceAll('{framerate}', '${task.config.framerate ?? 'none'}')
        .replaceAll('{audio_codec}', task.config.audioCodec).replaceAll('{audio_bitrate}', '${task.config.audioBitrate}')
        .replaceAll('{audio_channels}', '${task.config.audioChannels ?? 'none'}')
        .replaceAll('{subtitle}', task.config.subtitleEnabled ? (task.config.subtitleFile ?? 'embedded') : 'none')
        .replaceAll('{extra}', '');
    addLog('AI Prompt 已构建 (${p.length} chars)', category: 'info');
    try {
      final resp = await http.post(Uri.parse('${c.aiEndpoint}/v1/chat/completions'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${c.aiKey}'},
          body: jsonEncode({'model': c.aiModel, 'messages': [{'role': 'user', 'content': p}], 'temperature': 0.3}))
          .timeout(const Duration(seconds: 90));
      addLog('AI 响应: HTTP ${resp.statusCode}', category: 'info');
      if (resp.statusCode != 200) {
        addLog('AI 请求失败: ${resp.body}', category: 'error');
        return null;
      }
      final data = jsonDecode(resp.body);
      final text = data['choices']?[0]?['message']?['content'] ?? '';
      final cmd = _extractAICommand(text);
      if (cmd != null) {
        addLog('AI 生成命令: $cmd', category: 'info');
      } else {
        addLog('AI 未能从响应中提取 ffmpeg 命令', category: 'error');
      }
      return cmd;
    } catch (e) { addLog('AI 请求异常: $e', category: 'error'); return null; }
  }

  String? _extractAICommand(String text) {
    for (final line in text.split('\n')) { final t = line.trim(); if (t.startsWith('ffmpeg ')) return t; }
    final m = RegExp(r'```(?:bash|sh|shell)?\s*\n?(ffmpeg[^\n]*)', multiLine: true).firstMatch(text);
    if (m != null) return m.group(1)!.trim();
    for (final line in text.split('\n')) { if (line.contains('ffmpeg ')) { final s = line.indexOf('ffmpeg '); return line.substring(s).trim(); } }
    return null;
  }

  Future<void> shutdown() async { await pythonProcess.shutdown(); }

  @override
  void dispose() { backend.dispose(); pythonProcess.dispose(); super.dispose(); }
}
