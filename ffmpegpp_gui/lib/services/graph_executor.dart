import 'dart:io';
import '../models/models.dart';

class ExecutionStep {
  final String action;
  final List<PipelineNode> nodes;
  ExecutionStep(this.action, this.nodes);
}

class ExecutionPlan {
  final PipelineNode startNode;
  final List<ExecutionStep> steps;
  final PipelineNode? outputNode;
  ExecutionPlan({required this.startNode, required this.steps, this.outputNode});
}

class GraphExecutor {

  // ── 验证 ──

  static List<String> validateGraph(PipelineGraph graph) {
    final errors = <String>[];
    if (graph.nodes.isEmpty) {
      errors.add('画布为空，请添加节点');
      return errors;
    }

    final startNodes = graph.nodes.where((n) => n.type == PipelineStepType.start).toList();
    final outputNodes = graph.nodes.where((n) => n.type == PipelineStepType.output).toList();

    if (startNodes.isEmpty) errors.add('缺少源文件节点');
    if (outputNodes.isEmpty) errors.add('缺少输出节点');

    for (final node in graph.nodes) {
      if (node.type == PipelineStepType.start) continue;
      if (!graph.connections.any((c) => c.toNodeId == node.id)) {
        errors.add('"${node.label}" 没有输入连线');
      }
    }

    for (final node in graph.nodes) {
      if (node.type == PipelineStepType.output) continue;
      if (!graph.connections.any((c) => c.fromNodeId == node.id)) {
        errors.add('"${node.label}" 没有输出连线');
      }
    }

    for (final conn in graph.connections) {
      if (conn.fromNodeId == conn.toNodeId) {
        errors.add('存在自环连线');
      }
      final fi = graph.nodes.indexWhere((n) => n.id == conn.fromNodeId);
      final ti = graph.nodes.indexWhere((n) => n.id == conn.toNodeId);
      if (fi < 0) { errors.add('连线引用了不存在的源节点'); continue; }
      if (ti < 0) { errors.add('连线引用了不存在的目标节点'); continue; }
      if (!graph.nodes[fi].hasOutput) errors.add('"${graph.nodes[fi].label}" 不能作为连线起点');
      if (!graph.nodes[ti].hasInput) errors.add('"${graph.nodes[ti].label}" 不能作为连线终点');
    }

    final visited = <String>{};
    bool hasCycle(String nodeId, Set<String> path) {
      if (path.contains(nodeId)) return true;
      if (visited.contains(nodeId)) return false;
      path.add(nodeId);
      for (final c in graph.connections.where((c) => c.fromNodeId == nodeId)) {
        if (hasCycle(c.toNodeId, path)) return true;
      }
      path.remove(nodeId);
      visited.add(nodeId);
      return false;
    }
    for (final n in graph.nodes) {
      if (hasCycle(n.id, <String>{})) {
        errors.add('存在循环连线');
        break;
      }
    }

    if (errors.isNotEmpty) return errors;

    for (final start in startNodes) {
      final plan = _buildPlan(graph, start);
      if (plan == null) {
        errors.add('源文件节点未连接到输出节点');
        continue;
      }
      bool afterFrame = false;
      double? clipCeiling;
      for (var si = 0; si < plan.steps.length; si++) {
        final step = plan.steps[si];
        final types = step.nodes.map((n) => n.type).toSet();
        final hasMergeable = types.contains(PipelineStepType.avProcess) || types.contains(PipelineStepType.subtitle) || types.contains(PipelineStepType.speed);
        final hasSequential = types.contains(PipelineStepType.clip) || types.contains(PipelineStepType.frame);
        if (hasMergeable && hasSequential) {
          final names = step.nodes.map((n) => n.label).join(', ');
          errors.add('同层级节点冲突: $names (音视频处理/字幕 不能与 片段截取/帧提取 在同一层级)');
        }
        if (types.contains(PipelineStepType.clip) && types.contains(PipelineStepType.frame)) {
          errors.add('同层级节点冲突: 片段截取 和 帧提取 不能在同一层级');
        }
        if (types.contains(PipelineStepType.clip) && types.length > 1) {
          errors.add('片段截取 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.frame) && types.length > 1) {
          errors.add('帧提取 不能与其他操作并行');
        }

        if (afterFrame && types.any((t) => t != PipelineStepType.output)) {
          errors.add('帧提取后不能连接视频处理节点（帧提取输出为图片）');
        }

        if (types.contains(PipelineStepType.frame)) {
          afterFrame = true;
        }

        if (types.contains(PipelineStepType.clip)) {
          final clipNode = step.nodes.firstWhere((n) => n.type == PipelineStepType.clip);
          final st = (clipNode.params['start_time'] as num?)?.toDouble() ?? 0;
          final et = (clipNode.params['end_time'] as num?)?.toDouble();
          if (clipCeiling != null) {
            final duration = clipCeiling;
            if (st > duration) {
              errors.add('片段截取起始时间 ${st}s 超出上游截取范围 ${duration}s');
            }
            if (et != null && et > duration) {
              errors.add('片段截取结束时间 ${et}s 超出上游截取范围 ${duration}s');
            }
          }
          if (et != null && st < et) {
            clipCeiling = et - st;
          }
        }
      }
    }

    return errors;
  }

  // ── 构建执行计划 ──

  static ExecutionPlan? _buildPlan(PipelineGraph graph, PipelineNode start) {
    final reachable = <String>{};
    void collectReachable(String id) {
      if (reachable.contains(id)) return;
      reachable.add(id);
      for (final c in graph.connections.where((c) => c.fromNodeId == id)) {
        collectReachable(c.toNodeId);
      }
    }
    collectReachable(start.id);

    final subNodes = graph.nodes.where((n) => reachable.contains(n.id)).toList();
    final subConns = graph.connections.where((c) => reachable.contains(c.fromNodeId) && reachable.contains(c.toNodeId)).toList();

    final inDegree = <String, int>{};
    for (final n in subNodes) { inDegree[n.id] = 0; }
    for (final c in subConns) { inDegree[c.toNodeId] = (inDegree[c.toNodeId] ?? 0) + 1; }

    final levels = <List<PipelineNode>>[];
    var queue = subNodes.where((n) => inDegree[n.id] == 0).toList();

    while (queue.isNotEmpty) {
      levels.add(List.of(queue));
      final nextQueue = <PipelineNode>[];
      for (final n in queue) {
        for (final c in subConns.where((c) => c.fromNodeId == n.id)) {
          inDegree[c.toNodeId] = (inDegree[c.toNodeId] ?? 1) - 1;
          if (inDegree[c.toNodeId] == 0) {
            final target = subNodes.firstWhere((sn) => sn.id == c.toNodeId);
            if (!nextQueue.any((q) => q.id == target.id)) nextQueue.add(target);
          }
        }
      }
      queue = nextQueue;
    }

    PipelineNode? outputNode;
    final steps = <ExecutionStep>[];
    for (final level in levels) {
      final processing = level.where((n) =>
          n.type != PipelineStepType.start && n.type != PipelineStepType.output).toList();
      if (processing.isEmpty) {
        final out = level.where((n) => n.type == PipelineStepType.output);
        if (out.isNotEmpty) outputNode = out.first;
        continue;
      }
      final types = processing.map((n) => n.type).toSet();
      if (types.every((t) => t == PipelineStepType.avProcess || t == PipelineStepType.subtitle || t == PipelineStepType.speed)) {
        steps.add(ExecutionStep('merged', processing));
      } else {
        for (final n in processing) {
          steps.add(ExecutionStep(n.type == PipelineStepType.clip ? 'clip' : n.type == PipelineStepType.frame ? 'frame' : 'single', [n]));
        }
      }
    }

    if (outputNode == null) return null;
    return ExecutionPlan(startNode: start, steps: steps, outputNode: outputNode);
  }

  // ── 解析所有执行计划 ──

  static List<ExecutionPlan> resolvePlans(PipelineGraph graph) {
    final plans = <ExecutionPlan>[];
    for (final start in graph.nodes.where((n) => n.type == PipelineStepType.start)) {
      final plan = _buildPlan(graph, start);
      if (plan != null) plans.add(plan);
    }
    return plans;
  }

  // ── 将执行计划转为后端调用 ──

  static List<BackendCall> buildBackendCalls(
      ExecutionPlan plan, String inputPath, String outputPath) {
    final calls = <BackendCall>[];
    final tempFiles = <String>[];

    var currentInput = inputPath;

    for (var i = 0; i < plan.steps.length; i++) {
      final step = plan.steps[i];
      final isLast = i == plan.steps.length - 1;
      final currentOutput = isLast ? outputPath : _tempPath(inputPath, i);
      if (!isLast) tempFiles.add(currentOutput);

      switch (step.action) {
        case 'merged':
          final avNodes = step.nodes.where((n) => n.type == PipelineStepType.avProcess).toList();
          final subNodes = step.nodes.where((n) => n.type == PipelineStepType.subtitle).toList();
          final speedNodes = step.nodes.where((n) => n.type == PipelineStepType.speed).toList();

          final speedFilters = speedNodes.isNotEmpty ? _speedFilters(_effectiveSpeed(speedNodes.first.params)) : null;

          if (subNodes.isNotEmpty) {
            final avOpts = avNodes.isNotEmpty ? _avOptions(avNodes.first) : _defaultAvOptions();
            if (speedFilters != null) {
              avOpts['vf_filters'] = [speedFilters.$1];
              avOpts['af_filters'] = [speedFilters.$2];
            }
            calls.add(BackendCall(
              action: 'subtitle',
              params: {
                'input': currentInput,
                'output': currentOutput,
                'subtitle_options': _subtitleOptions(subNodes.first),
                'video_options': avOpts,
              },
            ));
          } else if (avNodes.isNotEmpty) {
            final opts = _avOptions(avNodes.first);
            if (speedFilters != null) {
              opts['vf_filters'] = [speedFilters.$1];
              opts['af_filters'] = [speedFilters.$2];
            }
            calls.add(BackendCall(
              action: 'transcode',
              params: {'input': currentInput, 'output': currentOutput, 'options': opts},
            ));
          } else if (speedNodes.isNotEmpty) {
            final opts = _defaultAvOptions();
            opts['vf_filters'] = [speedFilters!.$1];
            opts['af_filters'] = [speedFilters.$2];
            calls.add(BackendCall(
              action: 'transcode',
              params: {'input': currentInput, 'output': currentOutput, 'options': opts},
            ));
          }
          break;

        case 'clip':
          final node = step.nodes.first;
          final opts = <String, dynamic>{
            'video_codec': 'copy', 'audio_codec': 'copy', 'overwrite': true,
          };
          final p = node.params;
          if (p['start_time'] != null) opts['start_time'] = (p['start_time'] as num).toDouble();
          if (p['end_time'] != null) opts['end_time'] = (p['end_time'] as num).toDouble();
          calls.add(BackendCall(
            action: 'transcode',
            params: {'input': currentInput, 'output': currentOutput, 'options': opts},
          ));
          break;

        case 'frame':
          final node = step.nodes.first;
          final p = node.params;
          final fmt = p['output_format'] as String? ?? 'png';
          final mode = p['extract_mode'] as String? ?? 'single';
          final baseName = outputPath.replaceAll(RegExp(r'\.[^.]+$'), '');

          if (mode == 'single') {
            final time = (p['time'] as num?)?.toDouble() ?? 0;
            calls.add(BackendCall(
              action: 'extract_frame',
              params: {'input': currentInput, 'output': '${baseName}_frame.$fmt', 'time': time},
            ));
          } else if (mode == 'range') {
            final rs = (p['range_start'] as num?)?.toDouble() ?? 0;
            final re = (p['range_end'] as num?)?.toDouble() ?? 0;
            final fps = (p['fps_rate'] as num?)?.toDouble() ?? 1.0;
            calls.add(BackendCall(
              action: 'extract_frames_range',
              params: {
                'input': currentInput, 'output_dir': '${baseName}_frames',
                'start_time': rs, 'end_time': re, 'fps': fps, 'format': fmt,
              },
            ));
          } else {
            final fps = (p['fps_rate'] as num?)?.toDouble() ?? 1.0;
            calls.add(BackendCall(
              action: 'extract_frames_all',
              params: {
                'input': currentInput, 'output_dir': '${baseName}_frames',
                'fps': fps, 'format': fmt,
              },
            ));
          }
          break;

        case 'single':
          final node = step.nodes.first;
          if (node.type == PipelineStepType.avProcess) {
            calls.add(BackendCall(
              action: 'transcode',
              params: {'input': currentInput, 'output': currentOutput, 'options': _avOptions(node)},
            ));
          } else if (node.type == PipelineStepType.subtitle) {
            calls.add(BackendCall(
              action: 'subtitle',
              params: {
                'input': currentInput, 'output': currentOutput,
                'subtitle_options': _subtitleOptions(node),
                'video_options': _defaultAvOptions(),
              },
            ));
          } else if (node.type == PipelineStepType.speed) {
            final sf = _speedFilters(_effectiveSpeed(node.params));
            final opts = _defaultAvOptions();
            opts['vf_filters'] = [sf.$1];
            opts['af_filters'] = [sf.$2];
            calls.add(BackendCall(
              action: 'transcode',
              params: {'input': currentInput, 'output': currentOutput, 'options': opts},
            ));
          }
          break;
      }
      currentInput = currentOutput;
    }

    for (final tf in tempFiles) {
      calls.add(BackendCall(action: '_cleanup', params: {'path': tf}));
    }
    return calls;
  }

  // ── 输出路径 ──

  static String resolveOutputPath(ExecutionPlan plan, VideoFile video, AppConfig config) {
    final p = plan.outputNode?.params ?? {};
    final format = p['format'] as String? ?? 'keep';
    final namingMode = p['naming_mode'] as String? ?? 'keep';
    final namingValue = p['naming_value'] as String? ?? '_processed';
    final outputDir = p['output_dir'] as String?;

    final ext = format == 'keep' ? video.filepath.split('.').last : format;
    final base = video.filename.replaceAll(RegExp(r'\.[^.]+$'), '');
    final fn = namingMode == 'keep' ? '$base.$ext'
        : namingMode == 'suffix' ? '$base$namingValue.$ext'
        : '$namingValue.$ext';

    var dir = (outputDir != null && outputDir.isNotEmpty) ? outputDir
        : config.defaultOutputDir.isNotEmpty ? config.defaultOutputDir
        : video.filepath.replaceAll(RegExp(r'[^\\/]+$'), '');
    if (!dir.endsWith('/') && !dir.endsWith('\\')) dir = '$dir${Platform.pathSeparator}';

    var out = '$dir$fn';
    if (out == video.filepath) out = '$dir${base}_processed.$ext';
    return out;
  }

  // ── 调试描述 ──

  static String describeGraph(PipelineGraph graph) {
    final lines = <String>[];
    final plans = resolvePlans(graph);

    if (plans.isEmpty) {
      if (graph.nodes.isEmpty) return '画布为空';
      lines.add('未解析到有效任务');
      final orphans = graph.nodes.where((n) {
        return !graph.connections.any((c) => c.toNodeId == n.id) &&
            !graph.connections.any((c) => c.fromNodeId == n.id) &&
            n.type != PipelineStepType.start;
      });
      if (orphans.isNotEmpty) lines.add('孤立节点: ${orphans.map((n) => n.label).join(', ')}');
      return lines.join('\n');
    }

    final startCount = graph.nodes.where((n) => n.type == PipelineStepType.start).length;
    lines.add('$startCount 个源文件节点 → ${plans.length} 个独立任务');

    for (var i = 0; i < plans.length; i++) {
      final plan = plans[i];
      lines.add('');
      lines.add('任务${i + 1}: ${plan.steps.length} 步');

      for (var si = 0; si < plan.steps.length; si++) {
        final step = plan.steps[si];
        final descs = <String>[];
        for (final n in step.nodes) {
          switch (n.type) {
            case PipelineStepType.avProcess:
              final p = n.params;
              descs.add('编码(${p['video_codec'] ?? 'h264'}/${p['gpu'] ?? 'CPU'}, ${p['resolution'] ?? '原始'})');
              break;
            case PipelineStepType.subtitle:
              descs.add('字幕烧录(${n.params['source'] ?? 'external'})');
              break;
            case PipelineStepType.clip:
              descs.add('截取(${n.params['start_time'] ?? 0}s-${n.params['end_time'] ?? '?'}s)');
              break;
            case PipelineStepType.frame:
              final fm = n.params['extract_mode'] as String? ?? 'single';
              if (fm == 'single') descs.add('提取帧(${n.params['time'] ?? 0}s)');
              else if (fm == 'range') descs.add('范围分帧(${n.params['range_start'] ?? 0}s-${n.params['range_end'] ?? '?'}s @${n.params['fps_rate'] ?? 1}fps)');
              else descs.add('全部分帧(@${n.params['fps_rate'] ?? 1}fps)');
              break;
            case PipelineStepType.speed:
              final sp = _effectiveSpeed(n.params);
              descs.add('变速(${sp}x)');
              break;
            default: break;
          }
        }
        final merged = step.action == 'merged' && step.nodes.length > 1;
        final prefix = merged ? '  ${si + 1}. [合并] ' : '  ${si + 1}. ';
        lines.add('$prefix${descs.join(' + ')}');
        if (merged) lines.add('     → 单条ffmpeg命令');
        if (si < plan.steps.length - 1) lines.add('     → 中间文件传递');
      }
      lines.add('  → 输出');
    }

    lines.add('');
    lines.add('节点: ${graph.nodes.length}  连线: ${graph.connections.length}');
    return lines.join('\n');
  }

  // ── 参数转译 ──

  static Map<String, dynamic> _avOptions(PipelineNode node) {
    final p = node.params;
    final opts = <String, dynamic>{
      'video_codec': p['video_codec'] ?? 'h264',
      'gpu': p['gpu'] ?? 'CPU',
      'preset': p['preset'] ?? 'medium',
      'audio_codec': p['audio_codec'] ?? 'aac',
      'overwrite': true,
    };
    final rateMode = p['rate_mode'] as String? ?? 'keep';
    if (rateMode == 'crf' && p['crf'] != null) opts['crf'] = p['crf'];
    else if (rateMode == 'bitrate' && p['video_bitrate'] != null) opts['video_bitrate'] = p['video_bitrate'];

    switch (p['resolution'] as String? ?? 'original') {
      case '2160p': opts['resolution'] = [3840, 2160]; break;
      case '1080p': opts['resolution'] = [1920, 1080]; break;
      case '720p': opts['resolution'] = [1280, 720]; break;
      case '480p': opts['resolution'] = [854, 480]; break;
      case 'custom':
        if (p['resolution_w'] != null && p['resolution_h'] != null) opts['resolution'] = [p['resolution_w'], p['resolution_h']];
        break;
    }
    final fps = p['fps'] as String? ?? 'keep';
    if (fps == 'custom' && p['fps_value'] != null) opts['framerate'] = (p['fps_value'] as num).toDouble();
    else if (fps != 'keep') opts['framerate'] = double.tryParse(fps);
    if (p['audio_bitrate'] != null) opts['audio_bitrate'] = p['audio_bitrate'];
    final ch = p['audio_channels'] as String? ?? 'keep';
    if (ch != 'keep') opts['audio_channels'] = int.tryParse(ch);
    return opts;
  }

  static Map<String, dynamic> _defaultAvOptions() => {
    'video_codec': 'h264', 'gpu': 'CPU', 'preset': 'medium',
    'audio_codec': 'aac', 'overwrite': true,
  };

  static double _effectiveSpeed(Map<String, dynamic> params) {
    final isCustom = params['custom_speed'] as bool? ?? false;
    if (isCustom) {
      return (params['custom_speed_value'] as num?)?.toDouble() ?? 10.0;
    }
    return (params['speed'] as num?)?.toDouble() ?? 1.0;
  }

  static (String, String) _speedFilters(double speed) {
    final ptsFactor = (1.0 / speed).toStringAsFixed(6);
    final vf = 'setpts=$ptsFactor*PTS';

    final afParts = <String>[];
    var remaining = speed;
    while (remaining > 2.0) {
      afParts.add('atempo=2.0');
      remaining /= 2.0;
    }
    while (remaining < 0.5) {
      afParts.add('atempo=0.5');
      remaining /= 0.5;
    }
    afParts.add('atempo=${remaining.toStringAsFixed(6)}');
    return (vf, afParts.join(','));
  }

  static Map<String, dynamic> _subtitleOptions(PipelineNode node) {
    final p = node.params;
    return {
      'source': p['source'] ?? 'external',
      if (p['subtitle_file'] != null) 'subtitle_file': p['subtitle_file'],
      'subtitle_index': p['subtitle_index'] ?? 0,
      'style': {
        'font_name': p['font_name'] ?? 'Arial',
        'font_size': p['font_size'] ?? 24,
        'font_color': p['font_color'] ?? '#FFFFFF',
        'outline_width': p['outline_width'] ?? 2,
        'outline_color': p['outline_color'] ?? '#000000',
      },
    };
  }

  static String _tempPath(String inputPath, int step) {
    final dir = Directory.systemTemp.path;
    final base = inputPath.split('\\').last.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
    return '$dir${Platform.pathSeparator}ffmpegpp_${base}_step$step.mp4';
  }
}
