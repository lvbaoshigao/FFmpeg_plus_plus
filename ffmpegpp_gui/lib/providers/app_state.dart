import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../platform/app_platform.dart';
import '../services/android_platform.dart';
import '../services/backend_client.dart';
import '../services/config_service.dart';
import '../services/ffmpeg_installer.dart';
import '../services/graph_executor.dart';
import '../services/native_process.dart';

class AppState extends ChangeNotifier {
  /// 共享随机数生成器：避免随机参数生成时每处 new Random()，
  /// 否则同一毫秒内多次实例化会因时间种子相同而退化为固定偏移的伪随机序列。
  static final Random _rng = Random();
  final NativeProcessManager pythonProcess = NativeProcessManager();
  late final BackendClient backend = _createBackend();
  final ConfigService configService = ConfigService();

  /// [FIX audit] 后端的滤镜安全审计告警此前无人消费、被静默丢弃：
  /// handleTranscode / handleSubtitle 在启动 ffmpeg 之前会先发
  /// `{"type":"audit","warnings":[...]}`（见 json_io.cpp 的 JsonWriter::audit），
  /// 但 `BackendClient.auditStream` 在本项目里零监听者，用户永远看不到
  /// 「输出文件与输入相同，会覆盖源文件」这类告警。这里把它接进日志。
  StreamSubscription<List<String>>? _auditSub;
  BackendClient _createBackend() {
    final client = BackendClient(pythonProcess);
    _auditSub = client.auditStream.listen((warnings) {
      for (final w in warnings) {
        // audit.cpp 用 ERROR:/WARNING: 前缀区分严重程度
        addLog(w, category: w.startsWith('ERROR') ? 'error' : 'warn');
      }
    });
    return client;
  }

  void Function(String filename, TaskStatus status)? onTaskFinished;

  bool _envOk = false;
  String _ffmpegVersion = '';
  bool get envOk => _envOk;
  String get ffmpegVersion => _ffmpegVersion;

  final List<VideoFile> _videos = [];
  List<VideoFile> get videos => UnmodifiableListView(_videos);

  // ── id → VideoFile 索引（惰性、按通知周期失效）──
  // 容器卡片与容器详情页原先都靠 `videos.where((v) => v.id == item.fileId)`
  // 反查：容器卡是 O(items × videos)、详情页 itemBuilder 内更退化成 O(items²)，
  // 都会随进度心跳（~3.3Hz）反复执行。这里改为 O(1) 查表。
  //
  // 失效策略选「notifyListeners 时置空、下次查询时重建」而不是在每个
  // `_videos` 变更点手工同步：`_videos` 有 10 处变更点（add/removeWhere/
  // clear/下标替换 × 4 个方法），漏掉任何一处都会得到静默错误的查询结果；
  // 而所有变更路径后面都必然跟一次 notifyListeners，所以挂在这里是唯一
  // 不会遗漏的位置。重建是惰性的：一次通知周期内无论多少张卡查询，最多
  // 只重建一次（O(n)），远小于原先每卡一次的 O(n) 扫描。
  Map<String, VideoFile>? _videoIndexCache;

  /// 按 id 查视频（容器卡片 / 容器详情页用），找不到返回 null。
  ///
  /// 刻意不对外暴露整张 Map：Map 实例会在每次通知后重建，若被塞进
  /// `context.select` 会因引用变化而次次判定为「已变更」，反而放大重建。
  VideoFile? videoById(String id) {
    final cache = _videoIndexCache ??
        (_videoIndexCache = {for (final v in _videos) v.id: v});
    return cache[id];
  }

  int _probeCount = 0;
  bool get probingVideos => _probeCount > 0;
  // 媒体库指纹：项目页用 Selector 订阅它，替代「订阅整个 AppState」。
  // 只聚合媒体库相关的可变状态（视频/容器数量、探测状态、语言），
  // 因此进度心跳、日志、任务等无关 notifyListeners 不会触发项目页重建。
  // 用 Object.hash 组合，比较成本 O(1)；数量变化即代表列表结构变化，
  // 足以覆盖增删/导入/清空等场景（元素内容变化由数量或探测状态间接反映）。
  int get librarySignature => Object.hash(
        _videos.length,
        _containers.length,
        _probeCount,
        _probeErrors.length,
        config.language,
      );
  final Map<String, String> _probeErrors = {};
  // 零拷贝视图（与 videos / logEntries 同一原则，见下方 logEntries 的注释）。
  // 这里**必须**是视图而不是 Map.unmodifiable：本 getter 被 video_card 放进
  // context.select，而 provider 的 selector 在每次 notifyListeners() 都会重跑
  // ⇒ 每通知 × 每张视频卡 × 整份 Map 拷贝。实测 Map.unmodifiable 比
  // UnmodifiableMapView 慢 438×（n=100）/ 1860×（n=1000）/ 32101×（n=5000），
  // 单次 n=1000 约 0.30ms，200 张卡即 60ms/次通知（60fps 预算只有 16.7ms）。
  Map<String, String> get probeErrors => UnmodifiableMapView(_probeErrors);

  final List<TaskInfo> _tasks = [];
  // 同上：队列页在单次 build 里会读取 tasks 多次（空态判断、长度、逐项取卡片、
  // 按钮可用性），List.unmodifiable 会让每次都构造一份新列表（上限 200 项）。
  List<TaskInfo> get tasks => UnmodifiableListView(_tasks);
  // ── 处理队列结果持久化 ──
  // 结构性变化（增删/进入处理/终态）后防抖落盘；进度心跳不落盘。
  Timer? _taskPersistTimer;
  static const int _maxPersistedTasks = 200;
  final Set<String> _runningTaskIds = {};
  bool get processing => _runningTaskIds.isNotEmpty;
  String? _currentTaskId;
  // 取消标记：cancelProcessing 置位后，正在途中的任务完成/失败回调不得覆盖
  // cancelled 状态，processNextTask 也不得继续拉取 pending 任务。
  bool _cancelRequested = false;
  // [FIX H-3/H-8] 调度批次计数：startAll/processSingleTask 自增，收尾续体比对
  // 本批次编号决定是否继续拉取；「停止所有」(cancelProcessing) 与「单任务取消」
  // (cancelTask) 用此区分，避免二者状态语义互相污染。
  int _runGeneration = 0;
  // 单个任务取消：cancelTask 只取消指定任务（不触碰全局 _cancelRequested），
  // 多任务并发时其余任务继续执行。
  final Set<String> _cancelledTaskIds = {};
  // 每个任务正在运行的本地 ffmpeg 进程（供 cancelTask 只终止该任务名下的进程）
  final Map<String, List<Process>> _localProcessesByTask = {};

  // ── 任务列表版本号 ──
  // _tasks 是原地更新（元素级 copyWith 替换），List 引用永远不变，
  // Provider 的 Selector 无法据此感知变化。队列页/任务卡片订阅这个单调
  // 递增的版本号触发刷新（配合下方进度节流，通知频率已被压到 ~3Hz）。
  int _tasksVersion = 0;
  int get tasksVersion => _tasksVersion;

  /// 任务列表内容变化后调用：版本号 +1 并通知 UI。
  void _tasksNotify() {
    _tasksVersion++;
    notifyListeners();
  }

  // ── 释放守卫（S-6）──
  // dispose() 只能 cancel 尚未触发的 Timer，无法撤销已进入微任务/定时器队列
  // 的回调；而 addLog 由 AI 流式响应 / stderr 监听驱动，页面销毁后仍会被调用。
  // 所有延迟路径（Timer 回调、scheduleMicrotask、Future.then 续体）改用
  // _safeNotify，释放后直接短路，避免「dispose 后 notify」的静默丢通知/断言崩溃。
  bool _disposed = false;
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 每次通知都让视频索引失效，下次 [videoById] 查询时惰性重建。
  /// 挂在 notifyListeners 上而不是各变更点，理由见 `_videoIndexCache` 的注释。
  /// 代价为零：置空只是一个字段写入，真正的重建发生在真有查询时（每周期最多一次）。
  @override
  void notifyListeners() {
    _videoIndexCache = null;
    super.notifyListeners();
  }

  // ── 进度心跳节流 ──
  // ffmpeg 的进度输出每秒数次，多任务并发时更高频。此前每条进度消息都直接
  // 改 _tasks 并 notifyListeners() → 整棵订阅树（队列页、侧边栏、MaterialApp
  // 的 Selector 等）每 100~250ms 全量评估/重建，长转码下 CPU 与 GC 压力显著。
  // 现在按任务合并最新一条，每 300ms 批量落一次：
  //  - 进度条视觉上无差别（人眼分辨不出 300ms 间隔）；
  //  - 通知频率上限 ~3.3Hz，且只在确有变化时通知。
  final Map<String, bool Function()> _pendingProgress = {};
  Timer? _progressFlushTimer;
  static const Duration _progressFlushInterval = Duration(milliseconds: 300);

  /// 登记一个任务的进度应用闭包（闭包内须自行检查任务仍存在且仍在 processing）。
  void _queueProgress(String taskId, bool Function() apply) {
    _pendingProgress[taskId] = apply;
    _progressFlushTimer?.cancel();
    _progressFlushTimer =
        Timer(_progressFlushInterval, _flushProgress);
  }

  void _flushProgress() {
    _progressFlushTimer = null;
    final pending = Map<String, bool Function()>.from(_pendingProgress);
    _pendingProgress.clear();
    if (pending.isEmpty) return;
    var changed = false;
    for (final entry in pending.entries) {
      try {
        changed = entry.value() || changed;
      } catch (_) {}
    }
    if (changed) {
      _tasksVersion++;
      _safeNotify(); // [FIX S-6] dispose 后短路
    }
  }

  // ── Log entries ──
  final List<LogEntry> _logEntries = [];
  // 日志内存上限：长任务期间 stderr 逐行入队会无界增长，超出后丢弃最旧
  static const int _maxLogEntries = 2000;
  // L-11：单日志文件磁盘上限，超出轮转到 .1 备份，避免写盘无界增长
  static const int _maxLogDiskBytes = 10 * 1024 * 1024;
  bool _logNotifyPending = false;
  // 日志版本号：每次日志内容变化时自增。日志页用 Selector 订阅该计数
  // 而非整个 AppState，避免无关的进度心跳/任务更新触发日志页重建。
  int _logVersion = 0;
  int get logVersion => _logVersion;
  // 进度类日志的合批通知定时器（见 addLog 注释）
  Timer? _progressLogNotifyTimer;
  // 日志目录探测缓存（避免每条日志同步 existsSync/createSync）
  String? _logDirReadyFor;
  // L-11：stderr 进度行节流时间戳（避免高频 time= 行让日志/通知无界增长）
  DateTime? _lastStderrProgressAt;
  // UnmodifiableListView 是零拷贝视图（List.unmodifiable 每次都会构造新列表），
  // 避免每次 build 读取都分配一个包装列表；调用方只读，不缓存引用。
  List<LogEntry> get logEntries => UnmodifiableListView(_logEntries);
  void addLog(String message, {String category = 'general'}) {
    // M-12：统一 category 大小写并归并 warn/warning 两种拼写（项目内混用），
    // 否则关键失败日志（'warn'）因不在白名单被静默丢弃。
    final String cat;
    final raw = category.toLowerCase();
    cat = raw == 'warning' ? 'warn' : raw;
    // 调试模式关闭时，仅保留 error / progress / warn 类关键日志（不记录一般日志）
    if (!config.debugMode && cat != 'error' && cat != 'progress' && cat != 'warn') return;

    _logEntries.add(LogEntry(timestamp: DateTime.now(), message: message, category: cat));
    _logVersion++;
    if (_logEntries.length > _maxLogEntries) {
      _logEntries.removeRange(0, _logEntries.length - _maxLogEntries);
    }
    // L-11：progress 类日志不写盘（高频、纯进度，无价值且会让日志文件无界膨胀）
    if (config.saveLogs && config.logSavePath.isNotEmpty && cat != 'progress') {
      _writeLogToFile(message, cat);
    }
    // Progress logs need near-real-time UI updates, but ffmpeg 进度行每秒
    // 数次（本地任务 stderr 每行都进这里）。逐条 notify 会让整棵订阅树
    // （项目页/设置页的 Consumer）以 4~10Hz 全量重建。改为 400ms 合批：
    // 日志页观感上仍是实时的，重建频率降到 2.5Hz 封顶。
    if (cat == 'progress') {
      _progressLogNotifyTimer?.cancel();
      _progressLogNotifyTimer =
          Timer(const Duration(milliseconds: 400), () {
        _progressLogNotifyTimer = null;
        _safeNotify(); // [FIX S-6] dispose 后短路
      });
      return;
    }
    // Other logs batch via microtask to prevent UI blocking
    if (!_logNotifyPending) {
      _logNotifyPending = true;
      scheduleMicrotask(() {
        _logNotifyPending = false;
        _safeNotify(); // [FIX S-6] dispose 后短路
      });
    }
  }
  void clearLogs() { _logEntries.clear(); _logVersion++; notifyListeners(); }

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
          // L-11：磁盘日志上限，超出则轮转到 .1 备份，避免写盘无界增长
          if (await file.exists()) {
            final size = await file.length();
            if (size > _maxLogDiskBytes) {
              final rotated = File('${file.path}.1');
              try {
                if (await rotated.exists()) await rotated.delete();
                await file.rename(rotated.path);
              } catch (_) {}
            }
          }
          await file.writeAsString(line, mode: FileMode.append);
        } catch (_) {}
      });
    } catch (_) {
      // 目录创建失败等：重置缓存，下次重试
      _logDirReadyFor = null;
    }
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
    // 恢复上次退出时的处理队列结果（含孤儿导入缓存清理）；
    // 不依赖后端，后端启动失败也要能看到历史记录。
    await _loadPersistedTasks();
    notifyListeners(); // 让 UI 用上 config 里的主题 + 恢复的任务队列
    try {
      debugPrint('[init] 3-calling pythonProcess.start($serverScript)');
      await pythonProcess.start(serverScript);
      debugPrint('[init] 4-pythonProcess.start done, isRunning=${pythonProcess.isRunning}');
    } catch (e) {
      debugPrint('[init] 4-ERROR: $e');
      _envOk = false; _initialized = true; notifyListeners(); return;
    }
    try {
      debugPrint('[init] 5-waiting for ready...');
      final ready = await pythonProcess.waitForReady(timeout: const Duration(seconds: 30));
      debugPrint('[init] 6-ready result: ${ready['type']}');
      if (ready['type'] != 'ready') {
        _envOk = false; _initialized = true; notifyListeners(); return;
      }
    } catch (e) {
      debugPrint('[init] 6-ERROR: $e');
      _envOk = false; _initialized = true; notifyListeners(); return;
    }
    // L-10：此处 env 尚未确知，recheckEnv() 会在结果确定后置真值并通知；
    // 不再抢先置 false 并 notify，避免启动瞬间 UI 闪一下「环境异常」。
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
  ///
  /// 关键修复：
  /// 1) 之前自检失败（exit=-11 SIGSEGV 等）也硬写路径进 config + setPaths，导致后续
  ///    每个文件探测都报「ffprobe 执行失败 (-1): 无法读取文件」（Subprocess 把
  ///    SIGSEGV 错误地映射为 -1，见 server_cpp/src/subprocess.cpp）。
  /// 2) 后来改成「自检失败就跳过 setPaths」——这又导致 C++ 端 fallback 走默认
  ///    `findExecutable("ffprobe")` 找不到 libffprobe.so（apk_data_file 目录下），
  ///    每个文件探测变成「exit=127 命令未找到」，情况更糟。
  /// 3) 现在的方案：
  ///    a) 优先尝试 nativeLibraryDir 原路径；若 -version 通过就直接用。
  ///    b) 若失败（早前是 -static-pie 产物无 PT_INTERP 导致 exec 直接 SIGSEGV，
  ///       现已在 build_ffmpeg.sh 改为动态 PIE），把 libffmpeg.so / libffprobe.so
  ///       复制到应用私有二进制目录（filesDir/ffmpegpp_bin/）作为兜底，再次
  ///       自检；若通过则用复制路径。
  ///    c) 最终把**确认可执行的那条路径**注入 C++ 后端 + 写进 config，
  ///       让后续探测走有效路径而不是默认名查找。
  Future<void> _setupAndroidBundledTools() async {
    final ffmpegNative = await AndroidPlatformBridge.bundledFfmpegPath();
    final ffprobeNative = await AndroidPlatformBridge.bundledFfprobePath();
    debugPrint('[ffprobe] bundled ffmpeg=$ffmpegNative ffprobe=$ffprobeNative');
    if (ffmpegNative == null || ffprobeNative == null) {
      addLog('未找到内置 ffmpeg/ffprobe', category: 'error');
      debugPrint('[ffprobe] 未找到内置 ffmpeg/ffprobe（jniLibs 解压失败或原生通道不可用）');
      return;
    }

    // 选路径：先试 nativeLibraryDir 原路径，自检失败再退化到 filesDir 复制版。
    final String ffmpegPath;
    final String ffprobePath;
    final bool viaCopy;
    {
      // 候选 1：nativeLibraryDir 原路径。
      final directOk = await _runSelfCheck(ffmpegNative, ffprobeNative);
      if (directOk) {
        ffmpegPath = ffmpegNative;
        ffprobePath = ffprobeNative;
        viaCopy = false;
        addLog('内置 FFmpeg/FFprobe 直接执行 nativeLibraryDir 路径通过', category: 'info');
      } else {
        // 候选 2：复制到应用私有目录，作为个别 ROM 意外拦截时的兜底。
        addLog('原生路径自检失败，尝试复制到应用私有二进制目录...', category: 'info');
        final ffCopy = await AndroidPlatformBridge.ensureExecutableInAppDir(
          ffmpegNative,
          targetName: 'libffmpeg.so',
        );
        final fpCopy = await AndroidPlatformBridge.ensureExecutableInAppDir(
          ffprobeNative,
          targetName: 'libffprobe.so',
        );
        if (ffCopy != null && fpCopy != null && await _runSelfCheck(ffCopy, fpCopy)) {
          ffmpegPath = ffCopy;
          ffprobePath = fpCopy;
          viaCopy = true;
          addLog('已复制内置工具到应用私有目录并通过自检', category: 'info');
        } else {
          // 两条路径都跑不起来：仍把原路径注入，让后续探测给出明确的错误信息
          // （比 findExecutable("ffprobe") 返回默认名更可诊断）。
          ffmpegPath = ffmpegNative;
          ffprobePath = ffprobeNative;
          viaCopy = false;
          addLog('内置 FFprobe 自检在两条候选路径上都失败，'
              '原路径与 filesDir 副本都会被注入后端用于诊断。',
              category: 'error');
          // 无 PT_INTERP 段的 static-pie 二进制在 Android 14+/SDK 34+ 上 fork+exec
          // 会直接 SIGSEGV（exit=-11）。已在 build_ffmpeg.sh 去掉 -static-pie、改为
          // 动态 PIE（带 PT_INTERP → /system/bin/linker64）；此处报错说明用的仍是旧
          // 缓存产物，需要清理 FFMPEGPP_CACHE 里的 dist/ 后重新交叉编译。
          addLog('libffprobe.so 缺少 PT_INTERP 段导致 exec 直接 SIGSEGV。'
              '请清理 FFMPEGPP_CACHE 旧缓存并重跑 build/android/build_ffmpeg.sh，'
              '新版已改为动态 PIE（带 PT_INTERP）。',
              category: 'error');
        }
      }
    }

    // 写入 config + 注入后端：这里**总是**执行，确保 C++ 后端至少知道完整路径，
    // 避免它走 findExecutable("ffprobe") 拿到裸名后 execvp 返回 127。
    await configService.update((c) => c
      ..ffmpegPath = ffmpegPath
      ..ffprobePath = ffprobePath);

    await backend.setPaths(
      ffmpeg: ffmpegPath,
      ffprobe: ffprobePath,
      tempDir: isAndroidPlatform ? Directory.systemTemp.path : null,
    );
    // 供 UI 层本地调用（缩略图/帧预览）解析内置 ffmpeg
    FfmpegInstaller.configuredFfmpeg = ffmpegPath;
    addLog('已加载内置 FFmpeg: $ffmpegPath${viaCopy ? " (app_data_file 副本)" : ""}',
        category: 'info');
    addLog('已加载内置 FFprobe: $ffprobePath${viaCopy ? " (app_data_file 副本)" : ""}',
        category: 'info');
  }

  /// 直接 fork+exec 跑一遍 ffmpeg/ffprobe 的 -version，确认两条路径都可执行。
  /// 任一失败都返回 false；具体错误已在 caller 的 addLog 中打印。
  Future<bool> _runSelfCheck(String ffmpegPath, String ffprobePath) async {
    try {
      final v = await Process.run(ffprobePath, ['-version']);
      final firstLine = (v.stdout is String && (v.stdout as String).isNotEmpty)
          ? (v.stdout as String).split('\n').first
          : '<empty>';
      debugPrint('[ffprobe] -version exit=${v.exitCode} out=$firstLine path=$ffprobePath');
      if (v.exitCode == 0) {
        addLog('内置 FFprobe 自检通过: $firstLine', category: 'info');
        return true;
      }
      final sig = v.exitCode < 0
          ? ' (信号 -${-v.exitCode}，常见 -11=SIGSEGV 即二进制与系统不兼容)'
          : '';
      addLog('内置 FFprobe 自检失败 exit=${v.exitCode}$sig @ $ffprobePath',
          category: 'error');
      return false;
    } catch (e) {
      debugPrint('[ffprobe] -version error: $e path=$ffprobePath');
      addLog('内置 FFprobe 自检异常 @ $ffprobePath: $e', category: 'error');
      return false;
    }
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
        // L-11：stderr 进度行高频（每秒数次），做每 200ms 节流，避免日志/通知无界增长
        final now = DateTime.now();
        if (_lastStderrProgressAt == null ||
            now.difference(_lastStderrProgressAt!) >= const Duration(milliseconds: 200)) {
          _lastStderrProgressAt = now;
          addLog('转码 ${timeMatch.group(1)} ${speedMatch.group(1)}x', category: 'progress');
        }
        return;
      }
      addLog(line, category: 'ffmpeg');
    });
    // Initial log
    addLog('日志面板已就绪', category: 'info');
    addLog('后端模式: ${pythonProcess.isRunning ? "已连接" : "未连接"}', category: 'info');
  }

  void selectNav(int i) { _selectedNav = i; notifyListeners(); }


  // ══════════════════════════════════════════════════════════════
  // 处理队列结果持久化（PC/Mac/移动 全平台）
  // ══════════════════════════════════════════════════════════════

  /// 任务列表发生结构性变化后调用：防抖合并连续变化，500ms 后落盘。
  void _scheduleTaskPersist() {
    _taskPersistTimer?.cancel();
    _taskPersistTimer = Timer(const Duration(milliseconds: 500), _persistTasksNow);
  }

  /// 立即把当前任务队列写入磁盘（退出前 / 防抖触发）。
  Future<void> _persistTasksNow() async {
    _taskPersistTimer?.cancel();
    _taskPersistTimer = null;
    try {
      // 超出上限时优先丢弃最早的终态任务，保留 pending 与最新结果
      List<TaskInfo> list = _tasks;
      if (_tasks.length > _maxPersistedTasks) {
        final terminal = _tasks.where((t) =>
            t.status == TaskStatus.completed ||
            t.status == TaskStatus.failed ||
            t.status == TaskStatus.cancelled).toList();
        final active = _tasks.where((t) =>
            t.status == TaskStatus.pending ||
            t.status == TaskStatus.processing).toList();
        final terminalBudget = (_maxPersistedTasks - active.length)
            .clamp(0, terminal.length);
        final keptTerminal = terminal.sublist(terminal.length - terminalBudget);
        final keepIds = {
          ...active.map((t) => t.id),
          ...keptTerminal.map((t) => t.id),
        };
        list = _tasks.where((t) => keepIds.contains(t.id)).toList();
      }
      await configService.saveTaskHistory(list.map((t) => t.toJson()).toList());
    } catch (_) {}
  }

  /// 启动时恢复上次退出时的队列（含完成/失败结果）。
  /// - 上次退出时仍在处理中的任务：进程已不存在，标记为「已取消」并注明原因；
  /// - pending 任务保持可重新开始（桌面端输入路径仍在；Android 端流式导入的
  ///   缓存副本会被孤儿清理保留——仍被本任务引用）；
  /// - 恢复后顺带清理不再被任何视频/任务引用的导入缓存（见
  ///   [_cleanupOrphanImportCaches]）。
  Future<void> _loadPersistedTasks() async {
    try {
      final list = await configService.loadTaskHistory();
      final zh = config.language == 'zh';
      var restored = 0;
      for (final e in list) {
        try {
          var t = TaskInfo.fromJson(e);
          if (t.id.isEmpty) continue;
          if (_tasks.any((x) => x.id == t.id)) continue;
          if (t.status == TaskStatus.processing) {
            // [FIX S-3 落地] 上次退出时被中断的任务：除了改状态，还要清掉「上一次
            // 运行」残留的实时心跳（进度百分比 / 已用剩余时间 / 速度 / fps / 码率 /
            // 帧号 / 分步进度）。此前只改 status，卡片会显示「已取消」却挂着冻结在
            // 中断那一刻的进度条与速度数值（例如 87% + 12.5x），看起来像还在跑。
            t = t.copyWith(
              status: TaskStatus.cancelled,
              progress: 0,
              frame: 0,
              elapsed: '',
              remaining: '',
              speed: '',
              fps: '',
              bitrate: '',
              callProgresses: const [],
              currentCallIndex: 0,
              error: t.error ?? (zh ? '应用退出，处理中断' : 'Interrupted: app exited'),
            );
          }
          _tasks.add(t);
          restored++;
        } catch (_) {}
      }
      if (restored > 0) {
        addLog(zh ? '已恢复 $restored 条历史任务记录' : 'Restored $restored task record(s)',
            category: 'info');
      }
    } catch (_) {}
    // 无论有没有恢复记录，都清一次孤儿导入缓存：
    // 上次退出时用户可能已清空列表，这些副本不会再被引用。
    await _cleanupOrphanImportCaches();
  }

  /// 清理不再被任何视频/任务引用的应用临时导入副本。
  ///
  /// 背景（Android 体积膨胀 bug）：SAF 导入的媒体会被复制到应用缓存
  /// （file_picker 缓存 / 流式导入 ffmpegpp_import_*），用户移除项目或
  /// 直接退出后这些副本就成了孤儿，应用体积只增不减。这里在启动时
  /// （恢复持久化任务之后）把无引用的副本删掉。
  ///
  /// 安全边界：只删应用自己创建的缓存目录内容（systemTemp / file_picker /
  /// docsDir/ffmpegpp_imports），绝不动用户原文件目录；且仍被视频列表或
  /// 任务（输入/输出）引用的文件一律保留。
  ///
  /// [thumbOlderThan] 为 null 时缩略图也一并清掉（用户主动清理的场景）。
  /// 返回本次释放的字节数。
  Future<int> _purgeImportCaches(
      {Duration? thumbOlderThan = const Duration(days: 3)}) async {
    var freed = 0;
    try {
      final referenced = <String>{
        for (final v in _videos) v.filepath,
        for (final t in _tasks) ...[t.inputPath, t.outputPath],
      };
      final now = DateTime.now();

      Future<void> purge(String dirPath, bool Function(String name) match,
          {Duration? olderThan}) async {
        try {
          final dir = Directory(dirPath);
          if (!await dir.exists()) return;
          await for (final ent in dir.list(recursive: true, followLinks: false)) {
            if (ent is! File) continue;
            final name = ent.path.split(RegExp(r'[\\/]')).last;
            if (!match(name)) continue;
            if (referenced.contains(ent.path)) continue;
            if (olderThan != null) {
              try {
                if (now.difference(await ent.lastModified()) < olderThan) continue;
              } catch (_) {}
            }
            try {
              // 先量体积再删：删除失败时不会把未释放的空间算进「已释放」。
              final len = await ent.length();
              await ent.delete();
              freed += len;
            } catch (_) {}
          }
        } catch (_) {}
      }

      final cacheDir = Directory.systemTemp.path;
      // 本应用流式导入产生的副本（含默认输出到输入目录的产物）
      await purge(cacheDir, (n) => n.startsWith('ffmpegpp_import_'));
      // file_picker 的 SAF 缓存目录
      await purge('$cacheDir${Platform.pathSeparator}file_picker', (n) => true);
      // 任务卡片缩略图（可重建）
      await purge(cacheDir, (n) => n.startsWith('ffmpegpp_thumb_'),
          olderThan: thumbOlderThan);
      // 旧版 ensureReadableImport 的兜底复制目录
      try {
        final docsDir = await getApplicationDocumentsDirectory();
        await purge('${docsDir.path}${Platform.pathSeparator}ffmpegpp_imports',
            (n) => true);
      } catch (_) {}
    } catch (_) {}
    return freed;
  }

  /// 启动后的静默清理（仅移动端：桌面端导入直接用原路径，不会产生副本）。
  Future<void> _cleanupOrphanImportCaches() async {
    if (!isMobilePlatform) return;
    await _purgeImportCaches();
  }

  /// 用户主动清理导入缓存（设置 → 清除缓存），返回释放的字节数。
  ///
  /// 与启动静默清理的区别：缩略图不再只清 3 天前的（可重建，用户点了就是要腾空间），
  /// 且所有平台都执行。仍被当前视频列表 / 队列任务引用的副本一律保留 —— 删掉会让
  /// 对应项目指向一个不存在的文件，调用方应把「有多少被保留、为什么」提示给用户。
  Future<int> purgeImportCachesNow() => _purgeImportCaches(thumbOlderThan: null);

  Future<void> addVideos(List<String> filepaths) async {
    _probeCount++; notifyListeners();
    addLog('添加 ${filepaths.length} 个文件', category: 'info');

    final entries = <VideoFile>[];
    for (final fp in filepaths) {
      final path = await _ensureReadableForProbe(fp);
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

  /// 把 [fp] 转换为 ffprobe/后续转码可稳定读取的路径。
  ///
  /// 设计：直接原样返回 fp，**不做任何复制**。理由：
  /// - 桌面 / Linux / Windows：fp 已经是绝对路径（file_picker 拷到系统 tmpdir），
  ///   fork+exec 子进程天然能读。
  /// - Android：file_picker 8.x 用 withReadStream 后 fp 是 app 私有 cacheDir
  ///   （`/data/data/<pkg>/cache/file_picker/...`）下的**绝对路径**，对该路径
  ///   app 有完整读权限，fork+exec 出的 ffprobe 子进程通过普通 open()
  ///   即可读取，不需要 SAF ContentResolver。
  ///
  /// 与旧实现的对比：旧版会立刻把 fp 复制到 app docsDir。后果：
  ///   1) 大文件（>100MB）复制耗时数秒，UI 卡住；
  ///   2) docsDir 体积无谓翻倍；
  ///   3) 用户每次导入都永久占一份磁盘，且删除项目时还得记得清 docsDir。
  ///
  /// 如果个别 ROM / Android 版本上 file_picker 缓存路径确实不可读，
  /// _probeOne 会在日志里给出原始错误码和路径；不再做静默兜底复制。
  Future<String> _ensureReadableForProbe(String fp) async {
    return fp;
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
          _safeNotify(); // [FIX S-6] dispose 后短路
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

  void removeVideo(String id) {
    VideoFile? removed;
    _videos.removeWhere((v) { if (v.id == id) { removed = v; return true; } return false; });
    if (removed != null) _cleanupTempImportFile(removed!.filepath);
    notifyListeners();
  }

  void clearAllVideos() {
    final paths = _videos.map((v) => v.filepath).toList();
    _videos.clear();
    for (final p in paths) { _cleanupTempImportFile(p); }
    notifyListeners();
  }

  /// 删除属于应用临时导入的缓存副本，避免「只记录路径」仍让应用体积增长：
  /// file_picker 在 Android 上会把 SAF 的 content:// 拷贝到 cacheDir/file_picker/，
  /// 本应用流式导入也会落盘 ffmpegpp_import_* 临时文件。移除项目文件时一并
  /// 清理这些副本（仅当没有其它条目仍引用同一路径时才删除）。
  void _cleanupTempImportFile(String filepath) {
    if (filepath.isEmpty) return;
    final normalized = filepath.replaceAll('\\', '/');
    final isCacheCopy = normalized.contains('file_picker') || normalized.contains('ffmpegpp_import');
    if (!isCacheCopy) return;
    if (_videos.any((v) => v.filepath == filepath)) return; // 仍有引用，不删
    // 队列/历史里的任务仍引用该副本（重新开始/查看输出），不删
    if (_tasks.any((t) => t.inputPath == filepath || t.outputPath == filepath)) return;
    try {
      final f = File(filepath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
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
  List<FileContainer> get containers => UnmodifiableListView(_containers);

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
    final entries = <VideoFile>[]; // [FIX H-4] 声明在 try 外，finally 后仍可记日志
    try {
      for (final fp in filepaths) {
        // 容器路径同样需要保证 ffprobe 可读取（Android 上 SAF 缓存路径在子进程不可见）。
        final path = await _ensureReadableForProbe(fp);
        final vf = VideoFile.fromFilepath(path);
        _videos.add(vf);
        entries.add(vf);
      }
      final items = List.generate(entries.length, (i) => ContainerItem(fileId: entries[i].id, index: i + 1));
      // [FIX H-12] items 用不可变视图，外部拿到的容器引用无法再改内部集合
      _containers.add(FileContainer(id: const Uuid().v4(), name: name, items: List.unmodifiable(items)));
      notifyListeners();
      await _probeAll(entries);
    } finally {
      _probeCount--; _safeNotify(); // [FIX H-4] 异常路径也复位，避免 probingVideos 永久为 true
    }
    addLog('创建容器 "$name"，${entries.length} 个文件', category: 'info');
  }

  /// 创建空容器（不含任何文件，用户可稍后手动添加）
  void addEmptyContainer(String name) {
    // [FIX H-12] items 用不可变空列表，外部引用无法改内部集合
    _containers.add(FileContainer(id: const Uuid().v4(), name: name, items: const <ContainerItem>[]));
    notifyListeners();
    addLog('创建空容器 "$name"', category: 'info');
  }

  Future<void> addContainerFromFolder(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    final exts = {...kImageExts, 'mp4', 'mkv', 'mov', 'avi', 'webm', 'flv', 'wmv', 'ts', 'mpg', 'mpeg', 'm4v', '3gp', ...kAudioExts};
    // 异步遍历：大目录（数千文件）下 listSync() 会同步阻塞 UI isolate。
    final files = <String>[];
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final ext = f.path.split('.').last.toLowerCase();
      if (exts.contains(ext)) files.add(f.path);
    }
    if (files.isEmpty) return;
    files.sort();
    final name = dirPath.split('/').last.split('\\').last;
    await addContainer(name, files);
  }

  void removeContainer(String containerId) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    final container = _containers[idx];
    final removedPaths = <String>[];
    for (final item in container.items) {
      _videos.removeWhere((v) {
        if (v.id == item.fileId) { removedPaths.add(v.filepath); return true; }
        return false;
      });
    }
    _containers.removeAt(idx);
    for (final p in removedPaths) { _cleanupTempImportFile(p); }
    notifyListeners();
  }

  Future<void> addFilesToContainer(String containerId, List<String> filepaths) async {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0 || filepaths.isEmpty) return;
    _probeCount++; notifyListeners();
    final container = _containers[idx];
    final baseIndex = container.items.isEmpty ? 1 : container.items.map((i) => i.index).reduce(max) + 1;
    final entries = <VideoFile>[];
    // [FIX H-12] 复制一份 items，不再直接 container.items.add(...)，写操作经 copyWith 替换元素
    final newItems = List<ContainerItem>.from(container.items);
    for (var i = 0; i < filepaths.length; i++) {
      // 容器追加文件同样需要把 SAF 缓存路径复制到应用私有目录，
      // 否则后续 ffprobe 会以"无法读取文件"失败。
      final path = await _ensureReadableForProbe(filepaths[i]);
      final vf = VideoFile.fromFilepath(path);
      _videos.add(vf);
      entries.add(vf);
      newItems.add(ContainerItem(fileId: vf.id, index: baseIndex + i));
    }
    // [FIX H-12] 生成新 FileContainer 实例（旧引用失效），items 用不可变视图
    _containers[idx] = FileContainer(
      id: container.id,
      name: container.name,
      items: List.unmodifiable(newItems),
      pipelineGraph: container.pipelineGraph,
      expanded: container.expanded,
    );
    notifyListeners();
    try {
      await _probeAll(entries);
    } finally {
      _probeCount--; _safeNotify(); // [FIX H-4] 异常路径也复位
    }
  }

  void removeFileFromContainer(String containerId, String fileId) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    // [FIX H-12] 经 copyWith 替换元素，而非直接改内部集合
    final container = _containers[idx];
    final newItems = container.items.where((i) => i.fileId != fileId).toList();
    _containers[idx] = FileContainer(
      id: container.id, name: container.name,
      items: List.unmodifiable(newItems),
      pipelineGraph: container.pipelineGraph, expanded: container.expanded,
    );
    String? removedPath;
    _videos.removeWhere((v) { if (v.id == fileId) { removedPath = v.filepath; return true; } return false; });
    if (removedPath != null) _cleanupTempImportFile(removedPath!);
    notifyListeners();
  }

  void sortContainerBy(String containerId, ContainerSortMode mode) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    final container = _containers[idx];
    // [FIX H-12] 复制一份再排序，避免直接改内部集合
    final items = List<ContainerItem>.from(container.items);
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
    // [FIX M-13] 保证 index 唯一且 1..n 重新编号（用新元素实例而非改原字段）
    final reindexed = <ContainerItem>[
      for (var i = 0; i < items.length; i++)
        ContainerItem(fileId: items[i].fileId, index: i + 1),
    ];
    _containers[idx] = FileContainer(
      id: container.id, name: container.name,
      items: List.unmodifiable(reindexed),
      pipelineGraph: container.pipelineGraph, expanded: container.expanded,
    );
    addLog('容器排序: ${mode.name}，${items.length} 个文件', category: 'info');
    notifyListeners();
  }

  void updateContainerItemIndex(String containerId, String fileId, int newIndex) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    final container = _containers[idx];
    final item = container.items.where((i) => i.fileId == fileId).firstOrNull;
    if (item != null) {
      // [FIX H-12] 经 copyWith 替换元素，而非直接改内部字段
      final newItems = container.items.map((i) => i.fileId == fileId ? ContainerItem(fileId: i.fileId, index: newIndex) : i).toList();
      _containers[idx] = FileContainer(
        id: container.id, name: container.name,
        items: List.unmodifiable(newItems),
        pipelineGraph: container.pipelineGraph, expanded: container.expanded,
      );
      notifyListeners();
    }
  }

  void updateContainerPipeline(String containerId, PipelineGraph graph) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    // [FIX H-12] 生成新实例，而非直接改可变字段
    final container = _containers[idx];
    _containers[idx] = FileContainer(
      id: container.id, name: container.name,
      items: container.items, pipelineGraph: graph, expanded: container.expanded,
    );
    notifyListeners();
  }

  void renameContainer(String containerId, String newName) {
    final idx = _containers.indexWhere((c) => c.id == containerId);
    if (idx < 0) return;
    // [FIX H-12] 生成新实例，而非直接改可变字段
    final container = _containers[idx];
    _containers[idx] = FileContainer(
      id: container.id, name: newName,
      items: container.items, pipelineGraph: container.pipelineGraph, expanded: container.expanded,
    );
    notifyListeners();
  }

  void swapContainerItems(String containerId, int idxA, int idxB) {
    final ci = _containers.indexWhere((c) => c.id == containerId);
    if (ci < 0) return;
    final container = _containers[ci];
    final items = container.items;
    // [FIX M-13] 调用方传入 item.index 值（1..n）；sortContainerBy 已保证 index 唯一，
    // 故按 index 值定位唯一命中，交换两者的列表位置与 index 值（不再因重复 index
    // 导致 firstWhere 只命中第一项而「交换了但 UI 没变」）。
    final pa = items.indexWhere((i) => i.index == idxA);
    final pb = items.indexWhere((i) => i.index == idxB);
    if (pa < 0 || pb < 0) return;
    final a = items[pa];
    final b = items[pb];
    final newItems = List<ContainerItem>.from(items);
    newItems[pa] = ContainerItem(fileId: b.fileId, index: a.index);
    newItems[pb] = ContainerItem(fileId: a.fileId, index: b.index);
    _containers[ci] = FileContainer(
      id: container.id, name: container.name,
      items: List.unmodifiable(newItems),
      pipelineGraph: container.pipelineGraph, expanded: container.expanded,
    );
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
      final video = videoById(item.fileId);
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
        .map((item) => videoById(item.fileId))
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
    _tasksNotify();
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
    final String fn = cfg.namingMode == 'keep' ? '$base.$ext' : cfg.namingMode == 'suffix' ? '$base${cfg.namingValue}.$ext' : '${cfg.namingValue}.$ext';
    String dir = config.defaultOutputDir.isNotEmpty ? config.defaultOutputDir : video.filepath.replaceAll(RegExp(r'[^\\/]+$'), '');
    // filepath 无分隔符时正则返回空串，会导致写入文件系统根目录（M-13）
    if (dir.isEmpty) dir = Directory.current.path;
    if (!dir.endsWith('/') && !dir.endsWith('\\')) dir = '$dir${Platform.pathSeparator}';
    var out = '$dir$fn';
    if (out == video.filepath) { final be = fn.replaceAll(RegExp(r'\.[^.]+$'), ''); final ee = fn.split('.').last; out = '$dir${be}_processed.$ee'; }
    _tasks.add(TaskInfo(id: 'task_${const Uuid().v4()}', videoId: videoId, filename: video.filename, inputPath: video.filepath, outputPath: out, config: cfg));
    _tasksNotify();
  }

  void _addTasksFromGraph(VideoFile video) {
    // 入队前必须做完整的图校验：环路、媒体类型匹配、悬空节点、裁剪参数、
    // 并行冲突等。此前校验只在若干 UI 入口触发，程序化入队（AI 生成图 /
    // 强制导入 / 批量入队）会绕过全部保证（H-1）。
    final errors = GraphExecutor.validateGraph(video.pipelineGraph);
    if (errors.isNotEmpty) {
      addLog('节点图校验失败，已阻止入队: ${errors.first}'
          '${errors.length > 1 ? "（共 ${errors.length} 个问题）" : ""}',
          category: 'error');
      return;
    }

    final plans = GraphExecutor.resolvePlans(video.pipelineGraph);
    if (plans.isEmpty) {
      addLog('节点图中未找到完整的 源文件→输出 任务', category: 'error');
      return;
    }
    for (var i = 0; i < plans.length; i++) {
      final plan = plans[i];
      final outputPath = GraphExecutor.resolveOutputPath(plan, video, config);
      var calls = GraphExecutor.buildBackendCalls(plan, video.filepath, outputPath);
      // buildBackendCalls 返回 null 表示执行计划构建失败（如遇到未知/不支持的
      // 节点类型），此时必须终止而不是继续入队一条断裂的链路（H-2）。
      if (calls == null) {
        // plan.warnings 里可能是「条件不满足 → 按设置中止」这类明确原因，
        // 不再统一显示成「可能包含不支持的节点类型」
        final reason = plan.warnings.isEmpty
            ? '（可能包含不支持的节点类型）'
            : '：${plan.warnings.join('；')}';
        addLog('任务 ${i + 1} 执行计划构建失败，已跳过$reason', category: 'error');
        continue;
      }
      // 计划构建期告警（如非法参数被忽略），写日志便于定位
      for (final w in plan.warnings) {
        addLog(w, category: 'warn'); // [FIX M-12] 统一拼写
      }
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
    _tasksNotify();
    _scheduleTaskPersist();
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
    _tasksNotify();
    _scheduleTaskPersist();
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
    _tasksNotify();
    // [FIX H-3/H-8] 新批次：自增 generation 并传入，旧批次在途续体不会继续拉取
    final gen = ++_runGeneration;
    processNextTask(generation: gen);
  }

  void processAllTasks() {
    _cancelRequested = false;
    // [FIX H-3/H-8] 新批次自增 generation
    final gen = ++_runGeneration;
    processNextTask(generation: gen);
  }

  /// 仅测试用：直接注入任务实例（模拟 pending/failed/流水线任务进队列页）。
  @visibleForTesting
  void addTaskForTest(TaskInfo task) {
    _tasks.add(task);
    _tasksNotify();
  }

  Future<void> processNextTask({int? generation}) async {
    final gen = generation ?? _runGeneration;
    if (_cancelRequested) return;
    final limit = config.maxConcurrentTasks == 0 ? 999 : config.maxConcurrentTasks;
    while (_runningTaskIds.length < limit) {
      if (_cancelRequested) break;
      final pi = _tasks.indexWhere((t) => t.status == TaskStatus.pending);
      if (pi < 0) break;
      // [FIX H-3] 二次确认：状态可能被并发的 cancelTask 改掉，避免已取消任务被改回 processing
      if (_tasks[pi].status != TaskStatus.pending) continue;
      final task = _tasks[pi];
      // 只有确实要开始执行时才移除取消标记（收敛 H-3 竞态窗口）
      _cancelledTaskIds.remove(task.id);
      _runningTaskIds.add(task.id);
      _currentTaskId = task.id;
      _tasks[pi] = task.copyWith(status: TaskStatus.processing);
      _tasksNotify();
      _scheduleTaskPersist();
      addLog('开始处理: ${task.filename}', category: 'info');
      addLog('输入: ${task.inputPath}', category: 'info');
      addLog('输出: ${task.outputPath}', category: 'info');
      // catchError 必不可少：后端调用一旦抛异常/超时，没有它 .then 永不执行，
      // task id 会永远滞留在 _runningTaskIds、processing 恒为 true，队列卡死。
      _runTask(task).then((_) {
        _runningTaskIds.remove(task.id);
        if (_currentTaskId == task.id) _currentTaskId = null;
        // [FIX H-3/H-8] 仅本批次仍有效才继续拉取，避免「停止所有」与「单任务取消」互相污染
        if (gen == _runGeneration && !_cancelRequested && _tasks.any((t) => t.status == TaskStatus.pending)) {
          processNextTask(generation: gen);
        }
      }).catchError((Object e, StackTrace st) {
        _runningTaskIds.remove(task.id);
        if (_currentTaskId == task.id) _currentTaskId = null;
        final fi = _tasks.indexWhere((t) => t.id == task.id);
        // 已取消的任务保持 cancelled，不被异常覆盖为 failed
        if (fi >= 0 && !_cancelRequested && _tasks[fi].status == TaskStatus.processing) {
          _tasks[fi] = _tasks[fi].copyWith(status: TaskStatus.failed, error: '处理异常: $e');
          _tasksNotify();
          _scheduleTaskPersist();
        }
        if (gen == _runGeneration && !_cancelRequested && _tasks.any((t) => t.status == TaskStatus.pending)) {
          processNextTask(generation: gen);
        }
      });
    }
  }

  Future<void> _runTask(TaskInfo task) async {
    final pi = _tasks.indexWhere((t) => t.id == task.id);
    if (pi < 0) return;
    _ensureOutputDir(task.outputPath);
    if (task.pipelineCalls != null && task.pipelineCalls!.isNotEmpty) {
      await _processPipelineTask(task.id);
    } else if (task.command != null && task.command!.isNotEmpty) {
      await _processCustomCommand(task.id, task);
    } else {
      await _processLegacyTask(task.id, task);
    }
  }

  /// 任务开始前确保输出目录存在：输出节点允许用户填一个尚不存在的目录
  ///（如 Android 的 /storage/emulated/0/Download/新目录），ffmpeg 会因
  /// 「No such file or directory」直接开输出文件失败。创建失败不拦任务，
  /// 让后端给出原始错误（多半是权限问题）。
  void _ensureOutputDir(String outputPath) {
    if (outputPath.isEmpty) return;
    final iSlash = outputPath.lastIndexOf('/');
    final iBack = outputPath.lastIndexOf('\\');
    final sepAt = iSlash > iBack ? iSlash : iBack;
    if (sepAt <= 0) return;
    try {
      final dir = Directory(outputPath.substring(0, sepAt));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      addLog('输出目录已就绪: ${dir.path}', category: 'info');
    } catch (e) {
      addLog('输出目录创建失败（继续尝试处理）: $e', category: 'warn');
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
    // 进度消息先登记、按 300ms 批量冲刷（见类头「进度心跳节流」注释），
    // 不再每条消息都 notifyListeners() → 整棵订阅树全量重建。
    sub = backend.progressStream.listen((u) {
      if (u.taskId == taskId) {
        _queueProgress(taskId, () {
          final i = _tasks.indexWhere((t) => t.id == taskId);
          // 已取消/已完成/已失败的任务不再被进度消息改回 processing
          if (i < 0 || _tasks[i].status != TaskStatus.processing) return false;
          _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: u.progress, elapsed: u.currentTime, remaining: u.remaining, speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame);
          return true;
        });
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
      _tasksNotify();
      _scheduleTaskPersist();
    }
  }

  /// 处理用户自定义 FFmpeg 命令任务
  Future<void> _processCustomCommand(String taskId, TaskInfo task) async {
    addLog('自定义命令: ${task.command!.join(' ')}', category: 'info');

    StreamSubscription<ProgressUpdate>? sub;
    // 进度消息先登记、按 300ms 批量冲刷（见类头「进度心跳节流」注释），
    // 不再每条消息都 notifyListeners() → 整棵订阅树全量重建。
    sub = backend.progressStream.listen((u) {
      if (u.taskId == taskId) {
        _queueProgress(taskId, () {
          final i = _tasks.indexWhere((t) => t.id == taskId);
          // 已取消/已完成/已失败的任务不再被进度消息改回 processing
          if (i < 0 || _tasks[i].status != TaskStatus.processing) return false;
          _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: u.progress, elapsed: u.currentTime, remaining: u.remaining, speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame);
          return true;
        });
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
      _tasksNotify();
      _scheduleTaskPersist();
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
    //
    // 展平之后每一轮都是**普通的 BackendCall**（loopCount=1），执行循环完全不知道
    // 「循环」这件事存在。逻辑块的新增能力全部在这里落地：
    //   · 区间循环（序号 = loopIndexBase + k × loopIndexStep）
    //   · 迭代变量 {i} / {i0} / {n}（含嵌套 Map / List）
    //   · 链式累积（accumulate：本轮输入 = 上一轮输出）
    //   · 失败策略与重试（透传给执行层）
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
        final total = call.loopCount;
        // 组内是否用了迭代变量：用了就不再叠 `_loop_N` 后缀 ——
        // 用户已经用 {i} 指定了每轮各自的输出名，再加后缀会得到 `out_1_loop_2.jpg`
        final usesVars = call.useVars && group.any((gc) => _hasIterationVar(gc.params));
        // 链式累积：上一轮该组的最终产物，作为本轮第一条 call 的输入
        String? carryInput;

        // Duplicate the entire group N times, rewriting input/output paths
        for (var li = 0; li < total; li++) {
          final seq = call.loopIndexBase + li * call.loopIndexStep;
          final isLastIter = li == total - 1;
          final pathMap = <String, String>{}; // old path -> new loop path
          String? iterTailOutput;

          for (var gi = 0; gi < group.length; gi++) {
            final gc = group[gi];
            final p = gc.params;
            var loopParams = Map<String, dynamic>.from(p);
            if (call.useVars) {
              // 变量替换放在最前面：output / output_dir / input 的统一按替换后的
              // 值做路径映射，避免「output 含 {i}、下游 input 也含 {i}」时匹配不上
              loopParams = _substituteIterationVars(loopParams, seq, li, total)
                  as Map<String, dynamic>;
            }
            // 链式累积：本轮首条 call 的输入换成上一轮的最终产物
            if (call.accumulate && gi == 0 && carryInput != null) {
              loopParams['input'] = carryInput;
            }
            // Rewrite output path
            final output = loopParams['output'] as String? ?? '';
            if (output.isNotEmpty) {
              // 显式写了 {i} 时输出名由用户负责（含末轮），不再自动加后缀
              final newOutput = (isLastIter || usesVars) ? output : _loopPath(output, li + 1);
              pathMap[output] = newOutput;
              loopParams['output'] = newOutput;
              iterTailOutput = newOutput;
              if (!isLastIter) loopCleanupPaths.add(newOutput);
            }
            // 帧提取输出目录（range/all）也要随循环迭代改写，避免各迭代写进同一目录
            final outputDir = loopParams['output_dir'] as String? ?? '';
            if (outputDir.isNotEmpty) {
              final newOutputDir =
                  (isLastIter || usesVars) ? outputDir : _loopPath(outputDir, li + 1);
              loopParams['output_dir'] = newOutputDir;
              if (!isLastIter) loopCleanupPaths.add(newOutputDir);
            }
            // Rewrite input path if it was a previous step's output in this group
            final input = loopParams['input'] as String? ?? '';
            if (input.isNotEmpty && pathMap.containsKey(input)) {
              loopParams['input'] = pathMap[input]!;
            }
            expandedCalls.add(BackendCall(
              action: gc.action,
              params: loopParams,
              // 失败的「跳过 / 中止」与重试次数随 call 一起进执行层
              errorPolicy: gc.errorPolicy,
              retries: gc.retries,
            ));
          }
          if (call.accumulate) carryInput = iterTailOutput;
        }
        ci2 = j;
      } else {
        // 拷贝参数以允许运行时改写（如 extract_audio 改扩展名后修正下游 input），不污染原任务快照
        expandedCalls.add(BackendCall(
          action: call.action,
          params: Map<String, dynamic>.from(call.params),
          loopCount: call.loopCount,
          loopMode: call.loopMode,
          errorPolicy: call.errorPolicy,
          retries: call.retries,
        ));
        ci2++;
      }
    }
    // 循环中间产物与正常临时文件一起清理（成功/失败路径都会执行 _cleanupTempFiles）
    for (final path in loopCleanupPaths) {
      cleanupCalls.add(BackendCall(action: '_cleanup', params: {'path': path}));
    }

    addLog('节点图任务: ${expandedCalls.length} 步', category: 'info');

    // 初始化每步进度追踪
    final callProgresses = List<double>.filled(expandedCalls.length, 0.0);
    final fi0 = _tasks.indexWhere((t) => t.id == taskId);
    if (fi0 >= 0) {
      _tasks[fi0] = _tasks[fi0].copyWith(callProgresses: callProgresses);
      _tasksNotify();
    }

    // [FIX M-14] 记录「计划产物路径 -> 实际产物路径」映射：extract_audio 等会运行时改写
    // 扩展名，下游 input 需要跟随最近一个实际产物，而非只看紧邻上一步（否则中间有不消费
    // input 的步骤时链路断裂，第三步指向不存在的旧路径）。
    final actualOutputFor = <String, String>{};
    for (var ci = 0; ci < expandedCalls.length; ci++) {
      // 取消后不再执行后续步骤（本地 Process.run 步骤无法被 kill，必须靠这里停下）
      if (_cancelRequested || _cancelledTaskIds.contains(taskId)) break;
      final call = expandedCalls[ci];
      // 沿执行链向前查找：若本步 input 等于某步「计划 output」且那一步改写了实际产物，
      // 则用实际产物路径替换（中间有「不消费/不产出」的步骤也不会断裂）。
      final inp = call.params['input'];
      if (inp is String && actualOutputFor.containsKey(inp)) {
        call.params['input'] = actualOutputFor[inp]!;
      }
      final stepProgress = ci / expandedCalls.length;

      final fi = _tasks.indexWhere((t) => t.id == taskId);
      if (fi >= 0) {
        _tasks[fi] = _tasks[fi].copyWith(currentCallIndex: ci, progress: stepProgress * 100);
        _tasksNotify();
      }

      addLog('步骤 ${ci + 1}/${expandedCalls.length}: ${call.action}', category: 'info');

      StreamSubscription<ProgressUpdate>? sub;
      // 进度消息先登记、按 300ms 批量冲刷（见类头「进度心跳节流」注释）
      sub = backend.progressStream.listen((u) {
        if (u.taskId == taskId) {
          _queueProgress(taskId, () {
            final i = _tasks.indexWhere((t) => t.id == taskId);
            // 已取消/已完成/已失败的任务不再被进度消息改回 processing
            if (i < 0 || _tasks[i].status != TaskStatus.processing) return false;
            final overallProgress = (stepProgress + u.progress / 100 / expandedCalls.length) * 100;
            // 更新当前步骤的进度
            final newCallProgresses = List<double>.from(_tasks[i].callProgresses);
            if (ci < newCallProgresses.length) {
              newCallProgresses[ci] = u.progress / 100;
            }
            _tasks[i] = _tasks[i].copyWith(
              status: TaskStatus.processing,
              progress: overallProgress.clamp(0, 100),
              callProgresses: newCallProgresses,
              elapsed: u.currentTime, remaining: u.remaining,
              speed: u.speed, fps: u.fps, bitrate: u.bitrate, frame: u.frame,
            );
            return true;
          });
        }
      });

      // 失败重试：逻辑块的 retries 参数（attempt 从 0 数到 retries）。
      // resp 带初值，保证「重试耗尽后 break 出来」也能安全读取。
      Map<String, dynamic> resp = const <String, dynamic>{};
      try {
      for (var attempt = 0; ; attempt++) {
      final p = call.params;
      switch (call.action) {
        case 'transcode':
          // 缺 options 时用空对象兜底：直接 as 转换会抛 TypeError 被外层 catch
          // 捕获成不可读的「处理异常」（L-3）。
          resp = await backend.transcode(task.id,
              input: p['input'] as String, output: p['output'] as String,
              options: (p['options'] as Map<String, dynamic>?) ?? const <String, dynamic>{});
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
        case 'image_adjust':
          resp = await _runImageAdjust(p);
          break;
        case 'video_crop':
          resp = await _runVideoCrop(taskId, p, callIndex: ci);
          break;
        case 'extract_audio':
          resp = await _runExtractAudio(taskId, p, callIndex: ci);
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
      // 成功即结束；否则还有重试次数就再跑一遍（参数未变，重跑是安全的）
      if (resp['success'] == true || attempt >= call.retries) break;
      addLog('步骤 ${ci + 1} 重试 ${attempt + 1}/${call.retries}: ${call.action}',
          category: 'warning');
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
        // 失败策略（逻辑块参数 onError）：
        //   'continue' → 记一条警告日志后跳过本步，继续后面的步骤；
        //   'stop'（默认）→ 立即把任务判为失败并中断。
        // 末步永远不允许跳过 —— 跳过「写最终产物」那一步等于任务没有产物。
        final isLastStep = ci == expandedCalls.length - 1;
        if (call.errorPolicy == 'continue' && !isLastStep) {
          addLog('步骤 ${ci + 1} 失败，已按「跳过继续」策略忽略: ${resp['error']}',
              category: 'warning');
          continue;
        }
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
          _tasksNotify();
          _scheduleTaskPersist();
        }
        _cleanupTempFiles(cleanupCalls);
        return;
      }
      // 标记当前步骤为完成
      final fiDone = _tasks.indexWhere((t) => t.id == taskId);
      if (fiDone >= 0) {
        final newCallProgresses = List<double>.from(_tasks[fiDone].callProgresses);
        if (ci < newCallProgresses.length) {
          newCallProgresses[ci] = 1.0;
        }
        _tasks[fiDone] = _tasks[fiDone].copyWith(callProgresses: newCallProgresses);
        notifyListeners();
      }
      addLog('步骤 ${ci + 1} 完成', category: 'info');
      final actualOut = resp['_actual_output'];
      if (actualOut is String && actualOut.isNotEmpty) {
        // [FIX M-14] 记录 计划->实际 映射，供后续任意步骤按 input 命中替换
        final planned = call.params['output'];
        if (planned is String) {
          actualOutputFor[planned] = actualOut;
        }
        // 运行时改写了产物路径（典型：extract_audio 的 copy 模式按源编码换扩展名）。
        // 原计划里登记的中间文件路径已经是「不存在的旧路径」，必须把清理清单里的
        // 对应项改成真实路径，否则真实中间文件会永久残留在临时目录（M-7）。
        if (planned is String && planned != actualOut && ci < expandedCalls.length - 1) {
          for (var k = 0; k < cleanupCalls.length; k++) {
            if (cleanupCalls[k].params['path'] == planned) {
              cleanupCalls[k] = BackendCall(
                  action: '_cleanup',
                  params: {'path': actualOut});
            }
          }
        }
      }
    }

    final fi3 = _tasks.indexWhere((t) => t.id == taskId);
    if (fi3 >= 0 && !_cancelRequested && _tasks[fi3].status == TaskStatus.processing) {
      final outSize = await _measureOutputSize(task.outputPath);
      _tasks[fi3] = _tasks[fi3].copyWith(status: TaskStatus.completed, progress: 100, outputSize: outSize);
      addLog('任务完成: ${task.filename}', category: 'info');
      onTaskFinished?.call(task.filename, TaskStatus.completed);
      _tasksNotify();
      _scheduleTaskPersist();
    }

    _cleanupTempFiles(cleanupCalls);
  }

  /// 计算任务产物的体积。
  /// 帧提取任务可能产出上万张 PNG；原实现用 listSync() 一次性枚举目录、
  /// 再对每一项调用 lengthSync()（N 次同步 stat），在「任务完成」这一关键
  /// 交互时刻会把 UI isolate 冻结数秒。改为异步遍历 + 异步 stat，
  /// 单次遍历同时完成计数与求和，统计失败时返回 null（UI 显示为「—」）。
  Future<int?> _measureOutputSize(String outputPath) async {
    try {
      final type = await FileSystemEntity.type(outputPath);
      if (type == FileSystemEntityType.file) {
        return await File(outputPath).length();
      }
      if (type == FileSystemEntityType.directory) {
        var total = 0;
        await for (final f in Directory(outputPath).list()) {
          if (f is! File) continue;
          try {
            total += await f.length();
          } catch (_) {
            // 单项 stat 失败（文件被并发删除等）跳过，不影响其余统计
          }
        }
        return total;
      }
    } catch (_) {
      // 路径不可访问：交给 UI 显示「—」
    }
    return null;
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
        // 异步遍历目录计数：帧提取可产出上万张 PNG，原 listSync() 会在
        // UI isolate 同步枚举全部目录项并构造 File 对象，导致界面冻结。
        var count = 0;
        final suffix = '.$fmt';
        await for (final f in dir.list()) {
          if (f.path.endsWith(suffix)) count++;
        }
        addLog('帧提取完成: $count 帧 → $outDir', category: 'info');
        return {'success': true, 'data': {'output_path': outDir, 'frame_count': count}};
      } else {
        return _ffmpegFailResult('帧提取', (result.stderr as String).trim(), args);
      }
    } catch (e) {
      return {'success': false, 'error': '帧提取异常: $e'};
    }
  }

  // ── ffmpeg/ffprobe 可执行路径缓存 ──
  // 原实现每次读取都做一次 File.existsSync()（同步 stat）。这两个 getter 在
  // 任务热路径上被高频调用（每个探测/每个步骤/循环任务内每轮），
  // 累计成千上万次零收益的同步系统调用。路径在运行期几乎不变，
  // 仅在 config 变更（updateConfig）或环境重检（recheckEnv）时失效。
  String? _cachedFfmpegBin;
  String? _cachedFfprobeBin;
  /// 使路径缓存失效，下次读取时重新解析并各做一次 existsSync。
  void _invalidateBinCache() {
    _cachedFfmpegBin = null;
    _cachedFfprobeBin = null;
  }

  String get _ffmpegBin {
    final cached = _cachedFfmpegBin;
    if (cached != null) return cached;
    final p = config.ffmpegPath;
    return _cachedFfmpegBin = (p.isNotEmpty && File(p).existsSync()) ? p : 'ffmpeg';
  }

  /// 本地 ffmpeg 失败结果：error 只保留最后几行（卡片横幅摘要），
  /// 完整 stderr（截尾 120 行）与执行命令放进 data.log_lines/data.command，
  /// 否则队列卡片展开后「详细错误/日志」为空，无法排查（如缺 libwebp 编码器）。
  Map<String, dynamic> _ffmpegFailResult(String label, String stderr, List<String> args) {
    final lines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
    var errMsg = lines.length > 3 ? lines.sublist(lines.length - 3).join('; ') : stderr;
    // 编码器缺失（如旧构建缺 libwebp）给出可操作的提示
    if (errMsg.contains('Encoder not found')) {
      final zh = config.language == 'zh';
      errMsg += zh
          ? '；当前内置 FFmpeg 缺少该格式的编码器，请更新应用或改用 PNG/JPEG'
          : '; the bundled FFmpeg lacks this encoder — update the app or use PNG/JPEG';
    }
    addLog('$label失败: $errMsg', category: 'error');
    return {
      'success': false,
      'error': '$label失败: $errMsg',
      'data': {
        'log_lines': lines.length > 120 ? lines.sublist(lines.length - 120) : lines,
        'command': [_ffmpegBin, ...args],
      },
    };
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
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('图片转换', (result.stderr as String).trim(), args);
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
    var cropX = (p['crop_x'] as num?)?.toInt() ?? 0;
    var cropY = (p['crop_y'] as num?)?.toInt() ?? 0;

    if (cropW <= 0 || cropH <= 0) {
      return {'success': false, 'error': '裁剪尺寸无效 (${cropW}x$cropH)'};
    }

    // 按源尺寸钳制裁剪矩形：越界的 crop 参数会让 ffmpeg 直接报错
    // （"Invalid too big or non positive size"），此前表现为任务失败或
    // 用户误以为"输出与输入相同"。这里探测源宽高后做统一钳制。
    final src = await _probeImageSize(input);
    int useW = cropW, useH = cropH;
    if (src != null) {
      final (sw, sh) = src;
      if (cropX < 0) cropX = 0;
      if (cropY < 0) cropY = 0;
      if (cropX >= sw || cropY >= sh) {
        return {'success': false, 'error': '裁剪起点 ($cropX,$cropY) 超出图片范围 ${sw}x$sh'};
      }
      useW = cropW.clamp(1, sw - cropX);
      useH = cropH.clamp(1, sh - cropY);
      if (useW != cropW || useH != cropH) {
        addLog('裁剪尺寸按源图片调整为 ${useW}x$useH (源 ${sw}x$sh)', category: 'info');
      }
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final cropFilter = 'crop=$useW:$useH:$cropX:$cropY';
      final args = <String>['-y', '-i', input, '-vf', cropFilter, output];
      addLog('图片裁剪: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片裁剪完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('图片裁剪', (result.stderr as String).trim(), args);
      }
    } catch (e) {
      addLog('图片裁剪异常: $e', category: 'error');
      return {'success': false, 'error': '图片裁剪异常: $e'};
    }
  }

  Future<Map<String, dynamic>> _runVideoCrop(String taskId, Map<String, dynamic> p, {int? callIndex}) async {
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
      return await _runFfmpegWithProgress(taskId, args, '视频裁剪', totalDuration: totalDuration, callIndex: callIndex);
    } catch (e) {
      addLog('视频裁剪异常: $e', category: 'error');
      return {'success': false, 'error': '视频裁剪异常: $e'};
    }
  }

  String get _ffprobeBin {
    final cached = _cachedFfprobeBin;
    if (cached != null) return cached;
    final p = config.ffprobePath;
    return _cachedFfprobeBin = (p.isNotEmpty && File(p).existsSync()) ? p : 'ffprobe';
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

  /// 探测图片/视频首条视频流的宽高（像素）。失败返回 null。
  /// 用于裁剪参数按源尺寸钳制、绝对尺寸缩放换算缩放系数。
  Future<(int, int)?> _probeImageSize(String input) async {
    try {
      final result = await Process.run(_ffprobeBin, [
        '-v', 'quiet',
        '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height',
        '-of', 'csv=s=x:p=0',
        input,
      ]);
      if (result.exitCode == 0) {
        final out = (result.stdout as String).trim();
        final parts = out.split(RegExp(r'[xX,]'));
        if (parts.length >= 2) {
          final w = int.tryParse(parts[0].trim());
          final h = int.tryParse(parts[1].trim());
          if (w != null && h != null && w > 0 && h > 0) return (w, h);
        }
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
  void _parseFfmpegProgressLine(String taskId, String line, double? totalDuration, int? callIndex) {
    if (line.isEmpty) return;
    final m = _ffmpegTimeRe.firstMatch(line);
    if (m != null && totalDuration != null && totalDuration > 0) {
      final frac = m.group(4)!;
      final t = int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!) + int.parse(frac) / pow(10, frac.length);
      final pct = (t / totalDuration * 100).clamp(0, 99.9);
      final sm = _speedRe.firstMatch(line);
      final speed = sm != null ? '${sm.group(1)}x' : '';
      // 本地 ffmpeg 的 stderr 进度行同样高频，走 300ms 批量节流
      // （见类头「进度心跳节流」注释），避免每行都整树重建。
      _queueProgress(taskId, () {
        final i = _tasks.indexWhere((tk) => tk.id == taskId);
        if (i < 0 || _tasks[i].status != TaskStatus.processing) return false;
        List<double> newCallProgresses = _tasks[i].callProgresses;
        if (callIndex != null && callIndex < _tasks[i].callProgresses.length) {
          newCallProgresses = List<double>.from(_tasks[i].callProgresses);
          newCallProgresses[callIndex] = pct / 100;
        }
        _tasks[i] = _tasks[i].copyWith(status: TaskStatus.processing, progress: pct.toDouble(), speed: speed, callProgresses: newCallProgresses);
        return true;
      });
    }
  }

  Future<Map<String, dynamic>> _runFfmpegWithProgress(String taskId, List<String> args, String label, {double? totalDuration, int? callIndex}) async {
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
          _parseFfmpegProgressLine(taskId, text.substring(start, nl), totalDuration, callIndex);
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
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult(label, stderr, args);
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

  Future<Map<String, dynamic>> _runExtractAudio(String taskId, Map<String, dynamic> p, {int? callIndex}) async {
    final input = p['input'] as String;
    var output = p['output'] as String;
    final codec = p['audio_codec'] as String? ?? 'copy';
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
          addLog('copy 模式: $sourceCodec 不兼容 $outExt, 自动切换为 $bestFmt', category: 'warn'); // [FIX M-12] 统一拼写
          output = output.replaceAll(RegExp(r'\.[^.]+$'), '.$bestFmt');
        }
      } else if (codec == 'copy') {
        output = output.replaceAll(RegExp(r'\.[^.]+$'), '.mka');
        addLog('copy 模式: 未知源编码, 使用 mka 容器', category: 'warn'); // [FIX M-12] 统一拼写
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
      final result = await _runFfmpegWithProgress(taskId, args, '提取音频', totalDuration: clipDuration, callIndex: callIndex);
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
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('图片旋转', (result.stderr as String).trim(), args);
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
      String vf;
      if (mode == 'absolute') {
        // 绝对尺寸模式（快捷配置「缩放」）：探测源尺寸换算缩放系数，
        // 目标短边优先、等比缩放，保持纵横比不变形。
        final src = await _probeImageSize(input);
        if (src == null) {
          return {'success': false, 'error': '无法读取源图片尺寸，缩放失败'};
        }
        final (sw, sh) = src;
        final targetW = (p['target_w'] as num?)?.toInt() ?? 0;
        final targetH = (p['target_h'] as num?)?.toInt() ?? 0;
        final double fW = targetW > 0 ? targetW / sw : 0;
        final double fH = targetH > 0 ? targetH / sh : 0;
        factor = switch ((fW > 0, fH > 0)) {
          (true, true) => (fW < fH ? fW : fH), // 两边都给了 → 取小值（contain）
          (true, false) => fW,
          (false, true) => fH,
          _ => 1.0,
        };
        addLog('图片缩放(绝对): ${sw}x$sh → 目标 ${targetW}x$targetH, 系数 ${factor.toStringAsFixed(3)}', category: 'info');
        vf = 'scale=trunc(iw*$factor/2)*2:trunc(ih*$factor/2)*2';
      } else {
        vf = 'scale=trunc(iw*$factor/2)*2:trunc(ih*$factor/2)*2';
      }
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('图片缩放: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片缩放完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('图片缩放', (result.stderr as String).trim(), args);
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
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('图片亮度调整', (result.stderr as String).trim(), args);
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
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('图片噪声添加', (result.stderr as String).trim(), args);
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
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('图片锐化', (result.stderr as String).trim(), args);
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
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('图片降噪', (result.stderr as String).trim(), args);
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
        // 完整 stderr + 命令一并返回，队列卡片「详细错误」可查看
        return _ffmpegFailResult('通道提取', (result.stderr as String).trim(), args);
      }
    } catch (e) {
      addLog('通道提取异常: $e', category: 'error');
      return {'success': false, 'error': '通道提取异常: $e'};
    }
  }


  /// 图片调整：饱和度 / 伽马 / 对比度（eq 滤镜）。
  /// 三个参数都为默认值时退化为"直接复制"，避免无意义的二次编码。
  Future<Map<String, dynamic>> _runImageAdjust(Map<String, dynamic> p) async {
    final input = p['input'] as String;
    final output = p['output'] as String;
    final sat = _clampNum(p['saturation'], 0.0, 3.0, 1.0);
    final gamma = _clampNum(p['gamma'], 0.1, 10.0, 1.0);
    final contrast = _clampNum(p['contrast'], 0.0, 4.0, 1.0);

    if (sat == 1.0 && gamma == 1.0 && contrast == 1.0) {
      addLog('图片调整: 参数均为默认值，直接复制', category: 'info');
      return _runFileCopy(p);
    }

    try {
      final outDir = File(output).parent;
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final vf = 'eq=saturation=${sat.toStringAsFixed(3)}'
          ':gamma=${gamma.toStringAsFixed(3)}'
          ':contrast=${contrast.toStringAsFixed(3)}';
      final args = <String>['-y', '-i', input, '-vf', vf, output];
      addLog('图片调整: $_ffmpegBin ${args.join(' ')}', category: 'info');
      final result = await Process.run(_ffmpegBin, args);
      if (result.exitCode == 0 && File(output).existsSync()) {
        addLog('图片调整完成: $output', category: 'info');
        return {'success': true, 'data': {'output_path': output}};
      } else {
        return _ffmpegFailResult('图片调整', (result.stderr as String).trim(), args);
      }
    } catch (e) {
      addLog('图片调整异常: $e', category: 'error');
      return {'success': false, 'error': '图片调整异常: $e'};
    }
  }

  /// 数值钳制（非法值回退 fallback），用于滤镜参数防注入。
  static double _clampNum(dynamic raw, double lo, double hi, double fallback) {
    final v = (raw as num?)?.toDouble();
    if (v == null || !v.isFinite) return fallback;
    return v.clamp(lo, hi).toDouble();
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

  /// 参数值里是否含迭代占位符（`{i}` / `{i0}` / `{n}`）。
  ///
  /// 递归扫描嵌套 Map / List —— 节点参数里有大量嵌套结构（options、files 等）。
  static bool _hasIterationVar(dynamic value) {
    if (value is String) {
      return value.contains('{i}') ||
          value.contains('{i0}') ||
          value.contains('{i:') ||
          value.contains('{i0:') ||
          value.contains('{n}');
    }
    if (value is Map) return value.values.any(_hasIterationVar);
    if (value is List) return value.any(_hasIterationVar);
    return false;
  }

  /// 迭代变量替换（循环块每轮的参数改写）。
  ///
  /// | 占位符 | 含义 |
  /// |---|---|
  /// | `{i}` | 当前轮序号（固定模式 1,2,3…；区间模式取 from, from+step…） |
  /// | `{i0}` | 当前轮次（0-based，做「第几轮」偏移计算时更顺手） |
  /// | `{n}` | 总轮数 |
  /// | `{i:03}` / `{i0:02}` | 补零到指定宽度 |
  ///
  /// 只改 String（含嵌套 Map / List 中的），数字与布尔原样保留。
  /// 典型用法：输出名 `frame_{i:03}.jpg`、裁剪偏移 `{i0} * 100`、
  /// 抽帧时间 `{i0} * 0.5`。
  static dynamic _substituteIterationVars(dynamic value, int seq, int zeroSeq, int total) {
    if (value is String) {
      if (!value.contains('{')) return value;
      return value
          .replaceAllMapped(RegExp(r'\{i0:(\d+)\}'),
              (m) => zeroSeq.toString().padLeft(int.tryParse(m[1]!) ?? 0, '0'))
          .replaceAllMapped(RegExp(r'\{i:(\d+)\}'),
              (m) => seq.toString().padLeft(int.tryParse(m[1]!) ?? 0, '0'))
          .replaceAll('{i0}', '$zeroSeq')
          .replaceAll('{i}', '$seq')
          .replaceAll('{n}', '$total');
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      value.forEach((k, v) => out['$k'] = _substituteIterationVars(v, seq, zeroSeq, total));
      return out;
    }
    if (value is List) {
      return value.map((e) => _substituteIterationVars(e, seq, zeroSeq, total)).toList();
    }
    return value;
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
    if (await dir.exists()) {
      // 异步遍历：抽帧目录可能有上万文件，listSync() 会阻塞 UI isolate。
      final files = <String>[];
      await for (final f in dir.list()) {
        if (f is File) files.add(f.path);
      }
      files.sort();
      return files;
    }
    if (await File(input).exists()) return [input];
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
    // [FIX H-3/H-8] 终止所有在途调度批次：在途 .then 续体比对 generation 失效，不再继续拉取
    _runGeneration++;
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
    _runningTaskIds.clear(); _currentTaskId = null; _tasksNotify();
    _scheduleTaskPersist();
  }

  /// 只取消单个任务：其余 pending/processing 任务继续，不影响全局取消标记。
  void cancelTask(String taskId) {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i < 0) return;
    final st = _tasks[i].status;
    if (st != TaskStatus.processing && st != TaskStatus.pending) return;
    // [FIX H-3] 先置状态（copyWith cancelled），再写取消标记：避免「置 processing」与
    // 「写 cancelledTaskIds」之间的竞态窗口丢失取消意图。
    _tasks[i] = _tasks[i].copyWith(status: TaskStatus.cancelled);
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
    _tasksNotify();
    _scheduleTaskPersist();
    // 单任务取消不触碰 _cancelRequested / _runGeneration，继续当前批次拉取
    if (!_cancelRequested && _tasks.any((t) => t.status == TaskStatus.pending)) {
      processNextTask();
    }
  }

  void clearCompletedTasks() {
    // 记录被清除任务的输入路径：若是应用导入缓存副本且不再被引用，一并删除，
    // 避免「列表清了但缓存还在」导致应用体积只增不减。
    final removedInputs = _tasks
        .where((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed || t.status == TaskStatus.cancelled)
        .map((t) => t.inputPath)
        .toList();
    _tasks.removeWhere((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed || t.status == TaskStatus.cancelled);
    for (final p in removedInputs) { _cleanupTempImportFile(p); }
    _tasksNotify();
    _scheduleTaskPersist();
  }

  void removeTask(String id) {
    String? removedInput;
    _tasks.removeWhere((t) {
      if (t.id == id) { removedInput = t.inputPath; return true; }
      return false;
    });
    if (removedInput != null) _cleanupTempImportFile(removedInput!);
    _tasksNotify();
    _scheduleTaskPersist();
  }

  void clearAllTasks() {
    if (!processing) {
      final removedInputs = _tasks.map((t) => t.inputPath).toList();
      _tasks.clear();
      for (final p in removedInputs) { _cleanupTempImportFile(p); }
      _tasksNotify();
      _scheduleTaskPersist();
    }
  }
  void toggleTaskExpanded(String tid) { final i = _tasks.indexWhere((t) => t.id == tid); if (i >= 0) { _tasks[i] = _tasks[i].copyWith(expanded: !_tasks[i].expanded); _tasksNotify(); } }

  Future<void> toggleDarkMode(bool v) async { await configService.update((c) => c..darkMode = v); notifyListeners(); }
  Future<void> updateConfig(AppConfig Function(AppConfig) f) async {
    await configService.update(f);
    _invalidateBinCache(); // ffmpeg/ffprobe 路径可能已变更
    notifyListeners();
  }

  Future<Map<String, dynamic>> recheckEnv() async {
    addLog('检测 FFmpeg 环境...', category: 'info');
    _invalidateBinCache();
    await backend.setPaths(ffmpeg: config.ffmpegPath, ffprobe: config.ffprobePath);
    final env = await backend.checkEnv();
    _envOk = env['success'] == true && (env['data']?['all_ok'] as bool? ?? false);
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
  /// 记录当前打开的节点编辑器画布（供 MCP error_check / get_graph_stats /
  /// pipeline://current 读取）。编辑器关闭时应传 null 清空，
  /// 否则这些工具会返回已关闭画布的陈旧数据。
  void setCurrentPipeline(PipelineGraph? g) { _currentPipelineGraph = g; }
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
        addLog('[MCP] 服务已启动 (监听 $host:$port)，访问令牌: $_mcpToken — 请勿泄露', category: 'warn'); // [FIX M-12] 统一拼写
      }
      final server = _mcpServer!;
      server.listen((req) {
        _handleMcpRequest(req);
      }, onError: (e) {
        addLog('[MCP] 连接错误: $e', category: 'error');
      }, onDone: () {
        // 只有「当前仍是这个实例」才清空：stopMcpServer 已提前置空并可能
        // 紧接着 start 了新实例，此处若无条件置空会把新服务误标为已停止。
        if (!identical(_mcpServer, server)) return;
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
    final server = _mcpServer;
    if (server == null) return;
    // 先清引用：close() 会触发 onDone（内部也会置空并 notify），
    // 这里提前置空避免「停止中又被 startMcpServer 认为仍在运行」。
    _mcpServer = null;
    // force: true —— 普通 close() 会等所有活跃连接自然结束；MCP 客户端常保持
    // 长连接，退出应用时会卡在这里（此前表现为关闭窗口后进程残留）。
    await server.close(force: true);
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
        addLog('[MCP] 拒绝未授权请求 (${req.connectionInfo?.remoteAddress})', category: 'warn'); // [FIX M-12] 统一拼写
        req.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.contentType = ContentType.json
          ..write('{"jsonrpc":"2.0","error":{"code":-32000,"message":"Unauthorized: missing or invalid x-mcp-token header"}}');
        await req.response.close();
        return;
      }
    }
    // H-2/M-11：仅本机监听时，额外校验来源确为回环地址。用 InternetAddress.isLoopback
    // 属性（而非字符串比较 / 构造 InternetAddress('::1')，后者在部分平台解析失败），
    // 防止监听回环却被非回环来源越权访问本机任意进程可调用的 MCP 接口。
    final bindHost = config.mcpHost.isEmpty ? '127.0.0.1' : config.mcpHost;
    const loopbackHosts = {'127.0.0.1', 'localhost', '::1'};
    if (loopbackHosts.contains(bindHost)) {
      final remote = req.connectionInfo?.remoteAddress;
      if (remote != null && !remote.isLoopback) {
        addLog('[MCP] 拒绝非回环来源: $remote', category: 'warn');
        req.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType.json
          ..write('{"jsonrpc":"2.0","error":{"code":-32000,"message":"Forbidden: non-loopback origin"}}');
        await req.response.close();
        return;
      }
    }
    try {
      // M-10：请求体流式累计并限制上限（4MB）。先累计原始字节再一次性解码，避免多字节
      // UTF-8 跨块截断；超出上限立即断开回 -32600。真正的 JSON 解析错误由下方
      // FormatException 统一回 -32700。
      const maxBodyBytes = 4 * 1024 * 1024;
      final all = <int>[]; // 累积原始字节，避免引入 dart:typed_data 依赖
      var tooBig = false;
      await for (final chunk in req) {
        all.addAll(chunk);
        if (all.length > maxBodyBytes) { tooBig = true; break; }
      }
      if (tooBig) {
        req.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write('{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request: body too large"}}');
        await req.response.close();
        return;
      }
      final body = utf8.decode(all, allowMalformed: true);
      final decoded = jsonDecode(body);

      // JSON-RPC 2.0 批量请求（MCP 规范允许）：数组中的每个请求各产生一条响应，
      // 通知（无 id）不产生响应；全部是通知时按规范返回 202 空体。
      if (decoded is List) {
        final responses = <Map<String, dynamic>>[];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final r = await _handleMcpJsonRpcItem(item);
            if (r != null) responses.add(r);
          } else {
            // 批量中混入非对象元素：按 Invalid Request 回错（id 未知则为 null）
            responses.add({
              'jsonrpc': '2.0', 'id': null,
              'error': {'code': -32600, 'message': 'Invalid Request: batch items must be objects'},
            });
          }
        }
        req.response
          ..statusCode = responses.isEmpty ? HttpStatus.accepted : HttpStatus.ok
          ..headers.contentType = ContentType.json;
        if (responses.isNotEmpty) req.response.write(jsonEncode(responses));
        await req.response.close();
        return;
      }

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Request body must be a JSON object or array');
      }
      final single = await _handleMcpJsonRpcItem(decoded);
      req.response
        ..statusCode = single == null ? HttpStatus.accepted : HttpStatus.ok
        ..headers.contentType = ContentType.json;
      if (single != null) req.response.write(jsonEncode(single));
      await req.response.close();
    } on FormatException catch (e) {
      addLog('[MCP] Parse error: $e', category: 'error');
      req.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}');
      await req.response.close();
    } catch (e) {
      addLog('[MCP] Error: $e', category: 'error');
      try {
        // M-10：内部异常用 -32603（区别于解析失败的 -32700），按语义区分
        req.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write('{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}');
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 本服务可协商的 MCP 协议版本（capabilities 在这些版本间兼容：
  /// tools + resources 均为核心能力）。
  static const Set<String> _mcpSupportedVersions = {'2024-11-05', '2025-03-26', '2025-06-18'};
  static const String _mcpDefaultVersion = '2024-11-05';

  /// 处理单个 JSON-RPC 消息，返回响应对象；通知（无 id）返回 null（不回应）。
  Future<Map<String, dynamic>?> _handleMcpJsonRpcItem(Map<String, dynamic> json) async {
    final id = json['id'];
    final method = json['method'] as String? ?? '';
    final params = json['params'] as Map<String, dynamic>? ?? {};

    // JSON-RPC 通知（没有 id，如 notifications/initialized、
    // notifications/cancelled）按规范「绝不能」返回响应体：MCP 客户端收到
    // 带 id:null 的响应会当成协议错误报警。
    if (!json.containsKey('id') || id == null) return null;

    switch (method) {
      case 'initialize':
        // 版本协商：客户端请求的版本在支持集合内则原样回显；
        // 不支持时按规范返回服务器自己的最新受支持版本（此处为基线版本）。
        final requested = params['protocolVersion'];
        final negotiated = requested is String && _mcpSupportedVersions.contains(requested)
            ? requested
            : _mcpDefaultVersion;
        return {
          'jsonrpc': '2.0', 'id': id,
          'result': {
            'protocolVersion': negotiated,
            'capabilities': {'tools': {}, 'resources': {}},
            'serverInfo': {'name': 'ffmpegpp', 'version': '5.13.37'},
          },
        };
      // MCP 规范要求的心跳：客户端定期 ping 判定连接存活，
      // 缺失时部分客户端会认为服务器已失联并断开。返回空结果即表示存活。
      case 'ping':
        return {'jsonrpc': '2.0', 'id': id, 'result': {}};
      case 'tools/list':
        // nextCursor 省略 = 无更多分页（工具数量固定且很小，无需真实分页，
        // 但保留字段语义以兼容会检查分页的客户端）。
        return {'jsonrpc': '2.0', 'id': id, 'result': {'tools': _mcpToolsList()}};
      case 'tools/call':
        final toolName = params['name'] as String? ?? '';
        final args = params['arguments'] as Map<String, dynamic>? ?? {};
        final (result, isError) = await _mcpCallTool(toolName, args);
        return {
          'jsonrpc': '2.0', 'id': id,
          'result': {'content': [{'type': 'text', 'text': result}], if (isError) 'isError': true},
        };
      case 'resources/list':
        return {'jsonrpc': '2.0', 'id': id, 'result': {'resources': _mcpResourcesList()}};
      case 'resources/read':
        final uri = params['uri'] as String? ?? '';
        // H-2/M-11：所有资源接口（含文件名/用户路径）受文件系统访问开关约束
        if (!config.mcpAllowFsAccess) {
          return {
            'jsonrpc': '2.0', 'id': id,
            'error': {'code': -32000, 'message': 'MCP file system access is disabled — enable "Allow file access" in Settings → AI'},
          };
        }
        // M-10：未知资源视为参数非法，回 -32602
        const knownResources = {'pipeline://current', 'videos://loaded', 'tasks://all'};
        if (!knownResources.contains(uri)) {
          return {
            'jsonrpc': '2.0', 'id': id,
            'error': {'code': -32602, 'message': 'Unknown resource: $uri'},
          };
        }
        final result = _mcpReadResource(uri);
        return {
          'jsonrpc': '2.0', 'id': id,
          'result': {'contents': [{'uri': uri, 'mimeType': 'application/json', 'text': result}]},
        };
      default:
        return {
          'jsonrpc': '2.0', 'id': id,
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        };
    }
  }

  /// 工具清单。出口统一给每个 inputSchema 补 `additionalProperties: false`，
  /// 让客户端（及其后的 LLM）在传入未定义字段时能立刻收到 schema 校验错误，
  /// 而不是被服务端静默忽略后困惑于「参数没生效」。
  List<Map<String, dynamic>> _mcpToolsList() {
    final tools = _mcpToolsRaw();
    for (final t in tools) {
      final schema = t['inputSchema'];
      if (schema is Map<String, dynamic>) {
        schema.putIfAbsent('additionalProperties', () => false);
      }
    }
    return tools;
  }

  // L-12：工具 schema 为纯静态结构（不依赖运行期权限开关），构建一次缓存复用，
  // 避免每次 tools/list 都重新编码 27 个 map 造成同步 JSON 编码卡顿。
  static final List<Map<String, dynamic>> _mcpToolsRawCache = _buildMcpToolsRaw();
  static List<Map<String, dynamic>> _buildMcpToolsRaw() => [
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

  List<Map<String, dynamic>> _mcpToolsRaw() => _mcpToolsRawCache;

  List<Map<String, dynamic>> _mcpResourcesList() => [
    {'uri': 'pipeline://current', 'name': 'Current Pipeline', 'mimeType': 'application/json'},
    {'uri': 'videos://loaded', 'name': 'Loaded Videos', 'mimeType': 'application/json'},
    {'uri': 'tasks://all', 'name': 'Task Queue', 'mimeType': 'application/json'},
  ];

  // H-2/M-11：MCP 文件系统工具允许访问的「根目录」集合（项目内已知目录）。
  // 仅系统临时目录、默认输出目录、应用导入缓存目录，防止枚举全盘。
  Future<List<String>> _mcpAllowedRoots() async {
    final roots = <String>[];
    roots.add(Directory.systemTemp.path); // 临时工作目录
    if (config.defaultOutputDir.isNotEmpty) roots.add(config.defaultOutputDir); // 输出目录
    try {
      final docs = await getApplicationDocumentsDirectory();
      roots.add('${docs.path}${Platform.pathSeparator}ffmpegpp_imports'); // 导入缓存目录
    } catch (_) {}
    return roots;
  }

  // 规范化后判断 [normalized] 是否等于 root 或以 root + 分隔符为前缀
  bool _mcpPathWithin(String normalized, String root) {
    final r = root.replaceAll('\\', '/');
    final n = normalized.replaceAll('\\', '/');
    return n == r || n.startsWith('$r/');
  }

  Future<bool> _mcpFsAllowed(String path) async {
    final normalized = path.replaceAll('\\', '/');
    final roots = await _mcpAllowedRoots();
    for (final r in roots) {
      if (_mcpPathWithin(normalized, r)) return true;
    }
    return false;
  }

  Future<(String, bool)> _mcpCallTool(String name, Map<String, dynamic> args) async {
    // 写操作需在设置里开启 MCP 写入权限（默认只读，防止未经授权的修改）
    const writeTools = {'clear_all', 'undo', 'redo', 'save', 'modify_node_params', 'add_node', 'delete_node', 'connect_nodes', 'disconnect_nodes', 'cancel_tasks', 'add_gate', 'set_gate_params', 'rename_node'};
    if (writeTools.contains(name) && !config.mcpAllowWrite) {
      return ('Error: MCP write access is disabled — enable "Allow write" in Settings → AI', true);
    }
    // 文件系统类工具受独立开关门控（回环监听无令牌，本机任意进程都能调用，
    // 用户可关闭以禁用目录枚举/文件信息/媒体探测三个读取入口）。read_logs 与
    // 资源接口会泄露文件名/用户路径，同样纳入本开关（H-2/M-11）。
    const fsTools = {'list_directory', 'read_file_info', 'probe_video', 'read_logs'};
    if (fsTools.contains(name) && !config.mcpAllowFsAccess) {
      return ('Error: MCP file system access is disabled — enable "Allow file access" in Settings → AI', true);
    }
    const noEditor = 'Error: No editor open — open a pipeline editor first';
    switch (name) {
      case 'clear_all':
        if (mcpOnClearAll == null) return (noEditor, true);
        mcpOnClearAll!();
        return ('Canvas cleared', false);
      case 'undo':
        if (mcpOnUndo == null) return (noEditor, true);
        mcpOnUndo!();
        return ('Undo executed', false);
      case 'redo':
        if (mcpOnRedo == null) return (noEditor, true);
        mcpOnRedo!();
        return ('Redo executed', false);
      case 'save':
        if (mcpOnSave == null) return (noEditor, true);
        mcpOnSave!();
        return ('Save executed', false);
      case 'list_directory':
        final path = args['path'] as String? ?? '.';
        try {
          // H-2/M-11：仅允许项目内已知目录，拒绝越界枚举全盘
          // （_mcpFsAllowed 是 async：漏 await 会得到 Future<bool>，
          //   `!Future` 直接编译不过 —— 这里补上 await）
          if (!await _mcpFsAllowed(path)) {
            return ('Error: path not allowed: $path (MCP 仅允许项目内已知目录)', true);
          }
          final dir = Directory(path);
          if (!await dir.exists()) return ('Error: directory not found: $path', true);
          // 异步遍历，避免在 UI isolate 同步 listSync/statSync 卡界面；
          // 限制单次返回条目数（.take(50)）与深度（list 非递归，深度 1）
          final entries = <Map<String, dynamic>>[];
          await for (final e in dir.list().take(50)) {
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
          // H-2/M-11：用 FileSystemEntity.type() 返回真实类型，不再靠扩展名猜测
          // （无扩展名文件原返回 "Dockerfile"、目录 "/home/user" 原返回 "user"，语义错误）
          final type = await FileSystemEntity.type(path);
          final typeStr = switch (type) {
            FileSystemEntityType.file => 'file',
            FileSystemEntityType.directory => 'directory',
            FileSystemEntityType.link => 'link',
            _ => 'not_found',
          };
          final s = await File(path).stat();
          return (jsonEncode({'path': path, 'size': s.size, 'modified': s.modified.toIso8601String(), 'type': typeStr}), false);
        } catch (e) { return ('Error: $e', true); }
      case 'modify_node_params':
        final nodeId = args['nodeId'] as String? ?? '';
        final params = args['params'] as Map<String, dynamic>? ?? {};
        if (mcpOnModifyNode == null) return (noEditor, true);
        if (mcpOnModifyNode!(nodeId, params)) {
          return ('Node $nodeId params updated', false);
        }
        return ('Error: node $nodeId not found on canvas', true);
      case 'error_check':
        if (_currentPipelineGraph == null) return (noEditor, true);
        // 委托给与执行链一致的完整校验器（环路/逻辑门/连线类型/悬空节点等），
        // 此前这里是一份只查 start/output/悬空的弱化拷贝，会与真实校验结论相左。
        final errors = GraphExecutor.validateGraph(_currentPipelineGraph!);
        return (errors.isEmpty ? 'No errors found' : errors.join('; '), false);
      case 'add_node':
        if (mcpOnAddNode == null) return (noEditor, true);
        final typeName = args['type'] as String? ?? '';
        final x = (args['x'] as num?)?.toDouble() ?? 200;
        final y = (args['y'] as num?)?.toDouble() ?? 200;
        try {
          final nodeId = mcpOnAddNode!(typeName, x, y);
          return ('Node added: $nodeId (type: $typeName)', false);
        } catch (e) { return ('Error: $e', true); }
      case 'delete_node':
        if (mcpOnDeleteNode == null) return (noEditor, true);
        final nodeId = args['nodeId'] as String? ?? '';
        try { mcpOnDeleteNode!(nodeId); return ('Node $nodeId deleted', false); }
        catch (e) { return ('Error: $e', true); }
      case 'connect_nodes':
        if (mcpOnConnect == null) return (noEditor, true);
        final fromId = args['fromNodeId'] as String? ?? '';
        final toId = args['toNodeId'] as String? ?? '';
        final ok = mcpOnConnect!(fromId, toId);
        return ok ? ('Connected $fromId → $toId', false) : ('Error: Connection failed (invalid nodes or already connected)', true);
      case 'disconnect_nodes':
        if (mcpOnDisconnect == null) return (noEditor, true);
        final connId = args['connectionId'] as String? ?? '';
        final ok = mcpOnDisconnect!(connId);
        return ok ? ('Connection $connId removed', false) : ('Error: Connection not found', true);
      case 'list_nodes':
        if (mcpOnListNodes == null) return (noEditor, true);
        return (jsonEncode(mcpOnListNodes!()), false);
      case 'list_connections':
        if (mcpOnListConnections == null) return (noEditor, true);
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
        if (mcpOnAddGate == null) return (noEditor, true);
        final gateType = args['type'] as String? ?? '';
        final gx = (args['x'] as num?)?.toDouble() ?? 200;
        final gy = (args['y'] as num?)?.toDouble() ?? 200;
        try {
          final nodeId = mcpOnAddGate!(gateType, gx, gy);
          return ('Gate added: $nodeId (type: $gateType)', false);
        } catch (e) { return ('Error: $e', true); }
      case 'set_gate_params':
        if (mcpOnModifyNode == null) return (noEditor, true);
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
        if (mcpOnModifyNode == null) return (noEditor, true);
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
    // 队列结果历史同样落盘（防抖未触发时强制写一次）
    await _persistTasksNow();
    await stopMcpServer();
    await pythonProcess.shutdown();
  }

  @override
  void dispose() {
    _disposed = true; // [FIX S-6] 之后所有 _safeNotify 直接短路
    _taskPersistTimer?.cancel();
    _progressFlushTimer?.cancel();
    _progressLogNotifyTimer?.cancel();
    configService.dispose();
    // backend 是 late final：这一次访问有可能才是它的首次构造（连带建立 audit 订阅），
    // 所以必须「先 dispose 再取消订阅」，顺序反了会漏掉这条晚建的订阅。
    backend.dispose();
    _auditSub?.cancel(); // [FIX audit]
    _auditSub = null;
    pythonProcess.dispose();
    super.dispose();
  }
}
