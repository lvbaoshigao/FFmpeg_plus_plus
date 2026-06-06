import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../main.dart';
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

  AppConfig get config => configService.config;
  bool get darkMode => config.darkMode;
  int _selectedNav = 0;
  int get selectedNav => _selectedNav;

  Future<void> init(String serverScript) async {
    startupLogAdd('6-config loading...');
    await configService.load();
    startupLogAdd('6-config loaded');
    try {
      await pythonProcess.start(serverScript);
      startupLogAdd('7-process started');
    } catch (e) {
      _initError = 'Python backend failed: $e';
      _envChecked = true; _envOk = false; notifyListeners(); return;
    }
    try {
      startupLogAdd('7b-waiting for ready...');
      final ready = await pythonProcess.responses
          .firstWhere((o) => o['type'] == 'ready')
          .timeout(const Duration(seconds: 30), onTimeout: () => {'type': 'timeout'});
      startupLogAdd('7c-ready received: ${ready['type']}');
      if (ready['type'] != 'ready') {
        _initError = 'Backend not ready'; _envChecked = true; _envOk = false; notifyListeners(); return;
      }
    } catch (e) {
      _initError = 'Backend start failed: $e'; _envChecked = true; _envOk = false; notifyListeners(); return;
    }
    _envChecked = false; _envOk = false;
    notifyListeners();
  }

  void selectNav(int i) { _selectedNav = i; notifyListeners(); }

  Future<void> addVideos(List<String> filepaths) async {
    _probingVideos = true; notifyListeners();
    for (final fp in filepaths) {
      final vf = VideoFile.fromFilepath(fp); _videos.add(vf); notifyListeners();
      try {
        final resp = await backend.probe(fp);
        if (resp['success'] == true) {
          final info = resp['data'] as Map<String, dynamic>;
          final idx = _videos.indexWhere((v) => v.id == vf.id);
          if (idx >= 0) { _videos[idx] = VideoFile.fromProbeResult(fp, info, id: vf.id); _probeErrors.remove(fp); notifyListeners(); }
        } else { _probeErrors[fp] = resp['error'] as String? ?? 'Unknown'; notifyListeners(); }
      } catch (e) { _probeErrors[fp] = 'Error: $e'; notifyListeners(); }
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

    if (config.aiEnabled) {
      final cmd = await _generateAICommand(task);
      if (cmd == null) {
        _tasks[pi] = _tasks[pi].copyWith(status: TaskStatus.failed, error: 'AI generation failed. Check API config or disable AI.');
        _processing = false; _currentTaskId = null; notifyListeners(); return;
      }
      _aiGeneratedCommand = cmd;
    }

    StreamSubscription<ProgressUpdate>? sub;
    sub = backend.progressStream.listen((u) {
      if (u.taskId == _currentTaskId) {
        final i = _tasks.indexWhere((t) => t.id == _currentTaskId);
        if (i >= 0) { _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: u.progress, elapsed: u.currentTime, remaining: u.remaining, speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame); notifyListeners(); }
      }
    });

    Map<String, dynamic> resp;
    if (task.config.subtitleEnabled) {
      resp = await backend.subtitle(task.id, input: task.inputPath, output: task.outputPath, subtitleOptions: {'source': task.config.subtitleSource, if (task.config.subtitleFile != null) 'subtitle_file': task.config.subtitleFile, 'subtitle_index': task.config.subtitleIndex}, videoOptions: task.config.toBackendOptions());
    } else {
      resp = await backend.transcode(task.id, input: task.inputPath, output: task.outputPath, options: task.config.toBackendOptions());
    }
    await sub.cancel();

    final fi = _tasks.indexWhere((t) => t.id == _currentTaskId);
    if (fi >= 0) {
      if (resp['success'] == true) {
        final d = resp['data'] as Map<String, dynamic>?;
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.completed, progress: 100, outputSize: d?['output_size'] as int?, duration: (d?['duration'] as num?)?.toDouble(), command: (d?['command'] as List?)?.cast<String>());
      } else {
        _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.failed, error: resp['error'] as String?, logLines: (resp['data']?['log_lines'] as List?)?.cast<String>() ?? [], command: (resp['data']?['command'] as List?)?.cast<String>());
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
    String p = c.aiPrompt
        .replaceAll('{input}', task.inputPath).replaceAll('{output}', task.outputPath)
        .replaceAll('{video_codec}', task.config.videoCodec).replaceAll('{gpu}', task.config.gpu)
        .replaceAll('{resolution}', '${task.config.resolutionW ?? 'none'}x${task.config.resolutionH ?? 'none'}')
        .replaceAll('{bitrate}', '${task.config.videoBitrate}').replaceAll('{framerate}', '${task.config.framerate ?? 'none'}')
        .replaceAll('{audio_codec}', task.config.audioCodec).replaceAll('{audio_bitrate}', '${task.config.audioBitrate}')
        .replaceAll('{audio_channels}', '${task.config.audioChannels ?? 'none'}')
        .replaceAll('{subtitle}', task.config.subtitleEnabled ? (task.config.subtitleFile ?? 'embedded') : 'none')
        .replaceAll('{extra}', '');
    try {
      final resp = await http.post(Uri.parse('${c.aiEndpoint}/v1/chat/completions'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${c.aiKey}'},
          body: jsonEncode({'model': c.aiModel, 'messages': [{'role': 'user', 'content': p}], 'temperature': 0.3}))
          .timeout(const Duration(seconds: 90));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body);
      final text = data['choices']?[0]?['message']?['content'] ?? '';
      return _extractAICommand(text);
    } catch (_) { return null; }
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
