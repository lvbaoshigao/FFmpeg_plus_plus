import 'dart:async';
import '../models/models.dart';
import 'python_process.dart';

/// 高层 API 客户端
/// 封装 JSON 协议，提供类型安全的调用接口
class BackendClient {
  final PythonProcessManager _process;
  final _progressController = StreamController<ProgressUpdate>.broadcast();
  final _auditController = StreamController<List<String>>.broadcast();

  BackendClient(this._process) {
    _process.responses.listen((obj) {
      if (obj['type'] == 'progress') {
        try {
          _progressController.add(ProgressUpdate.fromJson(obj));
        } catch (_) {}
      } else if (obj['type'] == 'audit') {
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

  /// 探测视频文件信息
  Future<Map<String, dynamic>> probe(String filepath) async {
    final resp = await _process.request('probe', {'filepath': filepath});
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

  /// ping 检测连接
  Future<bool> ping() async {
    try {
      final resp = await _process.request('ping');
      return resp['success'] == true;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _progressController.close();
    _auditController.close();
  }
}
