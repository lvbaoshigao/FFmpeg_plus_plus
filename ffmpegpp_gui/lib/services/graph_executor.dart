import 'dart:io';
import '../models/models.dart';

class ExecutionStep {
  final String action;
  final List<PipelineNode> nodes;
  int loopCount;
  String? loopMode;
  String? innerAction;
  ExecutionStep(this.action, this.nodes, {this.loopCount = 1, this.loopMode, this.innerAction});
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

    // 媒体类型兼容校验
    for (final conn in graph.connections) {
      final fi = graph.nodes.indexWhere((n) => n.id == conn.fromNodeId);
      final ti = graph.nodes.indexWhere((n) => n.id == conn.toNodeId);
      if (fi < 0 || ti < 0) continue;
      final from = graph.nodes[fi];
      final to = graph.nodes[ti];
      final outType = from.outputType;
      final inTypes = to.inputTypes;
      if (outType != null && inTypes.isNotEmpty && !inTypes.contains(outType)) {
        errors.add('"${from.label}" 输出 ${outType.name}，无法连接到 "${to.label}"（需要 ${inTypes.map((t) => t.name).join("/")}）');
      }
    }

    if (errors.isNotEmpty) return errors;

    // Logic block validation
    for (final block in graph.logicBlocks) {
      for (final childId in block.childNodeIds) {
        if (!graph.nodes.any((n) => n.id == childId)) {
          errors.add('逻辑块引用了不存在的节点');
        }
      }
      // Check node not in multiple blocks
      for (final otherBlock in graph.logicBlocks) {
        if (otherBlock.id == block.id) continue;
        for (final childId in block.childNodeIds) {
          if (otherBlock.childNodeIds.contains(childId)) {
            errors.add('节点不能同时属于多个逻辑块');
          }
        }
      }
      // Check no start/output nodes inside blocks
      for (final childId in block.childNodeIds) {
        final node = graph.nodes.firstWhere((n) => n.id == childId, orElse: () => PipelineNode(id: '', type: PipelineStepType.start));
        if (node.type == PipelineStepType.start || node.type == PipelineStepType.output) {
          errors.add('逻辑块内不能包含源文件或输出节点');
        }
      }
    }

    if (errors.isNotEmpty) return errors;

    for (final start in startNodes) {
      final plan = _buildPlan(graph, start);
      if (plan == null) {
        errors.add('源文件节点未连接到输出节点');
        continue;
      }
      double? clipCeiling;
      for (var si = 0; si < plan.steps.length; si++) {
        final step = plan.steps[si];
        final types = step.nodes.map((n) => n.type).toSet();
        final hasMergeable = types.contains(PipelineStepType.avProcess) || types.contains(PipelineStepType.subtitle) || types.contains(PipelineStepType.speed);
        final hasSequential = types.contains(PipelineStepType.clip) || types.contains(PipelineStepType.frame)
            || types.contains(PipelineStepType.imageConvert) || types.contains(PipelineStepType.audioConvert)
            || types.contains(PipelineStepType.extractAudio) || types.contains(PipelineStepType.imageCrop)
            || types.contains(PipelineStepType.imageRotate) || types.contains(PipelineStepType.imageScale)
            || types.contains(PipelineStepType.imageBrightness) || types.contains(PipelineStepType.imageNoise)
            || types.contains(PipelineStepType.imageSharpen) || types.contains(PipelineStepType.imageDenoise)
            || types.contains(PipelineStepType.imageChannelExtract);
        if (hasMergeable && hasSequential) {
          final names = step.nodes.map((n) => n.label).join(', ');
          errors.add('同层级节点冲突: $names (合并节点不能与独立节点在同一层级)');
        }
        if (types.contains(PipelineStepType.clip) && types.length > 1) {
          errors.add('片段截取 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.frame) && types.length > 1) {
          errors.add('帧提取 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageConvert) && types.length > 1) {
          errors.add('图片转换 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageCrop) && types.length > 1) {
          errors.add('图片裁剪 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.audioConvert) && types.length > 1) {
          errors.add('音频转换 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.extractAudio) && types.length > 1) {
          errors.add('提取音频 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageRotate) && types.length > 1) {
          errors.add('图片旋转 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageScale) && types.length > 1) {
          errors.add('图片缩放 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageBrightness) && types.length > 1) {
          errors.add('图片亮度 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageNoise) && types.length > 1) {
          errors.add('图片噪声 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageSharpen) && types.length > 1) {
          errors.add('图片锐化 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageDenoise) && types.length > 1) {
          errors.add('图片降噪 不能与其他操作并行');
        }
        if (types.contains(PipelineStepType.imageChannelExtract) && types.length > 1) {
          errors.add('通道提取 不能与其他操作并行');
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
          final action = switch (n.type) {
            PipelineStepType.clip => 'clip',
            PipelineStepType.frame => 'frame',
            PipelineStepType.imageConvert => 'image_convert',
            PipelineStepType.audioConvert => 'audio_convert',
            PipelineStepType.extractAudio => 'extract_audio',
            PipelineStepType.imageCrop => 'image_crop',
            PipelineStepType.imageRotate => 'image_rotate',
            PipelineStepType.imageScale => 'image_scale',
            PipelineStepType.imageBrightness => 'image_brightness',
            PipelineStepType.imageNoise => 'image_noise',
            PipelineStepType.imageSharpen => 'image_sharpen',
            PipelineStepType.imageDenoise => 'image_denoise',
            PipelineStepType.imageChannelExtract => 'image_channel_extract',
            _ => 'single',
          };
          steps.add(ExecutionStep(action, [n]));
        }
      }
    }

    if (outputNode == null) return null;

    // Tag steps that belong to logic blocks with loop metadata
    for (final step in steps) {
      final firstNode = step.nodes.first;
      final block = graph.logicBlocks.where((b) => b.childNodeIds.contains(firstNode.id)).firstOrNull;
      if (block != null) {
        step.loopCount = block.params['count'] as int? ?? 1;
        step.loopMode = block.params['mode'] as String? ?? 'all';
        step.innerAction = step.action;
      }
    }

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
    final stepCallRanges = <(int, int, ExecutionStep)>[];

    var currentInput = inputPath;

    for (var i = 0; i < plan.steps.length; i++) {
      final step = plan.steps[i];
      final isLast = i == plan.steps.length - 1;
      final inputExt = currentInput.split('.').last;
      final currentOutput = isLast ? outputPath : _tempPath(inputPath, i, inputExt);
      if (!isLast) tempFiles.add(currentOutput);

      final callsBeforeStep = calls.length;

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

        case 'image_convert':
          final node = step.nodes.first;
          final outFmt = node.params['output_format'] as String? ?? 'png';
          final quality = (node.params['quality'] as num?)?.toInt() ?? 95;
          final outPath = isLast
              ? outputPath.replaceAll(RegExp(r'\.[^.]+$'), '.$outFmt')
              : _tempPath(inputPath, i, outFmt);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_convert',
            params: {'input': currentInput, 'output': outPath, 'quality': quality},
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'image_crop':
          final node = step.nodes.first;
          final cp = node.params;
          final cropX = (cp['crop_x'] as num?)?.toInt() ?? 0;
          final cropY = (cp['crop_y'] as num?)?.toInt() ?? 0;
          final cropW = (cp['crop_w'] as num?)?.toInt() ?? 0;
          final cropH = (cp['crop_h'] as num?)?.toInt() ?? 0;
          final ext = currentInput.split('.').last;
          final outPath = isLast
              ? outputPath
              : _tempPath(inputPath, i, ext);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_crop',
            params: {
              'input': currentInput,
              'output': outPath,
              'crop_x': cropX,
              'crop_y': cropY,
              'crop_w': cropW,
              'crop_h': cropH,
            },
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'image_rotate':
          final node = step.nodes.first;
          final p = node.params;
          final ext = currentInput.split('.').last;
          final outPath = isLast
              ? outputPath
              : _tempPath(inputPath, i, ext);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_rotate',
            params: {
              'input': currentInput,
              'output': outPath,
              if (p['angle'] != null) 'angle': p['angle'],
              if (p['rotate_mode'] != null) 'rotate_mode': p['rotate_mode'],
              if (p['random_min'] != null) 'random_min': p['random_min'],
              if (p['random_max'] != null) 'random_max': p['random_max'],
            },
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'image_scale':
          final node = step.nodes.first;
          final p = node.params;
          final ext = currentInput.split('.').last;
          final outPath = isLast
              ? outputPath
              : _tempPath(inputPath, i, ext);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_scale',
            params: {
              'input': currentInput,
              'output': outPath,
              if (p['scale_factor'] != null) 'scale_factor': p['scale_factor'],
              if (p['scale_mode'] != null) 'scale_mode': p['scale_mode'],
              if (p['random_min'] != null) 'random_min': p['random_min'],
              if (p['random_max'] != null) 'random_max': p['random_max'],
            },
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'image_brightness':
          final node = step.nodes.first;
          final p = node.params;
          final ext = currentInput.split('.').last;
          final outPath = isLast
              ? outputPath
              : _tempPath(inputPath, i, ext);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_brightness',
            params: {
              'input': currentInput,
              'output': outPath,
              if (p['brightness'] != null) 'brightness': p['brightness'],
              if (p['brightness_mode'] != null) 'brightness_mode': p['brightness_mode'],
              if (p['range_min'] != null) 'range_min': p['range_min'],
              if (p['range_max'] != null) 'range_max': p['range_max'],
            },
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'image_noise':
          final node = step.nodes.first;
          final p = node.params;
          final ext = currentInput.split('.').last;
          final outPath = isLast
              ? outputPath
              : _tempPath(inputPath, i, ext);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_noise',
            params: {
              'input': currentInput,
              'output': outPath,
              if (p['noise_strength'] != null) 'noise_strength': p['noise_strength'],
              if (p['noise_type'] != null) 'noise_type': p['noise_type'],
              if (p['noise_mode'] != null) 'noise_mode': p['noise_mode'],
              if (p['random_min'] != null) 'random_min': p['random_min'],
              if (p['random_max'] != null) 'random_max': p['random_max'],
            },
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'image_sharpen':
          final node = step.nodes.first;
          final p = node.params;
          final ext = currentInput.split('.').last;
          final outPath = isLast
              ? outputPath
              : _tempPath(inputPath, i, ext);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_sharpen',
            params: {
              'input': currentInput,
              'output': outPath,
              if (p['sharpen_strength'] != null) 'sharpen_strength': p['sharpen_strength'],
              if (p['sharpen_mode'] != null) 'sharpen_mode': p['sharpen_mode'],
              if (p['random_min'] != null) 'random_min': p['random_min'],
              if (p['random_max'] != null) 'random_max': p['random_max'],
            },
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'image_denoise':
          final node = step.nodes.first;
          final p = node.params;
          final ext = currentInput.split('.').last;
          final outPath = isLast
              ? outputPath
              : _tempPath(inputPath, i, ext);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_denoise',
            params: {
              'input': currentInput,
              'output': outPath,
              if (p['denoise_method'] != null) 'denoise_method': p['denoise_method'],
              if (p['denoise_strength'] != null) 'denoise_strength': p['denoise_strength'],
              if (p['denoise_mode'] != null) 'denoise_mode': p['denoise_mode'],
              if (p['random_min'] != null) 'random_min': p['random_min'],
              if (p['random_max'] != null) 'random_max': p['random_max'],
            },
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'image_channel_extract':
          final node = step.nodes.first;
          final p = node.params;
          final ext = currentInput.split('.').last;
          final outPath = isLast
              ? outputPath
              : _tempPath(inputPath, i, ext);
          if (!isLast) tempFiles.add(outPath);
          calls.add(BackendCall(
            action: 'image_channel_extract',
            params: {
              'input': currentInput,
              'output': outPath,
              if (p['channel'] != null) 'channel': p['channel'],
              if (p['extract_method'] != null) 'extract_method': p['extract_method'],
            },
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'extract_audio':
          final node = step.nodes.first;
          final p = node.params;
          final rawCodec = p['audio_codec'] as String? ?? 'copy';
          final rawFmt = p['output_format'] as String? ?? 'm4a';
          final (codec, outFmt) = _resolveAudioCodecFormat(rawCodec, rawFmt);
          final bitrate = (p['audio_bitrate'] as num?)?.toInt() ?? 128;
          final outPath = isLast
              ? outputPath.replaceAll(RegExp(r'\.[^.]+$'), '.$outFmt')
              : _tempPath(inputPath, i, outFmt);
          if (!isLast) tempFiles.add(outPath);
          final opts = <String, dynamic>{
            'video_codec': 'none',
            'audio_codec': codec,
            'overwrite': true,
          };
          if (codec != 'copy' && codec != 'flac' && codec != 'pcm_s16le') {
            opts['audio_bitrate'] = bitrate;
          }
          calls.add(BackendCall(
            action: 'transcode',
            params: {'input': currentInput, 'output': outPath, 'options': opts},
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;

        case 'audio_convert':
          final node = step.nodes.first;
          final p = node.params;
          final rawCodec = p['audio_codec'] as String? ?? 'aac';
          final rawFmt = p['output_format'] as String? ?? 'm4a';
          final (codec, outFmt) = _resolveAudioCodecFormat(rawCodec, rawFmt);
          final sr = p['sample_rate'] as String? ?? 'keep';
          final outPath = isLast
              ? outputPath.replaceAll(RegExp(r'\.[^.]+$'), '.$outFmt')
              : _tempPath(inputPath, i, outFmt);
          if (!isLast) tempFiles.add(outPath);
          final opts = <String, dynamic>{
            'video_codec': 'none',
            'audio_codec': codec,
            'overwrite': true,
          };
          if (codec != 'flac' && codec != 'pcm_s16le') {
            final bitrateVal = p['audio_bitrate'];
            if (bitrateVal != null) {
              opts['audio_bitrate'] = (bitrateVal as num).toInt();
            }
          }
          if (sr != 'keep') opts['sample_rate'] = int.tryParse(sr);
          calls.add(BackendCall(
            action: 'transcode',
            params: {'input': currentInput, 'output': outPath, 'options': opts},
          ));
          stepCallRanges.add((callsBeforeStep, calls.length, step));
          currentInput = outPath;
          continue;
      }

      // Record the range of calls generated by this step
      stepCallRanges.add((callsBeforeStep, calls.length, step));

      currentInput = currentOutput;
    }

    // Tag calls generated by steps with loop metadata
    for (final (start, end, step) in stepCallRanges) {
      if (step.loopCount > 1) {
        for (var ci = start; ci < end; ci++) {
          calls[ci].loopCount = step.loopCount;
          calls[ci].loopMode = step.loopMode;
        }
      }
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

    // Determine extension: check if last processing step overrides the format
    String ext;
    if (format != 'keep') {
      ext = format;
    } else if (plan.steps.isNotEmpty) {
      final lastStep = plan.steps.last;
      final lastNode = lastStep.nodes.last;
      if (lastStep.action == 'extract_audio' || lastStep.action == 'audio_convert') {
        ext = lastNode.params['output_format'] as String? ?? 'm4a';
      } else if (lastStep.action == 'image_convert') {
        ext = lastNode.params['output_format'] as String? ?? 'png';
      } else {
        ext = video.filepath.split('.').last;
      }
    } else {
      ext = video.filepath.split('.').last;
    }

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
            case PipelineStepType.imageConvert:
              descs.add('图片转换(→${n.params['output_format'] ?? 'png'})');
              break;
            case PipelineStepType.imageCrop:
              descs.add('图片裁剪(${n.params['crop_w'] ?? '?'}x${n.params['crop_h'] ?? '?'})');
              break;
            case PipelineStepType.audioConvert:
              descs.add('音频转换(${n.params['audio_codec'] ?? 'aac'}→${n.params['output_format'] ?? 'm4a'})');
              break;
            case PipelineStepType.extractAudio:
              descs.add('提取音频(${n.params['audio_codec'] ?? 'copy'}→${n.params['output_format'] ?? 'm4a'})');
              break;
            case PipelineStepType.imageRotate:
              descs.add('图片旋转(${n.params['angle'] ?? '0'}°)');
              break;
            case PipelineStepType.imageScale:
              descs.add('图片缩放(${n.params['scale_factor'] ?? '1.0'}x)');
              break;
            case PipelineStepType.imageBrightness:
              descs.add('图片亮度(${n.params['brightness'] ?? '0'})');
              break;
            case PipelineStepType.imageNoise:
              descs.add('图片噪声(${n.params['noise_strength'] ?? '0'})');
              break;
            case PipelineStepType.imageSharpen:
              descs.add('图片锐化(${n.params['sharpen_strength'] ?? '0'})');
              break;
            case PipelineStepType.imageDenoise:
              descs.add('图片降噪(${n.params['denoise_method'] ?? 'default'})');
              break;
            case PipelineStepType.imageChannelExtract:
              descs.add('通道提取(${n.params['channel'] ?? 'R'})');
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

  static const _codecForFormat = {
    'mp3': 'libmp3lame', 'ogg': 'libvorbis', 'flac': 'flac',
    'wav': 'pcm_s16le', 'aac': 'aac', 'm4a': 'aac', 'opus': 'libopus',
  };
  static const _copyCompatFormats = {
    'aac': {'m4a', 'aac', 'mp4', 'mkv', 'mov'},
    'mp3': {'mp3'},
    'flac': {'flac'},
    'opus': {'ogg', 'mkv', 'webm'},
    'vorbis': {'ogg', 'mkv', 'webm'},
    'pcm_s16le': {'wav'},
  };

  static (String codec, String format) _resolveAudioCodecFormat(String codec, String format) {
    if (codec != 'copy') return (codec, format);
    // copy 模式：检查格式兼容性，不兼容时自动选编码器
    final compatFormats = _copyCompatFormats.entries
        .where((e) => e.value.contains(format))
        .map((e) => e.key).toSet();
    if (compatFormats.isNotEmpty) return ('copy', format);
    // 格式不兼容 copy，自动选对应编码器
    final resolved = _codecForFormat[format] ?? 'aac';
    return (resolved, format);
  }

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

  static String _tempPath(String inputPath, int step, [String ext = 'mp4']) {
    final dir = Directory.systemTemp.path;
    final base = inputPath.split('\\').last.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
    final pathHash = inputPath.hashCode.toRadixString(16).substring(0, 8);
    return '$dir${Platform.pathSeparator}ffmpegpp_${pathHash}_${base}_step$step.$ext';
  }
}
