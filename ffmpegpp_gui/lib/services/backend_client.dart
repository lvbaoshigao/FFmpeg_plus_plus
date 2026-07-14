import 'dart:async';
import '../models/models.dart';
import 'native_process.dart';

/// 高层 API 客户端
/// 封装 JSON 协议，提供类型安全的调用接口
class BackendClient {
  final NativeProcessManager _process;
  final _progressController = StreamController<ProgressUpdate>.broadcast();
  final _auditController = StreamController<List<String>>.broadcast();

  BackendClient(this._process) {
    _process.responses.listen((obj) {
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
  Future<void> setPaths({String ffmpeg = '', String ffprobe = ''}) async {
    if (ffmpeg.isEmpty && ffprobe.isEmpty) return;
    await _process.request('set_paths', {'ffmpeg': ffmpeg, 'ffprobe': ffprobe});
  }

  /// 探测视频文件信息（60s 超时）
  Future<Map<String, dynamic>> probe(String filepath) async {
    final resp = await _process.requestWithTimeout('probe', 60, {'filepath': filepath});
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
      if (videoOptions != null) 'video_options': videoOptions,
    });
    return resp;
  }

  /// 取消当前任务
  void cancel() => _process.cancel();

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

  /// ping 检测连接
  Future<bool> ping() async {
    try {
      final resp = await _process.request('ping');
      return resp['success'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 合并音频/视频
  Future<Map<String, dynamic>> concat(String taskId, {
    required List<String> files, required String output,
    String mode = 'copy', Map<String, dynamic>? options,
  }) async {
    return await _process.requestWithId(taskId, 'concat', {
      'files': files, 'output': output, 'mode': mode,
      if (options != null) 'options': options,
    });
  }

  /// 图片序列→视频
  Future<Map<String, dynamic>> imageSequence(String taskId, {
    required List<String> files, required String output,
    required double framerate, Map<String, dynamic>? options,
  }) async {
    return await _process.requestWithId(taskId, 'image_sequence', {
      'files': files, 'output': output, 'framerate': framerate,
      if (options != null) 'options': options,
    });
  }

  void dispose() {
    _progressController.close();
    _auditController.close();
  }
}
