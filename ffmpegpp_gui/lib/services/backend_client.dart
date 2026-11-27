import 'dart:async';
import '../models/models.dart';
import 'diagnostic_trace.dart';
import 'native_process.dart';

/// 高层 API 客户端
/// 封装 JSON 协议，提供类型安全的调用接口
class BackendClient {
  final NativeProcessManager _process;
  final DiagnosticTrace? _trace;
  final _progressController = StreamController<ProgressUpdate>.broadcast();
  final _auditController = StreamController<List<String>>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _sub;

  bool _disposed = false;

  // Keep the optional injection parameter public.
  // ignore: prefer_initializing_formals
  BackendClient(this._process, {DiagnosticTrace? trace}) : _trace = trace {
    _sub = _process.responses.listen((obj) {
      if (_disposed) return;
      final t = obj['type'] as String?;
      if (t == 'progress') {
        try {
          _progressController.add(ProgressUpdate.fromJson(obj));
        } catch (_) {}
      } else if (t == 'audit') {
        try {
          final warnings = (obj['warnings'] as List).cast<String>();
          _auditController.add(warnings);
        } catch (_) {}
      }
    });
  }

  /// Shared opt-in diagnostics; a disposed client cannot start new spans.
  DiagnosticTrace? get diagnosticTrace => _disposed ? null : _trace;

  Stream<ProgressUpdate> get progressStream => _progressController.stream;
  Stream<List<String>> get auditStream => _auditController.stream;

  /// Whether this native backend has the bounded WebAssembly plugin ABI.
  Future<Map<String, dynamic>> configurePluginRoot(String root) => _traceRequest(
    'plugin_set_root',
    () => _process.requestWithTimeout('plugin_set_root', 5, {'root': root}),
    requestFields: 1,
  );

  Future<Map<String, dynamic>> pluginCapabilities() => _traceRequest(
    'plugin_capabilities',
    () => _process.requestWithTimeout('plugin_capabilities', 5),
    requestFields: 0,
  );

  /// Execute one bounded plugin export inside the native WASM sandbox.
  /// [timeoutSeconds] is deliberately larger than the per-call guest budget so
  /// the backend watchdog can terminate and serialize the result first.
  Future<Map<String, dynamic>> invokePlugin({
    required String modulePath,
    required String entry,
    required Map<String, dynamic> request,
    required Map<String, dynamic> limits,
    int timeoutSeconds = 10,
  }) => _traceRequest(
    'plugin_invoke',
    () => _process.requestWithTimeout('plugin_invoke', timeoutSeconds.clamp(1, 90), {
      'module_path': modulePath,
      'entry': entry,
      'request': request,
      'limits': limits,
    }),
    requestFields: 4,
  );

  // ── 后端正在执行的任务 id ──────────────────────────────────────────────
  // 暂停只允许作用在「确实有一个可冻结的进程」的任务上。仅凭 TaskInfo.status
  // == processing 判断是不够的：流水线任务的当前步骤可能是 Dart 侧短命的
  // Process.run（图片转换等），也可能正处于两步之间的空档；此时如果照样给
  // 后端记一个暂停标记并改 UI 状态，就是「假暂停」。这里记录哪些 task id 的
  // 请求真的还在后端里跑，AppState 据此决定暂停能否真正生效。
  final Set<String> _activeTaskIds = <String>{};

  /// 该任务的请求当前是否仍在后端执行（暂停可真正冻结它的 ffmpeg 子进程）。
  bool isTaskRunning(String taskId) => _activeTaskIds.contains(taskId);

  Future<Map<String, dynamic>> _traceRequest(
    String operation,
    Future<Map<String, dynamic>> Function() request, {
    int? requestFields,
  }) async {
    final span = _disposed ? null : _trace?.begin(
      'backend.request',
      details: {
        'action': operation,
        'requestFields': ?requestFields,
      },
    );
    if (span == null) return request();
    try {
      final result = await request();
      if (!_disposed) {
        span.finish(
          success: result['success'] == true,
          cancelled: result['cancelled'] == true,
          details: {
            'action': operation,
            'responseFields': result.length,
            'itemCount': ?_resultCount(result),
            if (result['success'] is! bool)
              'failureKind': 'malformed_response'
            else if (result['success'] == false)
              'failureKind': 'backend_rejected',
          },
        );
      }
      return result;
    } catch (error) {
      if (!_disposed) {
        span.finish(success: false, details: {
          'action': operation,
          'failureKind': error is TimeoutException
              ? 'timeout'
              : error is FormatException
              ? 'malformed_response'
              : 'transport_failure',
        });
      }
      rethrow;
    }
  }

  static int? _resultCount(Map<String, dynamic> result) {
    final data = result['data'];
    if (data is List) return data.length;
    if (data is Map) return data.length;
    return null;
  }

  Future<Map<String, dynamic>> _runTracked(
    String taskId,
    Future<Map<String, dynamic>> Function() start,
  ) async {
    _activeTaskIds.add(taskId);
    try {
      return await start();
    } finally {
      _activeTaskIds.remove(taskId);
    }
  }

  /// 冻结 / 解冻后端里该任务的 ffmpeg 子进程（真实进程级暂停）。
  Future<Map<String, dynamic>> pause(String taskId) =>
      _traceRequest('pause', () => _process.pause([taskId]), requestFields: 1);

  Future<Map<String, dynamic>> resume(String taskId) => _traceRequest(
    'resume',
    () => _process.resume([taskId]),
    requestFields: 1,
  );

  /// 检查 ffmpeg 环境
  Future<Map<String, dynamic>> checkEnv() async {
    final resp = await _traceRequest(
      'check_env',
      () => _process.request('check_env'),
      requestFields: 0,
    );
    return resp;
  }

  /// 设置 ffmpeg/ffprobe 路径（告知 C++ 后端使用前端配置的路径）
  /// [tempDir] 非空时同时注入临时目录（Android 无 /tmp，使用应用缓存目录）
  Future<void> setPaths({
    String ffmpeg = '',
    String ffprobe = '',
    String? tempDir,
  }) async {
    if (ffmpeg.isEmpty &&
        ffprobe.isEmpty &&
        (tempDir == null || tempDir.isEmpty)) {
      return;
    }
    await _traceRequest(
      'set_paths',
      () => _process.request('set_paths', {
        'ffmpeg': ffmpeg,
        'ffprobe': ffprobe,
        if (tempDir != null && tempDir.isNotEmpty) 'temp_dir': tempDir,
      }),
      requestFields: tempDir != null && tempDir.isNotEmpty ? 3 : 2,
    );
  }

  /// 探测视频文件信息（240s 超时）。
  /// 大文件（>100MB）在 mobile 上 ffprobe 需要更长——probesize/analyzeduration
  /// 限制已收紧（5MB / 10s），但首调 + 解码仍可能数秒到数十秒。120s 早期值对
  /// 1GB 视频偶发超时报"未知错误"，闪退常见原因是 ANR dialog 被关；240s 留足
  /// 余量，并由 probe.cpp 的 16MB 输出硬限避免失控。
  Future<Map<String, dynamic>> probe(String filepath) async {
    final resp = await _traceRequest(
      'probe',
      () => _process.requestWithTimeout('probe', 240, {'filepath': filepath}),
      requestFields: 1,
    );
    return resp;
  }

  /// 视频转码（taskId 用于匹配进度推送）
  Future<Map<String, dynamic>> transcode(
    String taskId, {
    required String input,
    required String output,
    required Map<String, dynamic> options,
  }) {
    return _runTracked(
      taskId,
      () => _traceRequest(
        'transcode',
        () => _process.requestWithId(taskId, 'transcode', {
          'input': input,
          'output': output,
          'options': options,
        }),
        requestFields: 3,
      ),
    );
  }

  /// 字幕烧录
  Future<Map<String, dynamic>> subtitle(
    String taskId, {
    required String input,
    required String output,
    required Map<String, dynamic> subtitleOptions,
    Map<String, dynamic>? videoOptions,
  }) {
    return _runTracked(
      taskId,
      () => _traceRequest(
        'subtitle',
        () => _process.requestWithId(taskId, 'subtitle', {
          'input': input,
          'output': output,
          'subtitle_options': subtitleOptions,
          'video_options': ?videoOptions,
        }),
        requestFields: videoOptions == null ? 3 : 4,
      ),
    );
  }

  /// 取消当前任务；[taskIds] 非空时同时取消队列中未开始的任务
  void cancel([List<String>? taskIds]) {
    final span = _disposed ? null : _trace?.begin(
      'backend.cancel',
      details: {'itemCount': taskIds?.length ?? 0},
    );
    span?.record('backend.cancel.request');
    try {
      _process.cancel(taskIds);
      if (!_disposed) span?.finish(success: true);
    } catch (_) {
      if (!_disposed) {
        span?.finish(success: false, details: {'failureKind': 'transport_failure'});
      }
      rethrow;
    }
  }

  /// 执行用户自定义 FFmpeg 命令（命令全文交给后端执行）
  Future<Map<String, dynamic>> customCommand(
    String taskId, {
    required String command,
    required String input,
    required String output,
  }) {
    return _runTracked(
      taskId,
      () => _traceRequest(
        'custom_command',
        () => _process.requestWithId(taskId, 'custom_command', {
          'command': command,
          'input': input,
          'output': output,
        }),
        requestFields: 3,
      ),
    );
  }

  /// 帧提取
  Future<Map<String, dynamic>> extractFrame(
    String taskId, {
    required String input,
    required String output,
    required double time,
  }) {
    return _runTracked(
      taskId,
      () => _traceRequest(
        'extract_frame',
        () => _process.requestWithId(taskId, 'extract_frame', {
          'input': input,
          'output': output,
          'time': time,
        }),
        requestFields: 3,
      ),
    );
  }

  /// 删除元数据（图片 / 音频 / 视频通用，C++ 端 stream copy，不重编码）
  Future<Map<String, dynamic>> removeMetadata(
    String taskId, {
    required String input,
    required String output,
    bool keepChapters = false,
    bool removeCover = false,
  }) {
    return _runTracked(
      taskId,
      () => _traceRequest(
        'remove_metadata',
        () => _process.requestWithId(taskId, 'remove_metadata', {
          'input': input,
          'output': output,
          if (keepChapters) 'keep_chapters': true,
          if (removeCover) 'remove_cover': true,
        }),
        requestFields: 2 + (keepChapters ? 1 : 0) + (removeCover ? 1 : 0),
      ),
    );
  }

  /// 合并音频/视频
  Future<Map<String, dynamic>> concat(
    String taskId, {
    required List<String> files,
    required String output,
    String mode = 'copy',
    Map<String, dynamic>? options,
  }) async {
    return _runTracked(
      taskId,
      () => _traceRequest(
        'concat',
        () => _process.requestWithId(taskId, 'concat', {
          'files': files,
          'output': output,
          'mode': mode,
          'options': ?options,
        }),
        requestFields: options == null ? 3 : 4,
      ),
    );
  }

  /// 图片序列→视频
  Future<Map<String, dynamic>> imageSequence(
    String taskId, {
    required List<String> files,
    required String output,
    required double framerate,
    Map<String, dynamic>? options,
  }) async {
    return _runTracked(
      taskId,
      () => _traceRequest(
        'image_sequence',
        () => _process.requestWithId(taskId, 'image_sequence', {
          'files': files,
          'output': output,
          'framerate': framerate,
          'options': ?options,
        }),
        requestFields: options == null ? 3 : 4,
      ),
    );
  }

  // ── FPPX 配置文件（新版 v2 / 旧版迁移），由 C++ 端直接读写文件 ──

  /// 导入 .fppx（自动路由：C++ 按文件头第 5 字节判别新旧格式后分发，
  /// Dart 不读配置文件的任何字节）。
  /// [force]=true 表示用户确认强制导入未知节点类型。
  /// [password] 仅用于加密文件；为空且文件已加密时，C++ 端返回
  /// success=false 且 data.need_password=true（不是错误），GUI 据此弹口令框后重调。
  /// 返回 data: {mode, is_new_format, description, encrypted, need_password,
  ///             graph?, quick_items?, errors, warnings, unknown_type_ids, forced}
  Future<Map<String, dynamic>> fppxImport(
    String path, {
    bool force = false,
    String password = '',
  }) async {
    return _traceRequest(
      'fppx_import',
      () => _process.requestWithTimeout('fppx_import', 30, {
        'path': path,
        'force': force,
        'password': password,
      }),
      requestFields: 3,
    );
  }

  /// 导出新版 .fppx。mode: 1=节点编辑器(需 graph) 2=快速模式(需 quickItems)。
  /// C++ 端写盘前完整校验；校验失败时 success=false 且 data.errors 带回原因。
  /// [encrypted]=true 时 [password] 必须非空（空口令 C++ 端一律拒绝）；
  /// [encryptAlgo] 见 FppxService.algoAes128Cbc / algoAes256Cbc（默认 AES-256-CBC）。
  Future<Map<String, dynamic>> fppx2Export(
    String path, {
    required int mode,
    required String description,
    Map<String, dynamic>? graph,
    List<dynamic>? quickItems,
    bool encrypted = false,
    String password = '',
    int encryptAlgo = 0x02,
  }) async {
    return _traceRequest(
      'fppx2_export',
      () => _process.requestWithTimeout('fppx2_export', 30, {
        'path': path,
        'mode': mode,
        'description': description,
        'encrypted': encrypted,
        'password': password,
        'encrypt_algo': encryptAlgo,
        'graph': ?graph,
        'quick_items': ?quickItems,
      }),
      requestFields: 8,
    );
  }

  /// 导出旧版 .fppx（与 Dart FppxExporter 输出逐字节兼容）。
  Future<Map<String, dynamic>> fppxLegacyExport(
    String path, {
    required Map<String, dynamic> graph,
    required String description,
  }) async {
    return _traceRequest(
      'fppx_legacy_export',
      () => _process.requestWithTimeout('fppx_legacy_export', 30, {
        'path': path,
        'graph': graph,
        'description': description,
      }),
      requestFields: 3,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub?.cancel();
    _progressController.close();
    _auditController.close();
  }
}
