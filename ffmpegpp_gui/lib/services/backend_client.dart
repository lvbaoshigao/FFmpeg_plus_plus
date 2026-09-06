import 'dart:async';
import '../models/models.dart';
import 'native_process.dart';

/// 高层 API 客户端
/// 封装 JSON 协议，提供类型安全的调用接口
class BackendClient {
  final NativeProcessManager _process;
  final _progressController = StreamController<ProgressUpdate>.broadcast();
  final _auditController = StreamController<List<String>>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _sub;

  BackendClient(this._process) {
    _sub = _process.responses.listen((obj) {
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

  Stream<ProgressUpdate> get progressStream => _progressController.stream;
  Stream<List<String>> get auditStream => _auditController.stream;

  /// 检查 ffmpeg 环境
  Future<Map<String, dynamic>> checkEnv() async {
    final resp = await _process.request('check_env');
    return resp;
  }

  /// 设置 ffmpeg/ffprobe 路径（告知 C++ 后端使用前端配置的路径）
  /// [tempDir] 非空时同时注入临时目录（Android 无 /tmp，使用应用缓存目录）
  Future<void> setPaths({String ffmpeg = '', String ffprobe = '', String? tempDir}) async {
    if (ffmpeg.isEmpty && ffprobe.isEmpty && (tempDir == null || tempDir.isEmpty)) return;
    await _process.request('set_paths', {
      'ffmpeg': ffmpeg,
      'ffprobe': ffprobe,
      if (tempDir != null && tempDir.isNotEmpty) 'temp_dir': tempDir,
    });
  }

  /// 探测视频文件信息（240s 超时）。
  /// 大文件（>100MB）在 mobile 上 ffprobe 需要更长——probesize/analyzeduration
  /// 限制已收紧（5MB / 10s），但首调 + 解码仍可能数秒到数十秒。120s 早期值对
  /// 1GB 视频偶发超时报"未知错误"，闪退常见原因是 ANR dialog 被关；240s 留足
  /// 余量，并由 probe.cpp 的 16MB 输出硬限避免失控。
  Future<Map<String, dynamic>> probe(String filepath) async {
    final resp = await _process.requestWithTimeout('probe', 240, {'filepath': filepath});
    return resp;
  }

  /// 查询 FFmpeg 支持的功能（codecs/formats/filters/protocols，20s 超时）
  Future<Map<String, dynamic>> queryFeatures() async {
    final resp = await _process.requestWithTimeout('query_ffmpeg_features', 20);
    return resp;
  }

  /// 视频转码（taskId 用于匹配进度推送）
  Future<Map<String, dynamic>> transcode(String taskId, {
    required String input,
    required String output,
    required Map<String, dynamic> options,
  }) async {
    final resp = await _process.requestWithId(taskId, 'transcode', {
      'input': input,
      'output': output,
      'options': options,
    });
    return resp;
  }

  /// 字幕烧录
  Future<Map<String, dynamic>> subtitle(String taskId, {
    required String input,
    required String output,
    required Map<String, dynamic> subtitleOptions,
    Map<String, dynamic>? videoOptions,
  }) async {
    final resp = await _process.requestWithId(taskId, 'subtitle', {
      'input': input,
      'output': output,
      'subtitle_options': subtitleOptions,
      'video_options': ?videoOptions,
    });
    return resp;
  }

  /// 取消当前任务；[taskIds] 非空时同时取消队列中未开始的任务
  void cancel([List<String>? taskIds]) => _process.cancel(taskIds);

  /// 执行用户自定义 FFmpeg 命令（命令全文交给后端执行）
  Future<Map<String, dynamic>> customCommand(String taskId, {
    required String command,
    required String input,
    required String output,
  }) async {
    final resp = await _process.requestWithId(taskId, 'custom_command', {
      'command': command,
      'input': input,
      'output': output,
    });
    return resp;
  }

  /// 帧提取
  Future<Map<String, dynamic>> extractFrame(String taskId, {
    required String input,
    required String output,
    required double time,
  }) async {
    final resp = await _process.requestWithId(taskId, 'extract_frame', {
      'input': input,
      'output': output,
      'time': time,
    });
    return resp;
  }

  /// 合并音频/视频
  Future<Map<String, dynamic>> concat(String taskId, {
    required List<String> files, required String output,
    String mode = 'copy', Map<String, dynamic>? options,
  }) async {
    return await _process.requestWithId(taskId, 'concat', {
      'files': files, 'output': output, 'mode': mode,
      'options': ?options,
    });
  }

  /// 图片序列→视频
  Future<Map<String, dynamic>> imageSequence(String taskId, {
    required List<String> files, required String output,
    required double framerate, Map<String, dynamic>? options,
  }) async {
    return await _process.requestWithId(taskId, 'image_sequence', {
      'files': files, 'output': output, 'framerate': framerate,
      'options': ?options,
    });
  }

  // ── FPPX 配置文件（新版 v2 / 旧版迁移），由 C++ 端直接读写文件 ──

  /// 导入 .fppx（自动路由：C++ 按文件头第 5 字节判别新旧格式后分发，
  /// Dart 不读配置文件的任何字节）。
  /// [force]=true 表示用户确认强制导入未知节点类型。
  /// 返回 data: {mode, is_new_format, description, encrypted, graph?, quick_items?,
  ///             errors, warnings, unknown_type_ids, forced}
  Future<Map<String, dynamic>> fppxImport(String path, {bool force = false}) async {
    return await _process.requestWithTimeout(
        'fppx_import', 30, {'path': path, 'force': force});
  }

  /// 导入新版 .fppx（明确指定 v2 解析器，正常流程请用 [fppxImport]）。
  Future<Map<String, dynamic>> fppx2Import(String path, {bool force = false}) async {
    return await _process.requestWithTimeout(
        'fppx2_import', 30, {'path': path, 'force': force});
  }

  /// 导出新版 .fppx。mode: 1=节点编辑器(需 graph) 2=快速模式(需 quickItems)。
  /// C++ 端写盘前完整校验；校验失败时 success=false 且 data.errors 带回原因。
  Future<Map<String, dynamic>> fppx2Export(String path, {
    required int mode,
    required String description,
    Map<String, dynamic>? graph,
    List<dynamic>? quickItems,
    bool encrypted = false,
  }) async {
    return await _process.requestWithTimeout('fppx2_export', 30, {
      'path': path,
      'mode': mode,
      'description': description,
      'encrypted': encrypted,
      'graph': ?graph,
      'quick_items': ?quickItems,
    });
  }

  /// 导入旧版 .fppx（魔数 + 版本号 + gzip(JSON)，完整迁移自 Dart FppxExporter）。
  Future<Map<String, dynamic>> fppxLegacyImport(String path) async {
    return await _process.requestWithTimeout('fppx_legacy_import', 30, {'path': path});
  }

  /// 导出旧版 .fppx（与 Dart FppxExporter 输出逐字节兼容）。
  Future<Map<String, dynamic>> fppxLegacyExport(String path, {
    required Map<String, dynamic> graph,
    required String description,
  }) async {
    return await _process.requestWithTimeout('fppx_legacy_export', 30, {
      'path': path,
      'graph': graph,
      'description': description,
    });
  }

  void dispose() {
    _sub?.cancel();
    _progressController.close();
    _auditController.close();
  }
}
