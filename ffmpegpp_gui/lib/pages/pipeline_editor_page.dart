import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/graph_executor.dart';
import '../theme/app_strings.dart';
import '../services/config_export.dart';
import '../widgets/step_editors/start_step_editor.dart';
import '../widgets/step_editors/av_process_step_editor.dart';
import '../widgets/step_editors/subtitle_step_editor.dart';
import '../widgets/step_editors/output_step_editor.dart';
import '../widgets/step_editors/clip_step_editor.dart';
import '../widgets/step_editors/frame_step_editor.dart';
import '../widgets/step_editors/speed_step_editor.dart';
import '../widgets/step_editors/image_convert_step_editor.dart';
import '../widgets/step_editors/audio_convert_step_editor.dart';
import '../widgets/step_editors/audio_quality_step_editor.dart';
import '../widgets/step_editors/audio_speed_step_editor.dart';
import '../widgets/step_editors/audio_volume_step_editor.dart';
import '../widgets/step_editors/audio_compressor_step_editor.dart';
import '../widgets/step_editors/audio_metadata_step_editor.dart';
import '../widgets/step_editors/concat_media_step_editor.dart';
import '../widgets/step_editors/image_to_video_step_editor.dart';
import '../widgets/step_editors/image_crop_step_editor.dart';
import '../widgets/step_editors/image_rotate_step_editor.dart';
import '../widgets/step_editors/image_scale_step_editor.dart';
import '../widgets/step_editors/image_brightness_step_editor.dart';
import '../widgets/step_editors/image_noise_step_editor.dart';
import '../widgets/step_editors/image_sharpen_step_editor.dart';
import '../widgets/step_editors/image_denoise_step_editor.dart';
import '../widgets/step_editors/image_channel_extract_step_editor.dart';
import '../widgets/step_editors/logic_block_editor.dart';
import '../widgets/toast.dart';

const _uuid = Uuid();

const _nodeW = 200.0;
const _nodeWNarrow = 150.0;
const _nodeH = 68.0;
const _canvasSize = 6000.0;
const _portZoneW = 18.0;

double _nodeWFor(PipelineStepType type) =>
    (type == PipelineStepType.start || type == PipelineStepType.output) ? _nodeWNarrow : _nodeW;
double _totalNodeWFor(PipelineStepType type) => _portZoneW + _nodeWFor(type) + _portZoneW;

class PipelineEditorPage extends StatefulWidget {
  final VideoFile video;
  final void Function(PipelineGraph graph) onSave;
  final PipelineGraph? initialGraph;
  final ({String name, int fileCount, Map<MediaType, int> typeCounts, List<String> fileIds})? containerInfo;
  const PipelineEditorPage({super.key, required this.video, required this.onSave, this.initialGraph, this.containerInfo});
  @override
  State<PipelineEditorPage> createState() => _PipelineEditorPageState();
}

class _PipelineEditorPageState extends State<PipelineEditorPage> with WindowListener {
  final List<PipelineNode> _nodes = [];
  final List<PipelineConnection> _connections = [];
  Set<String> _selectedNodeIds = {};
  String? _lastSelectedId;

  String? _dragFromNodeId;
  bool _dragIsOutput = true;
  Offset? _dragLineEnd;

  // Box-select state
  Offset? _boxSelectStart;
  Rect? _boxSelectRect;
  bool _isBoxSelecting = false;

  // Right-click drag-to-pan state
  Offset? _rightClickStart;
  Offset? _rightClickGlobal;
  bool _isRightDragging = false;

  String? _thumbPath;
  bool _isAudioNoCover = false;
  bool _toolboxExpanded = true;
  bool _editorExpanded = true;
  double _toolboxFraction = 0.4;

  final TransformationController _transformCtrl = TransformationController();
  final GlobalKey _canvasKey = GlobalKey();
  late final AppState _appState;
  double _currentScale = 1.0;
  int _sourceAnchorIndex = 0;
  bool _isMaximized = false;
  PipelineStepType? _previewedToolboxType;
  LogicBlockType? _previewedLogicType;
  final List<LogicBlock> _logicBlocks = [];
  bool _isLogicBoxSelecting = false;
  LogicBlockType? _pendingLogicType;
  String? _selectedLogicBlockId;

  // Undo/redo
  final List<Map<String, dynamic>> _undoStack = [];
  final List<Map<String, dynamic>> _redoStack = [];

  Map<String, dynamic> _snapshot() => PipelineGraph(nodes: List.of(_nodes), connections: List.of(_connections), logicBlocks: List.of(_logicBlocks)).toJson();
  void _pushUndo() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > 50) _undoStack.removeAt(0);
    _redoStack.clear();
  }
  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    _restoreSnapshot(_undoStack.removeLast());
  }
  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    _restoreSnapshot(_redoStack.removeLast());
  }
  void _restoreSnapshot(Map<String, dynamic> snap) {
    final g = PipelineGraph.fromJson(snap);
    setState(() {
      _nodes.clear(); _nodes.addAll(g.nodes);
      _connections.clear(); _connections.addAll(g.connections);
      _logicBlocks.clear(); _logicBlocks.addAll(g.logicBlocks);
      _selectedNodeIds.clear();
    });
  }

  void _saveGraph() {
    final graph = PipelineGraph(nodes: _nodes, connections: _connections, logicBlocks: _logicBlocks);
    widget.onSave(graph);
    context.read<AppState>().setCurrentPipeline(graph);
  }

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) {
      windowManager.addListener(this);
      windowManager.isMaximized().then((v) {
        if (mounted) setState(() => _isMaximized = v);
      });
    }
    final g = widget.initialGraph ?? widget.video.pipelineGraph;
    final isConfigMode = widget.video.filepath.isEmpty;
    if (g.nodes.isNotEmpty) {
      final copied = g.copy();
      _nodes.addAll(copied.nodes);
      _connections.addAll(copied.connections);
      _logicBlocks.addAll(copied.logicBlocks);
    } else {
      final cx = _canvasSize / 2;
      final cy = _canvasSize / 2;
      final startNode = PipelineNode(
        id: _uuid.v4(), type: PipelineStepType.start,
        x: cx - 100, y: cy,
        params: isConfigMode ? {} : {'file_media_type': widget.video.fileMediaType.name},
      );
      final outputNode = PipelineNode(
        id: _uuid.v4(), type: PipelineStepType.output,
        x: cx + 200, y: cy,
      );
      _nodes.addAll([startNode, outputNode]);
      _connections.add(PipelineConnection(
        id: _uuid.v4(), fromNodeId: startNode.id, toNodeId: outputNode.id,
      ));
    }
    if (!isConfigMode) {
      for (final n in _nodes) {
        if (n.type == PipelineStepType.start) {
          n.params['file_media_type'] = widget.video.fileMediaType.name;
        }
      }
    }
    _genThumb();
    _transformCtrl.addListener(_onScaleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _transformCtrl.value = Matrix4.identity()..translate(-_canvasSize / 2 + 300, -_canvasSize / 2 + 200);
    });
    _appState = context.read<AppState>();
    _appState.mcpOnClearAll = () { _pushUndo(); setState(() { _nodes.clear(); _connections.clear(); _logicBlocks.clear(); _selectedNodeIds.clear(); _saveGraph(); }); };
    _appState.mcpOnUndo = _undo;
    _appState.mcpOnRedo = _redo;
    _appState.mcpOnSave = _saveGraph;
    _appState.mcpOnModifyNode = (nodeId, params) {
      _pushUndo();
      setState(() {
        final node = _nodes.firstWhere((n) => n.id == nodeId, orElse: () => _nodes.first);
        params.forEach((k, v) { node.params[k] = v; });
      });
      _saveGraph();
    };
  }

  @override
  void dispose() {
    if (!Platform.isWindows) windowManager.removeListener(this);
    _transformCtrl.removeListener(_onScaleChanged);
    _transformCtrl.dispose();
    _appState.mcpOnClearAll = null;
    _appState.mcpOnUndo = null;
    _appState.mcpOnRedo = null;
    _appState.mcpOnSave = null;
    _appState.mcpOnModifyNode = null;
    super.dispose();
  }

  void _onScaleChanged() {
    final s = _transformCtrl.value.getMaxScaleOnAxis();
    if ((s - _currentScale).abs() > 0.01) {
      setState(() => _currentScale = s);
    }
  }

  @override
  void onWindowMaximize() { if (mounted) setState(() => _isMaximized = true); }
  @override
  void onWindowUnmaximize() { if (mounted) setState(() => _isMaximized = false); }

  Future<void> _genThumb() async {
    final fp = widget.video.filepath;
    final suffix = widget.video.fileMediaType == MediaType.audio ? '_cover' : '';
    final f = File('${Directory.systemTemp.path}/ffmpegpp_thumb_${fp.hashCode}$suffix.jpg');
    if (await f.exists()) { if (mounted) setState(() => _thumbPath = f.path); return; }
    try {
      final ext = fp.split('.').last.toLowerCase();
      final isImage = kImageExts.contains(ext);
      final isAudio = widget.video.fileMediaType == MediaType.audio;
      final args = <String>['-y'];
      if (!isImage && !isAudio) args.addAll(['-ss', '5']);
      if (isAudio) {
        args.addAll(['-i', fp, '-an', '-vframes', '1', '-q:v', '3', f.path]);
      } else {
        args.addAll(['-i', fp, '-vframes', '1', '-q:v', '3', '-s', '176x108', f.path]);
      }
      final r = await Process.run('ffmpeg', args);
      if (r.exitCode == 0 && await f.exists()) {
        if (mounted) setState(() { _thumbPath = f.path; _isAudioNoCover = false; });
      } else if (isAudio && mounted) {
        setState(() => _isAudioNoCover = true);
      }
    } catch (_) {
      if (widget.video.fileMediaType == MediaType.audio && mounted) {
        setState(() => _isAudioNoCover = true);
      }
    }
  }

  PipelineNode? get _selectedNode {
    if (_lastSelectedId == null) return null;
    final idx = _nodes.indexWhere((n) => n.id == _lastSelectedId);
    return idx >= 0 ? _nodes[idx] : null;
  }

  IconData _stepIcon(PipelineStepType t) {
    switch (t) {
      case PipelineStepType.start: return Icons.movie_outlined;
      case PipelineStepType.avProcess: return Icons.tune_outlined;
      case PipelineStepType.subtitle: return Icons.subtitles_outlined;
      case PipelineStepType.clip: return Icons.content_cut;
      case PipelineStepType.frame: return Icons.photo_camera_outlined;
      case PipelineStepType.speed: return Icons.speed;
      case PipelineStepType.imageConvert: return Icons.image;
      case PipelineStepType.audioConvert: return Icons.audiotrack;
      case PipelineStepType.audioQuality: return Icons.equalizer;
      case PipelineStepType.audioSpeed: return Icons.speed;
      case PipelineStepType.audioVolume: return Icons.volume_up;
      case PipelineStepType.audioCompressor: return Icons.compress;
      case PipelineStepType.audioMetadata: return Icons.library_music;
      case PipelineStepType.concatMedia: return Icons.merge_type;
      case PipelineStepType.imageToVideo: return Icons.movie_creation;
      case PipelineStepType.imageCrop: return Icons.crop;
      case PipelineStepType.imageRotate: return Icons.rotate_right;
      case PipelineStepType.imageScale: return Icons.photo_size_select_large;
      case PipelineStepType.imageBrightness: return Icons.brightness_6;
      case PipelineStepType.imageNoise: return Icons.grain;
      case PipelineStepType.imageSharpen: return Icons.deblur;
      case PipelineStepType.imageDenoise: return Icons.blur_on;
      case PipelineStepType.imageChannelExtract: return Icons.color_lens_outlined;
      case PipelineStepType.output: return Icons.save_alt_outlined;
    }
  }

  Color _nodeColor(PipelineStepType t, ColorScheme scheme, {int? customColor}) {
    if (customColor != null) return Color(customColor).withAlpha(180);
    switch (t) {
      case PipelineStepType.start: return scheme.primaryContainer;
      case PipelineStepType.output: return scheme.tertiaryContainer;
      default: return scheme.surfaceContainerHighest;
    }
  }

  // ── 节点操作 ──

  void _addNodeAt(PipelineStepType type, Offset canvasPos) {
    _pushUndo();
    final node = PipelineNode(
      id: _uuid.v4(), type: type,
      x: canvasPos.dx, y: canvasPos.dy,
    );
    if (type == PipelineStepType.start && widget.video.filepath.isNotEmpty) {
      node.params['file_media_type'] = widget.video.fileMediaType.name;
    }
    setState(() => _nodes.add(node));
    _trackUsage(type);
  }

  void _addNodeAtCenter(PipelineStepType type) {
    final rb = context.findRenderObject() as RenderBox;
    final center = rb.size.center(Offset.zero);
    final canvasPos = _screenToCanvas(center);
    _addNodeAt(type, canvasPos);
  }

  void _trackUsage(PipelineStepType type) {
    final state = context.read<AppState>();
    state.updateConfig((c) {
      c.nodeUsageCount[type.name] = (c.nodeUsageCount[type.name] ?? 0) + 1;
      return c;
    });
  }

  void _deleteNode(String nodeId) {
    _pushUndo();
    setState(() {
      _nodes.removeWhere((n) => n.id == nodeId);
      _connections.removeWhere((c) => c.fromNodeId == nodeId || c.toNodeId == nodeId);
      _selectedNodeIds.remove(nodeId);
      if (_lastSelectedId == nodeId) {
        _lastSelectedId = _selectedNodeIds.isEmpty ? null : _selectedNodeIds.last;
      }
    });
  }

  void _deleteSelectedNodes() {
    if (_selectedNodeIds.isEmpty) return;
    _pushUndo();
    setState(() {
      final ids = Set<String>.from(_selectedNodeIds);
      for (final id in ids) {
        _nodes.removeWhere((n) => n.id == id);
        _connections.removeWhere((c) => c.fromNodeId == id || c.toNodeId == id);
      }
      _selectedNodeIds.clear();
      _lastSelectedId = null;
    });
  }

  String _mediaTypeName(MediaType t, bool zh) => switch (t) {
    MediaType.video => zh ? '视频' : 'video',
    MediaType.image => zh ? '图片' : 'image',
    MediaType.audio => zh ? '音频' : 'audio',
  };

  void _addConnection(String fromId, String toId) {
    if (fromId == toId) return;
    _pushUndo();
    final fromIdx = _nodes.indexWhere((n) => n.id == fromId);
    final toIdx = _nodes.indexWhere((n) => n.id == toId);
    if (fromIdx < 0 || toIdx < 0) return;
    final fromNode = _nodes[fromIdx];
    final toNode = _nodes[toIdx];
    if (!fromNode.hasOutput || !toNode.hasInput) return;
    if (_connections.any((c) => c.fromNodeId == fromId && c.toNodeId == toId)) return;
    final zh = context.read<AppState>().config.language == 'zh';

    // Container-aware connection check
    if (fromNode.type == PipelineStepType.start && toNode.inputTypes.isNotEmpty && widget.containerInfo != null) {
      final tc = widget.containerInfo!.typeCounts;
      final neededTypes = toNode.inputTypes;
      final matchCount = neededTypes.map((t) => tc[t] ?? 0).fold<int>(0, (a, b) => a + b);
      if (matchCount == 0) {
        showToast(context, zh
            ? '容器内没有${neededTypes.map((t) => _mediaTypeName(t, zh)).join("/")}类型的文件'
            : 'Container has no ${neededTypes.map((t) => t.name).join("/")} files',
            type: ToastType.error);
        return;
      }
      if (matchCount >= 2) {
        toNode.params['container_file_select'] ??= 'all';
      }
    }

    // Source node connecting to a processing node: auto-detect and lock media type
    if (fromNode.type == PipelineStepType.start && toNode.inputTypes.isNotEmpty) {
      final currentMediaType = fromNode.params['file_media_type'] as String?;
      final neededTypes = toNode.inputTypes;

      if (currentMediaType != null && currentMediaType.isNotEmpty) {
        final currentType = MediaType.values.firstWhere((t) => t.name == currentMediaType, orElse: () => MediaType.video);
        if (!neededTypes.contains(currentType)) {
          // Source already locked to a different type
          final existingConns = _connections.where((c) => c.fromNodeId == fromId).toList();
          if (existingConns.isNotEmpty) {
            showToast(context, zh
                ? '源文件已连接${_mediaTypeName(currentType, zh)}类型节点，不能同时连接${_mediaTypeName(neededTypes.first, zh)}类型节点'
                : 'Source is connected to ${currentType.name} nodes, cannot also connect to ${neededTypes.first.name} nodes',
                type: ToastType.error);
            return;
          }
        }
      } else {
        // Config mode: auto-set source media type from first connection
        fromNode.params['file_media_type'] = neededTypes.first.name;
      }
    }

    // Check existing connections from same source node to prevent mixed types
    if (fromNode.type == PipelineStepType.start) {
      final existingConns = _connections.where((c) => c.fromNodeId == fromId).toList();
      for (final ec in existingConns) {
        final existingTarget = _nodes.firstWhere((n) => n.id == ec.toNodeId, orElse: () => PipelineNode(id: '', type: PipelineStepType.output));
        if (existingTarget.inputTypes.isNotEmpty && toNode.inputTypes.isNotEmpty) {
          final existingNeeds = existingTarget.inputTypes;
          final newNeeds = toNode.inputTypes;
          if (existingNeeds.intersection(newNeeds).isEmpty && existingTarget.type != PipelineStepType.output && toNode.type != PipelineStepType.output) {
            showToast(context, zh
                ? '源文件不能同时连接不同媒体类型的处理节点'
                : 'Source cannot connect to different media type nodes',
                type: ToastType.error);
            return;
          }
        }
      }
    }

    final outType = fromNode.outputType;
    final inTypes = toNode.inputTypes;
    if (outType != null && inTypes.isNotEmpty && !inTypes.contains(outType)) {
      showToast(context, zh
            ? '类型不兼容：${fromNode.label} 输出 ${outType.name}，${toNode.label} 需要 ${inTypes.map((t) => t.name).join("/")}'
            : 'Incompatible: ${fromNode.labelEn} outputs ${outType.name}, ${toNode.labelEn} needs ${inTypes.map((t) => t.name).join("/")}',
          type: ToastType.error);
      return;
    }
    setState(() {
      _connections.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId));
    });
  }

  void _deleteConnection(String connId) {
    _pushUndo();
    final conn = _connections.firstWhere((c) => c.id == connId, orElse: () => PipelineConnection(id: '', fromNodeId: '', toNodeId: ''));
    setState(() {
      _connections.removeWhere((c) => c.id == connId);
    });
    if (widget.video.filepath.isEmpty && conn.fromNodeId.isNotEmpty) {
      final fromNode = _nodes.where((n) => n.id == conn.fromNodeId).firstOrNull;
      if (fromNode != null && fromNode.type == PipelineStepType.start) {
        final remaining = _connections.where((c) => c.fromNodeId == conn.fromNodeId).toList();
        final hasProcessingConn = remaining.any((c) {
          final target = _nodes.where((n) => n.id == c.toNodeId).firstOrNull;
          return target != null && target.type != PipelineStepType.output;
        });
        if (!hasProcessingConn) {
          fromNode.params.remove('file_media_type');
        }
      }
    }
  }

  PipelineConnection? _hitTestConnection(Offset pos) {
    const threshold = 8.0;
    for (final conn in _connections) {
      final fi = _nodes.indexWhere((n) => n.id == conn.fromNodeId);
      final ti = _nodes.indexWhere((n) => n.id == conn.toNodeId);
      if (fi < 0 || ti < 0) continue;
      final from = _nodes[fi];
      final to = _nodes[ti];
      final p1 = Offset(from.x + _portZoneW + _nodeWFor(from.type) + _portZoneW / 2, from.y + _nodeH / 2);
      final p2 = Offset(to.x + _portZoneW / 2, to.y + _nodeH / 2);
      if (_distToBezier(pos, p1, p2) < threshold) return conn;
    }
    return null;
  }

  double _distToBezier(Offset pt, Offset p1, Offset p2) {
    final dx = (p2.dx - p1.dx).abs() * 0.5;
    final c1 = Offset(p1.dx + dx, p1.dy);
    final c2 = Offset(p2.dx - dx, p2.dy);
    var minDist = double.infinity;
    for (var t = 0.0; t <= 1.0; t += 0.05) {
      final u = 1 - t;
      final x = u * u * u * p1.dx + 3 * u * u * t * c1.dx + 3 * u * t * t * c2.dx + t * t * t * p2.dx;
      final y = u * u * u * p1.dy + 3 * u * u * t * c1.dy + 3 * u * t * t * c2.dy + t * t * t * p2.dy;
      final d = (Offset(x, y) - pt).distance;
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  void _showConnectionMenu(Offset screenPos, PipelineConnection conn) {
    final s = AppStrings.of(context.read<AppState>().config.language);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(screenPos.dx, screenPos.dy, screenPos.dx + 1, screenPos.dy + 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem(value: 'delete', child: Row(children: [
          Icon(Icons.link_off, size: 16, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 6),
          Text(s.isZh ? '删除连线' : 'Delete Link', style: const TextStyle(fontSize: 13)),
        ])),
      ],
    ).then((action) {
      if (action == 'delete') _deleteConnection(conn.id);
    });
  }

  void _save() {
    final graph = PipelineGraph(nodes: _nodes, connections: _connections, logicBlocks: _logicBlocks);
    final errors = GraphExecutor.validateGraph(graph);
    if (errors.isNotEmpty) {
      final scheme = Theme.of(context).colorScheme;
      final s = AppStrings.of(context.read<AppState>().config.language);
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Icon(Icons.error_outline, color: scheme.error, size: 22),
            const SizedBox(width: 8),
            Text(s.isZh ? '节点逻辑错误' : 'Node Logic Error',
                style: TextStyle(color: scheme.onSurface, fontSize: 16)),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: errors.map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('• ', style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold)),
                Expanded(child: Text(e, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))),
              ]),
            )).toList(),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx),
                child: Text(s.isZh ? '知道了' : 'OK')),
          ],
        ),
      );
      return;
    }
    widget.onSave(graph);
    Navigator.pop(context);
  }

  Future<void> _exportConfig(AppStrings s) async {
    final graph = PipelineGraph(nodes: _nodes, connections: _connections, logicBlocks: _logicBlocks);
    final errors = GraphExecutor.validateGraph(graph);
    if (errors.isNotEmpty) {
      final scheme = Theme.of(context).colorScheme;
      final zh = s.isZh;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: [
            Icon(Icons.error_outline, size: 20, color: scheme.error),
            const SizedBox(width: 8),
            Text(zh ? '无法导出' : 'Cannot Export', style: TextStyle(color: scheme.onSurface)),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(zh ? '配置存在逻辑错误，请先修复：' : 'Config has logic errors. Fix them first:',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              ...errors.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('• ', style: TextStyle(color: scheme.error, fontWeight: FontWeight.bold)),
                  Expanded(child: Text(e, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))),
                ]),
              )),
            ],
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(zh ? '知道了' : 'OK')),
          ],
        ),
      );
      return;
    }

    final descCtrl = TextEditingController();
    final scheme = Theme.of(context).colorScheme;
    final zh = s.isZh;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.file_upload_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Text(zh ? '导出配置' : 'Export Config', style: TextStyle(color: scheme.onSurface)),
        ]),
        content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(zh ? '将当前节点配置导出为 .fppx 文件，可应用于其他视频。' : 'Export current node config as .fppx file for reuse.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withAlpha(80), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(Icons.info_outline, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Text('${_nodes.length} ${zh ? '节点' : 'nodes'}  •  ${_connections.length} ${zh ? '连线' : 'links'}',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ]),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: descCtrl, maxLines: 4,
            decoration: InputDecoration(
              labelText: zh ? '配置介绍（可选）' : 'Description (optional)',
              labelStyle: TextStyle(color: scheme.onSurfaceVariant),
              hintText: zh ? '描述这个配置的用途...' : 'Describe what this config does...',
              hintStyle: TextStyle(color: scheme.outline),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              alignLabelWithHint: true,
            ),
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(zh ? '导出' : 'Export')),
        ],
      ),
    );

    if (confirmed != true) { descCtrl.dispose(); return; }

    final desc = descCtrl.text;
    descCtrl.dispose();

    final result = await FilePicker.platform.saveFile(
      dialogTitle: zh ? '保存配置文件' : 'Save Config File',
      fileName: '${widget.video.filename.replaceAll(RegExp(r'\.[^.]+$'), '')}_config.fppx',
      type: FileType.custom,
      allowedExtensions: ['fppx'],
    );
    if (result == null) return;

    final bytes = FppxExporter.exportGraph(graph, desc);
    await File(result).writeAsBytes(bytes);

    if (mounted) {
      showToast(context, zh ? '已导出: $result' : 'Exported: $result', type: ToastType.success);
    }
  }

  Future<bool> _onWillPop() async {
    if (_nodes.isEmpty) return true;
    final scheme = Theme.of(context).colorScheme;
    final s = AppStrings.of(context.read<AppState>().config.language);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(s.isZh ? '放弃更改?' : 'Discard changes?', style: TextStyle(color: scheme.onSurface)),
        content: Text(s.isZh ? '你有未保存的更改，确定要退出吗？' : 'You have unsaved changes. Discard?',
            style: TextStyle(color: scheme.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.isZh ? '放弃' : 'Discard')),
        ],
      ),
    );
    return result ?? false;
  }

  Offset _screenToCanvas(Offset screen) {
    final inv = Matrix4.inverted(_transformCtrl.value);
    final x = inv.storage[0] * screen.dx + inv.storage[4] * screen.dy + inv.storage[12];
    final y = inv.storage[1] * screen.dx + inv.storage[5] * screen.dy + inv.storage[13];
    return Offset(x, y);
  }

  Offset _outPort(PipelineNode n) => Offset(n.x + _portZoneW + _nodeWFor(n.type) + _portZoneW / 2, n.y + _nodeH / 2);
  Offset _inPort(PipelineNode n) => Offset(n.x + _portZoneW / 2, n.y + _nodeH / 2);

  // ── 缩放/整理/定位 ──

  void _zoomTo(double newScale) {
    final rb = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final viewCenter = rb.size.center(Offset.zero);
    final canvasCenter = _screenToCanvas(viewCenter);
    final clamped = newScale.clamp(0.3, 2.0);
    _transformCtrl.value = Matrix4.identity()
      ..translate(viewCenter.dx, viewCenter.dy)
      ..scale(clamped)
      ..translate(-canvasCenter.dx, -canvasCenter.dy);
  }

  void _zoomToFit() {
    if (_nodes.isEmpty) return;
    final rb = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final viewSize = rb.size;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final n in _nodes) {
      if (n.x < minX) minX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.x + _totalNodeWFor(n.type) > maxX) maxX = n.x + _totalNodeWFor(n.type);
      if (n.y + _nodeH > maxY) maxY = n.y + _nodeH;
    }
    final contentW = maxX - minX + 80;
    final contentH = maxY - minY + 80;
    final scale = math.min(viewSize.width / contentW, viewSize.height / contentH).clamp(0.3, 2.0);
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    _transformCtrl.value = Matrix4.identity()
      ..translate(viewSize.width / 2, viewSize.height / 2)
      ..scale(scale)
      ..translate(-cx, -cy);
  }

  void _autoLayout() {
    if (_nodes.isEmpty) return;
    _pushUndo();
    final adj = <String, List<String>>{};
    final inDeg = <String, int>{};
    for (final n in _nodes) {
      adj[n.id] = [];
      inDeg[n.id] = 0;
    }
    for (final c in _connections) {
      adj[c.fromNodeId]?.add(c.toNodeId);
      inDeg[c.toNodeId] = (inDeg[c.toNodeId] ?? 0) + 1;
    }
    // BFS topo layers
    final layers = <List<String>>[];
    var queue = [for (final n in _nodes) if (inDeg[n.id] == 0) n.id];
    final visited = <String>{};
    while (queue.isNotEmpty) {
      layers.add(queue);
      visited.addAll(queue);
      final next = <String>[];
      for (final id in queue) {
        for (final to in adj[id]!) {
          inDeg[to] = (inDeg[to] ?? 1) - 1;
          if (inDeg[to] == 0 && !visited.contains(to)) next.add(to);
        }
      }
      queue = next;
    }
    // Append any unvisited nodes (cycles/disconnected)
    final remaining = _nodes.where((n) => !visited.contains(n.id)).map((n) => n.id).toList();
    if (remaining.isNotEmpty) layers.add(remaining);

    const gapX = 300.0;
    const gapY = 100.0;
    final startX = _canvasSize / 2 - (layers.length * gapX) / 2;
    setState(() {
      for (var col = 0; col < layers.length; col++) {
        final layer = layers[col];
        final startY = _canvasSize / 2 - (layer.length * (_nodeH + gapY)) / 2;
        for (var row = 0; row < layer.length; row++) {
          final node = _nodes.firstWhere((n) => n.id == layer[row]);
          node.x = startX + col * gapX;
          node.y = startY + row * (_nodeH + gapY);
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _zoomToFit());
  }

  void _goToSource(AppStrings s) {
    final startNodes = _nodes.where((n) => n.type == PipelineStepType.start).toList();
    if (startNodes.isEmpty) {
      showToast(context, s.isZh ? '没有源文件节点' : 'No source nodes', type: ToastType.info);
      return;
    }
    final target = startNodes[_sourceAnchorIndex % startNodes.length];
    _sourceAnchorIndex++;
    final rb = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final viewCenter = rb.size.center(Offset.zero);
    final nodeCenterX = target.x + _totalNodeWFor(target.type) / 2;
    final nodeCenterY = target.y + _nodeH / 2;
    _transformCtrl.value = Matrix4.identity()
      ..translate(viewCenter.dx, viewCenter.dy)
      ..scale(_currentScale)
      ..translate(-nodeCenterX, -nodeCenterY);
    setState(() {
      _selectedNodeIds = {target.id};
      _lastSelectedId = target.id;
    });
  }

  // ── 右键菜单 ──

  void _startLogicBoxSelect(LogicBlockType type, AppStrings s) {
    setState(() {
      _isLogicBoxSelecting = true;
      _pendingLogicType = type;
      _selectedNodeIds.clear();
      _lastSelectedId = null;
    });
    showToast(context, s.isZh ? '请在画布中框选要包含的元素' : 'Box-select elements on canvas to include', type: ToastType.info);
  }

  void _finishLogicBoxSelect(AppStrings s) {
    final validIds = _selectedNodeIds.where((id) {
      final n = _nodes.firstWhere((n) => n.id == id, orElse: () => PipelineNode(id: '', type: PipelineStepType.start));
      return n.id.isNotEmpty && n.type != PipelineStepType.start && n.type != PipelineStepType.output;
    }).toList();

    if (validIds.isEmpty) {
      setState(() { _isLogicBoxSelecting = false; _pendingLogicType = null; });
      showToast(context, s.isZh ? '未选中有效的处理元素' : 'No valid processing elements selected', type: ToastType.warning);
      return;
    }

    // Check if any selected node is already in a logic block
    for (final block in _logicBlocks) {
      if (validIds.any((id) => block.childNodeIds.contains(id))) {
        setState(() { _isLogicBoxSelecting = false; _pendingLogicType = null; });
        showToast(context, s.isZh ? '选中的元素已在其他逻辑块中' : 'Selected elements are already in another logic block', type: ToastType.warning);
        return;
      }
    }

    // Calculate bounding box of selected nodes
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final id in validIds) {
      final n = _nodes.firstWhere((n) => n.id == id);
      minX = math.min(minX, n.x);
      minY = math.min(minY, n.y);
      maxX = math.max(maxX, n.x + _totalNodeWFor(n.type));
      maxY = math.max(maxY, n.y + _nodeH);
    }
    final padding = 20.0;

    _showLoopCountDialog(s).then((count) {
      if (count != null && count > 0) {
        _pushUndo();
        setState(() {
          _logicBlocks.add(LogicBlock(
            id: _uuid.v4(),
            type: _pendingLogicType!,
            childNodeIds: validIds,
            params: {'count': count},
            x: minX - padding,
            y: minY - padding - 20,
            width: maxX - minX + padding * 2,
            height: maxY - minY + padding * 2 + 20,
          ));
          _isLogicBoxSelecting = false;
          _pendingLogicType = null;
          _selectedNodeIds.clear();
        });
      } else {
        setState(() { _isLogicBoxSelecting = false; _pendingLogicType = null; });
      }
    });
  }

  Future<int?> _showLoopCountDialog(AppStrings s) {
    int count = 10;
    final scheme = Theme.of(context).colorScheme;
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.isZh ? '设置循环次数' : 'Set Loop Count', style: TextStyle(fontSize: 16, color: scheme.onSurface)),
        content: TextFormField(
          initialValue: '10',
          autofocus: true,
          style: TextStyle(color: scheme.onSurface, fontSize: 14),
          decoration: InputDecoration(
            labelText: s.isZh ? '循环次数' : 'Loop Count',
            labelStyle: TextStyle(color: scheme.onSurfaceVariant),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) { count = int.tryParse(v) ?? 10; },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.isZh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, count), child: Text(s.isZh ? '确定' : 'OK')),
        ],
      ),
    );
  }

  static const _videoTypes = [
    PipelineStepType.avProcess,
    PipelineStepType.subtitle,
    PipelineStepType.clip,
    PipelineStepType.frame,
    PipelineStepType.speed,
  ];
  static const _audioTypes = [
    PipelineStepType.audioConvert,
    PipelineStepType.audioQuality,
    PipelineStepType.audioSpeed,
    PipelineStepType.audioVolume,
    PipelineStepType.audioCompressor,
    PipelineStepType.audioMetadata,
  ];
  static const _imageTypes = [
    PipelineStepType.imageConvert,
    PipelineStepType.imageCrop,
    PipelineStepType.imageRotate,
    PipelineStepType.imageScale,
    PipelineStepType.imageBrightness,
    PipelineStepType.imageNoise,
    PipelineStepType.imageSharpen,
    PipelineStepType.imageDenoise,
    PipelineStepType.imageChannelExtract,
  ];
  static const _containerTypes = [
    PipelineStepType.concatMedia,
    PipelineStepType.imageToVideo,
  ];
  static const _allNodeTypes = [
    PipelineStepType.start,
    ..._videoTypes,
    ..._audioTypes,
    ..._imageTypes,
    PipelineStepType.output,
  ];

  List<PipelineStepType> _top5Types() {
    final counts = context.read<AppState>().config.nodeUsageCount;
    final sorted = List<PipelineStepType>.from(_allNodeTypes)
      ..sort((a, b) => (counts[b.name] ?? 0).compareTo(counts[a.name] ?? 0));
    final top = sorted.take(5).toList();
    if (!top.contains(PipelineStepType.start)) top[4] = PipelineStepType.start;
    if (!top.contains(PipelineStepType.output)) {
      final idx = top.indexWhere((t) => t != PipelineStepType.start && (counts[t.name] ?? 0) == 0);
      if (idx >= 0) top[idx] = PipelineStepType.output;
      else top[3] = PipelineStepType.output;
    }
    return top;
  }

  void _showCanvasMenu(Offset screenPos) {
    final s = AppStrings.of(context.read<AppState>().config.language);
    final scheme = Theme.of(context).colorScheme;
    final canvasPos = _screenToCanvas(screenPos);
    final top5 = _top5Types();

    PopupMenuItem<PipelineStepType> _item(PipelineStepType t) {
      final dummy = PipelineNode(id: '', type: t);
      return PopupMenuItem(
        value: t,
        child: Row(children: [
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(color: _nodeColor(t, scheme), borderRadius: BorderRadius.circular(5)),
            child: Icon(_stepIcon(t), size: 13, color: scheme.onSurface),
          ),
          const SizedBox(width: 8),
          Text(s.isZh ? dummy.label : dummy.labelEn, style: const TextStyle(fontSize: 13)),
          if (dummy.mediaTag.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(dummy.mediaTag, style: TextStyle(fontSize: 9, color: scheme.outline)),
          ],
        ]),
      );
    }

    showMenu<PipelineStepType>(
      context: context,
      position: RelativeRect.fromLTRB(screenPos.dx, screenPos.dy, screenPos.dx + 1, screenPos.dy + 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        ...top5.map(_item),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: null,
          enabled: false,
          height: 0,
          child: PopupMenuButton<PipelineStepType>(
            tooltip: '',
            offset: const Offset(200, 0),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            itemBuilder: (_) => _allNodeTypes.map(_item).toList(),
            onSelected: (type) {
              Navigator.pop(context);
              _addNodeAt(type, canvasPos);
            },
            child: Row(children: [
              Icon(Icons.more_horiz, size: 16, color: scheme.outline),
              const SizedBox(width: 8),
              Text(s.isZh ? '全部元素...' : 'All elements...', style: TextStyle(fontSize: 13, color: scheme.outline)),
            ]),
          ),
        ),
      ],
    ).then((type) {
      if (type != null) _addNodeAt(type, canvasPos);
    });
  }

  void _showNodeMenu(Offset screenPos, String nodeId) {
    final s = AppStrings.of(context.read<AppState>().config.language);
    final multiSelected = _selectedNodeIds.length > 1 && _selectedNodeIds.contains(nodeId);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(screenPos.dx, screenPos.dy, screenPos.dx + 1, screenPos.dy + 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem(value: 'delete', child: Row(children: [
          Icon(Icons.delete_outline, size: 16, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 6),
          Text(s.isZh ? '删除节点' : 'Delete Node', style: const TextStyle(fontSize: 13)),
        ])),
        if (multiSelected)
          PopupMenuItem(value: 'delete_selected', child: Row(children: [
            Icon(Icons.delete_sweep_outlined, size: 16, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 6),
            Text(s.isZh ? '删除选中 (${_selectedNodeIds.length}个)' : 'Delete Selected (${_selectedNodeIds.length})',
                style: const TextStyle(fontSize: 13)),
          ])),
      ],
    ).then((action) {
      if (action == 'delete') {
        _deleteNode(nodeId);
      } else if (action == 'delete_selected') {
        _deleteSelectedNodes();
      }
    });
  }

  // ── 构建步骤编辑器 ──

  String? _resolveSourceImagePath(PipelineNode node) {
    final visited = <String>{};
    String? trace(String nodeId) {
      if (visited.contains(nodeId)) return null;
      visited.add(nodeId);
      for (final conn in _connections.where((c) => c.toNodeId == nodeId)) {
        final srcIdx = _nodes.indexWhere((n) => n.id == conn.fromNodeId);
        if (srcIdx < 0) continue;
        final src = _nodes[srcIdx];
        if (src.type == PipelineStepType.start && src.outputType == MediaType.image) {
          return widget.video.filepath;
        }
        final result = trace(src.id);
        if (result != null) return result;
      }
      return null;
    }
    return trace(node.id);
  }

  String? _resolveUpstreamExtension(PipelineNode node) {
    final visited = <String>{};
    String? trace(String nodeId) {
      if (visited.contains(nodeId)) return null;
      visited.add(nodeId);
      for (final conn in _connections.where((c) => c.toNodeId == nodeId)) {
        final srcIdx = _nodes.indexWhere((n) => n.id == conn.fromNodeId);
        if (srcIdx < 0) continue;
        final src = _nodes[srcIdx];
        if (src.type == PipelineStepType.audioConvert) {
          return src.params['output_format'] as String? ?? 'm4a';
        }
        if (src.type == PipelineStepType.imageConvert) {
          return src.params['output_format'] as String? ?? 'png';
        }
        final result = trace(src.id);
        if (result != null) return result;
      }
      return null;
    }
    return trace(node.id);
  }

  Widget _buildStepEditor(PipelineNode node, bool isZh) {
    void onChanged() => setState(() {});
    final v = widget.video;
    Widget editor;
    switch (node.type) {
      case PipelineStepType.start:
        if (widget.containerInfo != null) {
          final cName = widget.containerInfo!.name;
          final cCount = widget.containerInfo!.fileCount;
          final cs = Theme.of(context).colorScheme;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Container(
                width: double.infinity, height: 80,
                decoration: BoxDecoration(color: cs.primaryContainer.withAlpha(60), borderRadius: BorderRadius.circular(8)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.folder_special, size: 32, color: cs.primary),
                  const SizedBox(height: 4),
                  Text(cName, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
                  Text('$cCount ${isZh ? "个文件" : "files"}', style: TextStyle(fontSize: 11, color: cs.outline)),
                ]),
              ),
            ),
          ]);
        }
        return Column(mainAxisSize: MainAxisSize.min, children: [
          if (_thumbPath != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(_thumbPath!), width: double.infinity, height: 140,
                    fit: widget.video.fileMediaType == MediaType.audio ? BoxFit.contain : BoxFit.cover),
              ),
            )
          else if (_isAudioNoCover)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Container(
                width: double.infinity, height: 100,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(80),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.music_note, size: 48, color: Theme.of(context).colorScheme.primary),
              ),
            ),
          StartStepEditor(filename: v.filename, resolution: v.resolution, durationStr: v.durationStr,
              sizeMb: v.sizeMb, codec: v.codec, pixFmt: v.pixFmt, audioCodec: v.audioCodec, audioChannels: v.audioChannels, isZh: isZh),
        ]);
      case PipelineStepType.output:
        final resolvedExt = _resolveUpstreamExtension(node);
        return OutputStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh,
            sourceFilename: resolvedExt != null ? v.filename.replaceAll(RegExp(r'\.[^.]+$'), '.$resolvedExt') : v.filename,
            defaultOutputDir: context.read<AppState>().config.defaultOutputDir);
      case PipelineStepType.avProcess:
        editor = AvProcessStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.subtitle:
        editor = SubtitleStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh, embeddedSubtitles: v.subtitles);
      case PipelineStepType.clip:
        editor = ClipStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, videoPath: v.filepath, videoDuration: v.duration, isZh: isZh);
      case PipelineStepType.frame:
        editor = FrameStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, videoPath: v.filepath, videoDuration: v.duration, isZh: isZh);
      case PipelineStepType.speed:
        editor = SpeedStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.imageConvert:
        editor = ImageConvertStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.audioConvert:
        editor = AudioConvertStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.audioQuality:
        editor = AudioQualityStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.audioSpeed:
        editor = AudioSpeedStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.audioVolume:
        editor = AudioVolumeStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.audioCompressor:
        editor = AudioCompressorStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.audioMetadata:
        editor = AudioMetadataStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.concatMedia:
        editor = ConcatMediaStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh,
            containerFileCount: widget.containerInfo?.fileCount ?? 0);
      case PipelineStepType.imageToVideo:
        editor = ImageToVideoStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh,
            containerFileCount: widget.containerInfo?.fileCount ?? 0);
      case PipelineStepType.imageCrop:
        editor = ImageCropStepEditor(
          key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh,
          sourceImagePath: _resolveSourceImagePath(node),
        );
      case PipelineStepType.imageRotate:
        editor = ImageRotateStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.imageScale:
        editor = ImageScaleStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.imageBrightness:
        editor = ImageBrightnessStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.imageNoise:
        editor = ImageNoiseStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.imageSharpen:
        editor = ImageSharpenStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.imageDenoise:
        editor = ImageDenoiseStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.imageChannelExtract:
        editor = ImageChannelExtractStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
    }

    // Wrap with container file-selection header + node naming/coloring footer
    final cs = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // Container file selection (only in container mode with >= 2 matching files)
      if (widget.containerInfo != null && node.params.containsKey('container_file_select'))
        _buildFileSelectHeader(node, isZh, cs, onChanged),
      editor,
      // Node naming & color (not for preview)
      if (node.id != '__preview__')
        _buildNodeCustomSection(node, isZh, cs, onChanged),
    ]);
  }

  Widget _buildFileSelectHeader(PipelineNode node, bool isZh, ColorScheme cs, VoidCallback onChanged) {
    final mode = node.params['container_file_select'] as String? ?? 'all';
    final selectedIndices = node.params['container_selected_indices'] as String? ?? '';
    final fileCount = widget.containerInfo!.fileCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withAlpha(40),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.primary.withAlpha(60)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.filter_list, size: 14, color: cs.primary),
            const SizedBox(width: 6),
            Text(isZh ? '文件选择 ($fileCount 个可用)' : 'File Selection ($fileCount available)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
          ]),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'all', label: Text(isZh ? '全部处理' : 'All', style: const TextStyle(fontSize: 11))),
              ButtonSegment(value: 'select', label: Text(isZh ? '指定文件' : 'Select', style: const TextStyle(fontSize: 11))),
            ],
            selected: {mode},
            onSelectionChanged: (s) { setState(() => node.params['container_file_select'] = s.first); onChanged(); },
          ),
          if (mode == 'select') ...[
            const SizedBox(height: 8),
            TextField(
              controller: TextEditingController(text: selectedIndices),
              decoration: InputDecoration(
                hintText: isZh ? '输入编号，如: 1,3,5' : 'e.g. 1,3,5',
                hintStyle: TextStyle(color: cs.outline, fontSize: 11),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              ),
              style: TextStyle(fontSize: 12, color: cs.onSurface),
              onChanged: (v) { node.params['container_selected_indices'] = v; onChanged(); },
            ),
          ],
        ]),
      ),
    );
  }

  Widget _buildNodeCustomSection(PipelineNode node, bool isZh, ColorScheme cs, VoidCallback onChanged) {
    final nodeName = node.params['node_name'] as String? ?? '';
    final nodeColorVal = node.params['node_color'] as int?;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withAlpha(40),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(isZh ? '自定义' : 'Custom', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.outline)),
          const SizedBox(height: 6),
          TextField(
            controller: TextEditingController(text: nodeName),
            decoration: InputDecoration(
              labelText: isZh ? '节点名称' : 'Node Name',
              labelStyle: TextStyle(fontSize: 11, color: cs.outline),
              hintText: isZh ? '可选，显示在节点右下角' : 'Optional, shown bottom-right',
              hintStyle: TextStyle(fontSize: 10, color: cs.outline),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            ),
            style: TextStyle(fontSize: 12, color: cs.onSurface),
            onChanged: (v) { setState(() => node.params['node_name'] = v); onChanged(); },
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text(isZh ? '颜色: ' : 'Color: ', style: TextStyle(fontSize: 11, color: cs.outline)),
            const SizedBox(width: 4),
            for (final c in [null, 0xFFEF4444, 0xFF3B82F6, 0xFF10B981, 0xFFF59E0B, 0xFF8B5CF6])
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: GestureDetector(
                  onTap: () { setState(() { if (c == null) node.params.remove('node_color'); else node.params['node_color'] = c; }); onChanged(); },
                  child: Container(
                    width: 18, height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c != null ? Color(c) : cs.surfaceContainerHighest,
                      border: Border.all(
                        color: nodeColorVal == c || (c == null && nodeColorVal == null) ? cs.onSurface : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: c == null ? Icon(Icons.block, size: 10, color: cs.outline) : null,
                  ),
                ),
              ),
          ]),
        ]),
      ),
    );
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = AppStrings.of(context.watch<AppState>().config.language);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _onWillPop()) nav.pop();
      },
      child: _withWallpaper(context, Scaffold(
        backgroundColor: Colors.transparent,
        appBar: Platform.isWindows ? AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () async {
            final nav = Navigator.of(context);
            if (await _onWillPop()) nav.pop();
          }),
          title: Text(
            s.isZh ? '编辑: ${widget.video.filename}' : 'Edit: ${widget.video.filename}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: s.isZh ? '导出配置' : 'Export Config',
              onPressed: _nodes.isEmpty ? null : () => _exportConfig(s),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check, size: 18),
                label: Text(s.save),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ) : null,
        body: _buildBody(scheme, s),
      )),
    );
  }

  // ── Body with CSD title bar ──

  Widget _buildBody(ColorScheme scheme, AppStrings s) {
    final content = Padding(
      padding: EdgeInsets.only(top: Platform.isWindows ? 0 : 36),
      child: Column(children: [
        Expanded(child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(children: [
            Expanded(flex: 3, child: _buildCanvas(scheme, s)),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: _buildRightPanel(scheme, s)),
          ]),
        )),
        _buildBottomBar(scheme, s),
      ]),
    );
    if (Platform.isWindows) return content;
    return Stack(children: [
      content,
      Positioned(left: 0, right: 0, top: 0, child: _buildEditorCsdTitleBar(scheme)),
    ]);
  }

  Widget _buildEditorCsdTitleBar(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.surface.withAlpha(isDark ? 160 : 180),
                scheme.surface.withAlpha(isDark ? 120 : 140),
              ],
            ),
            border: Border(bottom: BorderSide(
              color: scheme.outlineVariant.withAlpha(isDark ? 60 : 80),
              width: 0.5,
            )),
          ),
          child: Stack(children: [
            DragToMoveArea(child: GestureDetector(
              onDoubleTap: () async {
                if (await windowManager.isMaximized()) {
                  windowManager.unmaximize();
                } else {
                  windowManager.maximize();
                }
              },
              child: Container(color: Colors.transparent),
            )),
            Positioned(left: 8, top: 0, bottom: 0, child: Row(mainAxisSize: MainAxisSize.min, children: [
              _EditorCsdBtn(icon: Icons.arrow_back, color: scheme.onSurfaceVariant, onTap: () async {
                final nav = Navigator.of(context);
                if (await _onWillPop()) nav.pop();
              }),
            ])),
            Positioned(right: 0, top: 0, bottom: 0, child: Row(mainAxisSize: MainAxisSize.min, children: [
              _EditorCsdBtn(icon: Icons.remove, color: scheme.onSurfaceVariant, onTap: () => windowManager.minimize()),
              _EditorCsdBtn(
                icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
                color: scheme.onSurfaceVariant,
                onTap: () async {
                  if (await windowManager.isMaximized()) {
                    windowManager.unmaximize();
                  } else {
                    windowManager.maximize();
                  }
                },
              ),
              _EditorCsdBtn(icon: Icons.close, color: scheme.onSurface, hoverBg: Colors.red, onTap: () => windowManager.close()),
            ])),
          ]),
        ),
      ),
    );
  }

  // ── 壁纸 ──

  Widget _withWallpaper(BuildContext context, Widget child) {
    final cfg = context.watch<AppState>().config;
    final bg = cfg.backgroundImage;
    if (bg.isEmpty || !File(bg).existsSync()) return child;
    final scheme = Theme.of(context).colorScheme;
    final a = ((1.0 - cfg.backgroundOpacity) * 220).round().clamp(20, 240);
    return Stack(children: [
      Positioned.fill(child: Image.file(File(bg), fit: BoxFit.cover)),
      Positioned.fill(child: Container(color: scheme.surface.withAlpha(a))),
      Theme(data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: Theme.of(context).appBarTheme.copyWith(backgroundColor: Colors.transparent),
      ), child: child),
    ]);
  }

  Widget _glassWrap(Widget child, ColorScheme scheme) {
    final cfg = context.read<AppState>().config;
    final ca = (cfg.cardOpacity * 255).round().clamp(0, 255);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface.withAlpha(ca),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
          ),
          child: child,
        ),
      ),
    );
  }

  // ── 画布 ──

  bool _isCtrlPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) || keys.contains(LogicalKeyboardKey.controlRight);
  }

  Widget _buildCanvas(ColorScheme scheme, AppStrings s) {

    final canvas = Listener(
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
          // Right-click: record start for drag-to-pan vs menu detection
          _rightClickStart = e.position;
          _rightClickGlobal = e.position;
          _isRightDragging = false;
        } else if (e.kind == PointerDeviceKind.mouse && e.buttons == kPrimaryMouseButton) {
          // Left-click on empty canvas: start box-select or deselect
          final canvasPos = _screenToCanvas(e.localPosition);
          final hitNode = _findNodeAtCanvasPos(canvasPos);
          if (hitNode == null) {
            final hitConn = _hitTestConnection(canvasPos);
            if (hitConn == null) {
              // No node or connection hit: start box-select
              setState(() {
                _boxSelectStart = canvasPos;
                _boxSelectRect = null;
                _isBoxSelecting = true;
                if (!_isCtrlPressed()) {
                  _selectedNodeIds.clear();
                  _lastSelectedId = null;
                }
              });
            }
          }
        }
      },
      onPointerMove: (e) {
        // Right-click drag-to-pan
        if (e.kind == PointerDeviceKind.mouse && (e.buttons & kSecondaryMouseButton) != 0 && _rightClickStart != null) {
          if (!_isRightDragging) {
            if ((_rightClickStart! - e.position).distance > 8) {
              _isRightDragging = true;
            }
          }
          if (_isRightDragging) {
            final delta = e.position - _rightClickGlobal!;
            _rightClickGlobal = e.position;
            _transformCtrl.value = _transformCtrl.value.clone()..translate(delta.dx, delta.dy);
          }
        }
        // Left-click box-select drag
        if (_isBoxSelecting && _boxSelectStart != null && (e.buttons & kPrimaryMouseButton) != 0) {
          final canvasPos = _screenToCanvas(e.localPosition);
          setState(() {
            _boxSelectRect = Rect.fromPoints(_boxSelectStart!, canvasPos);
          });
        }
      },
      onPointerUp: (e) {
        // Right-click release
        if (e.kind == PointerDeviceKind.mouse && _rightClickStart != null) {
          if (!_isRightDragging) {
            // Was a click, not a drag → show context menu
            final canvasPos = _screenToCanvas(e.localPosition);
            final hitNode = _findNodeAtCanvasPos(canvasPos);
            if (hitNode != null) {
              // handled by node's onSecondaryTapUp
            } else {
              final hitConn = _hitTestConnection(canvasPos);
              if (hitConn != null) {
                _showConnectionMenu(e.position, hitConn);
              } else {
                _showCanvasMenu(e.position);
              }
            }
          }
          _rightClickStart = null;
          _rightClickGlobal = null;
          _isRightDragging = false;
        }
        // Box-select release
        if (_isBoxSelecting) {
          if (_boxSelectRect != null) {
            final rect = _boxSelectRect!;
            setState(() {
              for (final n in _nodes) {
                final nodeRect = Rect.fromLTWH(n.x, n.y, _totalNodeWFor(n.type), _nodeH);
                if (rect.overlaps(nodeRect)) {
                  _selectedNodeIds.add(n.id);
                  _lastSelectedId = n.id;
                }
              }
            });
          } else {
            // Click on empty canvas without drag: deselect all
            if (!_isCtrlPressed()) {
              setState(() {
                _selectedNodeIds.clear();
                _lastSelectedId = null;
              });
            }
          }
          setState(() {
            _boxSelectStart = null;
            _boxSelectRect = null;
            _isBoxSelecting = false;
          });
          if (_isLogicBoxSelecting && _selectedNodeIds.isNotEmpty) {
            _finishLogicBoxSelect(s);
          }
        }
      },
      child: InteractiveViewer(
        transformationController: _transformCtrl,
        constrained: false,
        panEnabled: !_isBoxSelecting,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        minScale: 0.3,
        maxScale: 2.0,
        child: SizedBox(
          width: _canvasSize,
          height: _canvasSize,
          child: Stack(clipBehavior: Clip.none, children: [
            // 网格背景
            Positioned.fill(child: CustomPaint(painter: _GridPainter(color: scheme.outlineVariant.withAlpha(25)))),
            // 连线
            CustomPaint(
              size: Size(_canvasSize, _canvasSize),
              painter: _ConnectionPainter(
                nodes: _nodes,
                connections: _connections,
                color: scheme.primary.withAlpha(140),
                selectedNodeIds: _selectedNodeIds,
              ),
            ),
            // 临时拖拽连线
            if (_dragFromNodeId != null && _dragLineEnd != null)
              CustomPaint(
                size: Size(_canvasSize, _canvasSize),
                painter: _TempLinePainter(
                  from: _dragIsOutput
                      ? _outPort(_nodes.firstWhere((n) => n.id == _dragFromNodeId))
                      : _dragLineEnd!,
                  to: _dragIsOutput
                      ? _dragLineEnd!
                      : _inPort(_nodes.firstWhere((n) => n.id == _dragFromNodeId)),
                  color: scheme.primary.withAlpha(100),
                ),
              ),
            // 节点
            for (final node in _nodes)
              Positioned(
                left: node.x, top: node.y,
                child: _buildNodeWidget(node, scheme, s),
              ),
            // 逻辑块虚线框
            for (final block in _logicBlocks)
              Positioned(
                left: block.x, top: block.y,
                child: _buildLogicBlockOverlay(block, scheme, s),
              ),
            // Box-select overlay
            if (_boxSelectRect != null)
              CustomPaint(
                size: Size(_canvasSize, _canvasSize),
                painter: _BoxSelectPainter(rect: _boxSelectRect!, color: scheme.primary),
              ),
          ]),
        ),
      ),
    );

    // Wrap canvas area with Focus for Ctrl+A
    final focusedCanvas = Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bindings = context.read<AppState>().config.keyBindings;

        // Select all (Ctrl+A)
        final selectAll = bindings['canvas_select_all'] ?? ['Control', 'A'];
        if (selectAll.isNotEmpty && _isCtrlPressed() && event.logicalKey == LogicalKeyboardKey.keyA) {
          if (selectAll.contains('Control') && selectAll.contains('A')) {
            setState(() {
              _selectedNodeIds = _nodes.map((n) => n.id).toSet();
              if (_nodes.isNotEmpty) _lastSelectedId = _nodes.last.id;
            });
            return KeyEventResult.handled;
          }
        }

        // Delete selected (Delete key by default)
        final delBinding = bindings['canvas_delete_selected'] ?? ['Delete'];
        if (delBinding.isNotEmpty && _selectedNodeIds.isNotEmpty) {
          final keyLabel = event.logicalKey.keyLabel;
          final nonModifiers = delBinding.where((b) => !const {'Control', 'Shift', 'Alt', 'Meta'}.contains(b)).toList();
          final modifiers = delBinding.where((b) => const {'Control', 'Shift', 'Alt', 'Meta'}.contains(b)).toSet();
          final pressed = HardwareKeyboard.instance.logicalKeysPressed;
          final heldMods = <String>{};
          for (final k in pressed) {
            if (k == LogicalKeyboardKey.controlLeft || k == LogicalKeyboardKey.controlRight) heldMods.add('Control');
            if (k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight) heldMods.add('Shift');
            if (k == LogicalKeyboardKey.altLeft || k == LogicalKeyboardKey.altRight) heldMods.add('Alt');
          }
          if (heldMods.length == modifiers.length && heldMods.containsAll(modifiers) &&
              nonModifiers.length == 1 && keyLabel.toLowerCase() == nonModifiers.first.toLowerCase()) {
            _deleteSelectedNodes();
            return KeyEventResult.handled;
          }
        }

        // Undo (Ctrl+Z)
        if (_isCtrlPressed() && event.logicalKey == LogicalKeyboardKey.keyZ && !HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) && !HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight)) {
          _undo();
          return KeyEventResult.handled;
        }
        // Redo (Ctrl+Shift+Z)
        if (_isCtrlPressed() && event.logicalKey == LogicalKeyboardKey.keyZ && (HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) || HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight))) {
          _redo();
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
      child: canvas,
    );

    final inner = Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Row(children: [
          if (!Platform.isWindows) ...[
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () async {
                final nav = Navigator.of(context);
                if (await _onWillPop()) nav.pop();
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.arrow_back, size: 18, color: scheme.onSurface),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Icon(Icons.account_tree_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(s.isZh ? '节点编辑器' : 'Node Editor',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.undo, size: 16, color: _undoStack.isEmpty ? scheme.outlineVariant : scheme.onSurfaceVariant),
            tooltip: s.isZh ? '撤销' : 'Undo',
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            onPressed: _undoStack.isEmpty ? null : _undo,
          ),
          IconButton(
            icon: Icon(Icons.redo, size: 16, color: _redoStack.isEmpty ? scheme.outlineVariant : scheme.onSurfaceVariant),
            tooltip: s.isZh ? '重做' : 'Redo',
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            onPressed: _redoStack.isEmpty ? null : _redo,
          ),
          const Spacer(),
          if (!Platform.isWindows) ...[
            IconButton(
              icon: Icon(Icons.file_upload_outlined, size: 18, color: scheme.onSurface),
              tooltip: s.isZh ? '导出配置' : 'Export Config',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: _nodes.isEmpty ? null : () => _exportConfig(s),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check, size: 16),
              label: Text(s.save, style: const TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ] else
            Text(s.isZh ? '右键添加节点' : 'Right-click to add',
                style: TextStyle(fontSize: 10, color: scheme.outline)),
        ]),
      ),
      const Divider(height: 1, indent: 12, endIndent: 12),
      if (_isLogicBoxSelecting)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.red.withAlpha(30),
          child: Row(children: [
            Icon(Icons.info_outline, size: 14, color: Colors.red),
            const SizedBox(width: 8),
            Text(s.isZh ? '请在画布中框选要包含的元素，然后松开鼠标' : 'Box-select elements on canvas, then release',
                style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w500)),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() { _isLogicBoxSelecting = false; _pendingLogicType = null; }),
              child: Text(s.isZh ? '取消' : 'Cancel', style: const TextStyle(fontSize: 12)),
            ),
          ]),
        ),
      Expanded(child: ClipRRect(
        key: _canvasKey,
        borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(12), bottomRight: Radius.circular(12)),
        child: DragTarget<PipelineStepType>(
          onAcceptWithDetails: (details) {
            final rb = context.findRenderObject() as RenderBox;
            final local = rb.globalToLocal(details.offset);
            final canvasPos = _screenToCanvas(local);
            _addNodeAt(details.data, canvasPos);
          },
          builder: (ctx, candidateData, rejectedData) => Stack(children: [
            focusedCanvas,
            if (context.read<AppState>().config.debugMode)
              Positioned(
                left: 8, bottom: 8, right: 80,
                child: IgnorePointer(child: Text(
                  GraphExecutor.describeGraph(PipelineGraph(nodes: _nodes, connections: _connections, logicBlocks: _logicBlocks)),
                  style: TextStyle(fontSize: 10, color: scheme.onSurface.withAlpha(128), height: 1.4),
                )),
              ),
            Positioned(
              right: 10, bottom: context.read<AppState>().config.aiEnabled ? 60 : 10,
              child: _buildCanvasControls(scheme, s),
            ),
            if (context.read<AppState>().config.aiEnabled)
              Positioned(
                right: 10, bottom: 10,
                child: _AiPanel(
                  strings: s,
                  existingNodes: _nodes,
                  existingConnections: _connections,
                  onApplyGraph: (nodes, connections) {
                    _pushUndo();
                    setState(() {
                      _nodes.clear();
                      _connections.clear();
                      _nodes.addAll(nodes);
                      _connections.addAll(connections);
                    });
                  },
                  onMergeGraph: (aiNodes, aiConns) {
                    _pushUndo();
                    setState(() {
                      final idRemap = <String, String>{};
                      for (final n in aiNodes) {
                        final existing = _nodes.indexWhere((e) => e.type == n.type && !idRemap.containsValue(e.id));
                        if (existing >= 0) {
                          _nodes[existing].params.addAll(n.params);
                          idRemap[n.id] = _nodes[existing].id;
                        } else {
                          _nodes.add(n);
                          idRemap[n.id] = n.id;
                        }
                      }
                      final newConns = <PipelineConnection>[];
                      for (final c in aiConns) {
                        final fromId = idRemap[c.fromNodeId] ?? c.fromNodeId;
                        final toId = idRemap[c.toNodeId] ?? c.toNodeId;
                        if (!_connections.any((e) => e.fromNodeId == fromId && e.toNodeId == toId)) {
                          newConns.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId));
                        }
                      }
                      // Remove old connections superseded by new path
                      final remappedConns = aiConns.map((c) => (
                        from: idRemap[c.fromNodeId] ?? c.fromNodeId,
                        to: idRemap[c.toNodeId] ?? c.toNodeId,
                      )).toSet();
                      final aiNodeIds = remappedConns.expand((c) => [c.from, c.to]).toSet();
                      _connections.removeWhere((c) {
                        if (!aiNodeIds.contains(c.fromNodeId) || !aiNodeIds.contains(c.toNodeId)) return false;
                        if (remappedConns.any((r) => r.from == c.fromNodeId && r.to == c.toNodeId)) return false;
                        // Old connection between two AI-touched nodes not in AI graph → remove
                        return true;
                      });
                      _connections.addAll(newConns);
                    });
                  },
                  onModifyNodeParams: (nodeId, params) {
                    _pushUndo();
                    setState(() {
                      final node = _nodes.firstWhere((n) => n.id == nodeId, orElse: () => _nodes.first);
                      params.forEach((k, v) { node.params[k] = v; });
                    });
                    _saveGraph();
                  },
                  onClearAll: () {
                    _pushUndo();
                    setState(() {
                      _nodes.clear();
                      _connections.clear();
                      _logicBlocks.clear();
                      _selectedNodeIds.clear();
                      _saveGraph();
                    });
                  },
                  onUndo: _undo,
                  onRedo: _redo,
                  onSave: _saveGraph,
                ),
              ),
          ]),
        ),
      )),
    ]);

    return _glassWrap(inner, scheme);
  }

  // ── 节点 Widget ──

  Offset _canvasFromGlobal(Offset global) {
    final rb = context.findRenderObject() as RenderBox;
    return _screenToCanvas(rb.globalToLocal(global));
  }

  void _onPortDragStart(String nodeId, bool isOutput) {
    setState(() {
      _dragFromNodeId = nodeId;
      _dragIsOutput = isOutput;
    });
  }

  void _onPortDragUpdate(Offset globalPos) {
    setState(() => _dragLineEnd = _canvasFromGlobal(globalPos));
  }

  void _onPortDragEnd() {
    if (_dragFromNodeId != null && _dragLineEnd != null) {
      final target = _findNodeAtCanvasPos(_dragLineEnd!);
      if (target != null && target.id != _dragFromNodeId) {
        if (_dragIsOutput) {
          _addConnection(_dragFromNodeId!, target.id);
        } else {
          _addConnection(target.id, _dragFromNodeId!);
        }
      }
    }
    setState(() {
      _dragFromNodeId = null;
      _dragLineEnd = null;
    });
  }

  Widget _buildNodeWidget(PipelineNode node, ColorScheme scheme, AppStrings s) {
    final selected = _selectedNodeIds.contains(node.id);

    Widget portZone(bool isOutput) {
      final hasPort = isOutput ? node.hasOutput : node.hasInput;
      return Listener(
        onPointerDown: (_) {},
        behavior: HitTestBehavior.opaque,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: hasPort ? (_) => _onPortDragStart(node.id, isOutput) : null,
          onPanUpdate: hasPort ? (d) => _onPortDragUpdate(d.globalPosition) : null,
          onPanEnd: hasPort ? (_) => _onPortDragEnd() : null,
          child: SizedBox(
            width: _portZoneW,
            height: _nodeH,
            child: Center(child: Container(
              width: 12, height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasPort
                    ? (isOutput ? scheme.primary : scheme.secondary)
                    : Colors.transparent,
                border: hasPort
                    ? Border.all(color: scheme.surface, width: 2)
                    : null,
              ),
            )),
          ),
        ),
      );
    }

    Widget centerZone() {
      return Listener(
        onPointerDown: (_) {},
        behavior: HitTestBehavior.opaque,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() {
              _previewedToolboxType = null;
              _previewedLogicType = null;
              _selectedLogicBlockId = null;
              if (_isCtrlPressed()) {
                // Ctrl+click: toggle in/out of selection
                if (_selectedNodeIds.contains(node.id)) {
                  _selectedNodeIds.remove(node.id);
                  _lastSelectedId = _selectedNodeIds.isEmpty ? null : _selectedNodeIds.last;
                } else {
                  _selectedNodeIds.add(node.id);
                  _lastSelectedId = node.id;
                }
              } else {
                // Single click: select only this node
                _selectedNodeIds.clear();
                _selectedNodeIds.add(node.id);
                _lastSelectedId = node.id;
              }
            });
          },
          onPanStart: (_) => _pushUndo(),
          onPanUpdate: (d) {
            final scale = _transformCtrl.value.getMaxScaleOnAxis();
            final dx = d.delta.dx / scale;
            final dy = d.delta.dy / scale;
            setState(() {
              if (_selectedNodeIds.contains(node.id)) {
                // Move all selected nodes together
                for (final n in _nodes) {
                  if (_selectedNodeIds.contains(n.id)) {
                    n.x += dx;
                    n.y += dy;
                  }
                }
              } else {
                // Dragging an unselected node: move only it
                node.x += dx;
                node.y += dy;
              }
            });
          },
          onSecondaryTapUp: (d) => _showNodeMenu(d.globalPosition, node.id),
          child: Container(
            width: _nodeWFor(node.type),
            height: _nodeH,
            decoration: BoxDecoration(
              color: _nodeColor(node.type, scheme, customColor: node.params['node_color'] as int?),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant.withAlpha(100),
                width: selected ? 2 : 1,
              ),
              boxShadow: [BoxShadow(color: scheme.shadow.withAlpha(30), blurRadius: 6, offset: const Offset(0, 2))],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _currentScale >= 0.6
                ? Stack(children: [
                    Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(_stepIcon(node.type), size: 17, color: selected ? scheme.primary : scheme.onSurface),
                        const SizedBox(width: 5),
                        Expanded(child: Text(
                          s.isZh ? node.label : node.labelEn,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: scheme.onSurface),
                          overflow: TextOverflow.ellipsis,
                        )),
                      ]),
                      if (node.mediaTag.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 22, top: 2),
                          child: Text(node.mediaTag, style: TextStyle(fontSize: 10, color: scheme.outline, fontWeight: FontWeight.w600)),
                        ),
                    ]),
                    if ((node.params['node_name'] as String? ?? '').isNotEmpty)
                      Positioned(
                        right: 0, bottom: 2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.primary.withAlpha(30),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            node.params['node_name'] as String,
                            style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ])
                : Center(child: Text(
                    s.isZh ? node.label : node.labelEn,
                    style: TextStyle(
                      fontSize: _currentScale < 0.4 ? (13 / _currentScale * 0.5).clamp(13.0, 40.0) : (13 / _currentScale * 0.7).clamp(13.0, 28.0),
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  )),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        portZone(false),
        centerZone(),
        portZone(true),
      ],
    );
  }

  PipelineNode? _findNodeAtCanvasPos(Offset pos) {
    for (final n in _nodes) {
      if (pos.dx >= n.x && pos.dx <= n.x + _totalNodeWFor(n.type) && pos.dy >= n.y && pos.dy <= n.y + _nodeH) {
        return n;
      }
    }
    return null;
  }

  // ── 右侧面板 ──

  Widget _buildLogicBlockOverlay(LogicBlock block, ColorScheme scheme, AppStrings s) {
    final selected = _selectedLogicBlockId == block.id;
    return SizedBox(
      width: block.width,
      height: block.height,
      child: Stack(clipBehavior: Clip.none, children: [
        // Dashed border — pass hits through
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _LogicBlockPainter(
                color: selected ? Colors.red : Colors.red.withAlpha(120),
                strokeWidth: selected ? 2.0 : 1.0,
              ),
            ),
          ),
        ),
        // Label at top-left — clickable
        Positioned(
          left: 8, top: 4,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                _selectedLogicBlockId = block.id;
                _selectedNodeIds.clear();
                _lastSelectedId = null;
                _previewedToolboxType = null;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(selected ? 50 : 30),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(block.type == LogicBlockType.loop ? Icons.repeat : Icons.shuffle, size: 12, color: Colors.red),
                const SizedBox(width: 4),
                Text(block.label(s.isZh), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.red)),
              ]),
            ),
          ),
        ),
        // Edit + Delete icons at top-right — clickable
        Positioned(
          right: 8, top: 4,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _logicIconBtn(Icons.edit_outlined, () {
              setState(() {
                _selectedLogicBlockId = block.id;
                _selectedNodeIds.clear();
                _lastSelectedId = null;
                _previewedToolboxType = null;
              });
            }),
            const SizedBox(width: 2),
            _logicIconBtn(Icons.close, () {
              _pushUndo();
              setState(() {
                if (_selectedLogicBlockId == block.id) _selectedLogicBlockId = null;
              });
            }),
          ]),
        ),
        // Ports — visual only
        Positioned(left: -6, top: block.height / 2 - 6, child: IgnorePointer(child: _logicPort(scheme))),
        Positioned(right: -6, top: block.height / 2 - 6, child: IgnorePointer(child: _logicPort(scheme))),
      ]),
    );
  }

  Widget _logicIconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 20, height: 20,
        decoration: BoxDecoration(
          color: Colors.red.withAlpha(30),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 12, color: Colors.red),
      ),
    );
  }

  Widget _logicPort(ColorScheme scheme) {
    return Container(
      width: 12, height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.red.withAlpha(180),
        border: Border.all(color: scheme.surface, width: 2),
      ),
    );
  }


  Widget _buildRightPanel(ColorScheme scheme, AppStrings s) {
    final node = _selectedNode;
    final previewType = _previewedToolboxType;
    final showPreview = node == null && previewType != null;

    // Determine what to show in properties
    final logicBlock = _selectedLogicBlockId != null
        ? _logicBlocks.where((b) => b.id == _selectedLogicBlockId).firstOrNull
        : null;

    Widget inner = LayoutBuilder(builder: (ctx, constraints) {
      final totalH = constraints.maxHeight;
      const dividerH = 6.0;
      final usable = totalH - dividerH;
      final toolboxH = usable * _toolboxFraction;
      final editorH = usable * (1 - _toolboxFraction);

      return Column(children: [
        // ── 元素工具栏 ──
        SizedBox(height: toolboxH, child: Column(children: [
          _buildCollapsibleHeader(
            scheme: scheme,
            icon: Icons.widgets_outlined,
            title: s.isZh ? '元素' : 'Elements',
            expanded: _toolboxExpanded,
            onToggle: () => setState(() => _toolboxExpanded = !_toolboxExpanded),
            trailing: Text('${_allNodeTypes.length}', style: TextStyle(fontSize: 10, color: scheme.outline)),
          ),
          if (_toolboxExpanded)
            Expanded(child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 4, runSpacing: 4, children: [
                  _buildToolboxItem(PipelineStepType.start, scheme, s),
                  _buildToolboxItem(PipelineStepType.output, scheme, s),
                ]),
                const SizedBox(height: 8),
                _categoryLabel(scheme, Icons.videocam_outlined, s.isZh ? '视频' : 'Video'),
                const SizedBox(height: 4),
                Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final t in _videoTypes) _buildToolboxItem(t, scheme, s),
                ]),
                const SizedBox(height: 8),
                _categoryLabel(scheme, Icons.audiotrack_outlined, s.isZh ? '音频' : 'Audio'),
                const SizedBox(height: 4),
                Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final t in _audioTypes) _buildToolboxItem(t, scheme, s),
                ]),
                const SizedBox(height: 8),
                _categoryLabel(scheme, Icons.image_outlined, s.isZh ? '图片' : 'Image'),
                const SizedBox(height: 4),
                Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final t in _imageTypes) _buildToolboxItem(t, scheme, s),
                ]),
                const SizedBox(height: 8),
                _categoryLabel(scheme, Icons.account_tree_outlined, s.isZh ? '逻辑' : 'Logic'),
                const SizedBox(height: 4),
                Wrap(spacing: 4, runSpacing: 4, children: [
                  _buildLogicToolboxItem(LogicBlockType.loop, scheme, s),
                  _buildLogicToolboxItem(LogicBlockType.selectiveLoop, scheme, s),
                ]),
                if (widget.containerInfo != null) ...[
                  const SizedBox(height: 8),
                  _categoryLabel(scheme, Icons.folder_special_outlined, s.isZh ? '容器' : 'Container'),
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final t in _containerTypes) _buildToolboxItem(t, scheme, s),
                  ]),
                ],
              ]),
            )),
        ])),

        // ── 可拖动分割线 ──
        MouseRegion(
          cursor: SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) => setState(() {
              _toolboxFraction = ((_toolboxFraction * usable + d.delta.dy) / usable).clamp(0.15, 0.85);
            }),
            child: Container(
              height: dividerH,
              color: Colors.transparent,
              child: Center(child: Container(
                width: 32, height: 3,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant.withAlpha(80),
                  borderRadius: BorderRadius.circular(2),
                ),
              )),
            ),
          ),
        ),

        // ── 属性编辑器 ──
        SizedBox(height: editorH, child: Column(children: [
          _buildCollapsibleHeader(
            scheme: scheme,
            icon: logicBlock != null
                ? (logicBlock.type == LogicBlockType.loop ? Icons.repeat : Icons.shuffle)
                : node != null ? _stepIcon(node.type) : (showPreview ? _stepIcon(previewType) : Icons.tune_outlined),
            title: logicBlock != null
                ? logicBlock.label(s.isZh)
                : node != null
                    ? (s.isZh ? node.label : node.labelEn)
                    : showPreview
                        ? (s.isZh ? PipelineNode(id: '', type: previewType).label : PipelineNode(id: '', type: previewType).labelEn)
                        : (s.isZh ? '属性' : 'Properties'),
            expanded: _editorExpanded,
            onToggle: () => setState(() => _editorExpanded = !_editorExpanded),
          ),
          if (_editorExpanded)
            Expanded(child: logicBlock != null
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(4),
                    child: LogicBlockEditor(
                      key: ValueKey(logicBlock.id),
                      block: logicBlock,
                      childNodes: _nodes.where((n) => logicBlock.childNodeIds.contains(n.id)).toList(),
                      onChanged: () => setState(() {}),
                      isZh: s.isZh,
                    ),
                  )
                : node != null
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(4),
                    child: _buildStepEditor(node, s.isZh),
                  )
                : showPreview
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(4),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            margin: const EdgeInsets.only(bottom: 8, left: 16, right: 16, top: 8),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer.withAlpha(60),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(children: [
                              Icon(Icons.preview_outlined, size: 14, color: scheme.primary),
                              const SizedBox(width: 6),
                              Text(s.isZh ? '预览 · 双击添加到画布' : 'Preview · double-click to add',
                                  style: TextStyle(fontSize: 11, color: scheme.primary)),
                            ]),
                          ),
                          _buildStepEditor(PipelineNode(id: '__preview__', type: previewType), s.isZh),
                        ]),
                      )
                    : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.touch_app_outlined, size: 32, color: scheme.outline.withAlpha(80)),
                        const SizedBox(height: 8),
                        Text(s.isZh ? '选择节点开始编辑' : 'Select a node to edit',
                            style: TextStyle(color: scheme.outline, fontSize: 12)),
                      ])),
            ),
        ])),
      ]);
    });

    return _glassWrap(inner, scheme);
  }

  Widget _buildCollapsibleHeader({
    required ColorScheme scheme, required IconData icon, required String title,
    required bool expanded, required VoidCallback onToggle, Widget? trailing,
  }) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Icon(icon, size: 15, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface))),
          if (trailing != null) ...[trailing, const SizedBox(width: 6)],
          AnimatedRotation(
            turns: expanded ? 0.0 : 0.5,
            duration: const Duration(milliseconds: 200),
            child: Icon(Icons.expand_less, size: 16, color: scheme.outline),
          ),
        ]),
      ),
    );
  }

  Widget _buildToolboxItem(PipelineStepType t, ColorScheme scheme, AppStrings s) {
    final dummy = PipelineNode(id: '', type: t);
    final tag = dummy.mediaTag;
    return Draggable<PipelineStepType>(
      data: t,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: _nodeColor(t, scheme), borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_stepIcon(t), size: 14, color: scheme.onSurface),
            const SizedBox(width: 4),
            Text(s.isZh ? dummy.label : dummy.labelEn, style: TextStyle(fontSize: 11, color: scheme.onSurface, decoration: TextDecoration.none)),
          ]),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: _toolboxChip(t, dummy, tag, scheme, s)),
      child: GestureDetector(
        onTap: () {
          setState(() {
            _previewedLogicType = null;
            if (_previewedToolboxType == t) {
              _previewedToolboxType = null;
            } else {
              _previewedToolboxType = t;
              _selectedNodeIds.clear();
              _lastSelectedId = null;
              _selectedLogicBlockId = null;
            }
          });
        },
        onDoubleTap: () => _addNodeAtCenter(t),
        child: _toolboxChip(t, dummy, tag, scheme, s, isSelected: _previewedToolboxType == t),
      ),
    );
  }

  Widget _categoryLabel(ColorScheme scheme, IconData icon, String label) {
    return Row(children: [
      Icon(icon, size: 12, color: scheme.outline),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: scheme.outline)),
    ]);
  }

  Widget _buildLogicToolboxItem(LogicBlockType type, ColorScheme scheme, AppStrings s) {
    final label = type == LogicBlockType.loop
        ? (s.isZh ? '循环' : 'Loop')
        : (s.isZh ? '选择性循环' : 'Selective Loop');
    final icon = type == LogicBlockType.loop ? Icons.repeat : Icons.shuffle;
    final isSelected = _previewedLogicType == type;
    return GestureDetector(
      onTap: () {
        setState(() {
          _previewedLogicType = _previewedLogicType == type ? null : type;
          _previewedToolboxType = null;
          _selectedNodeIds.clear();
          _lastSelectedId = null;
          _selectedLogicBlockId = null;
        });
      },
      onDoubleTap: () => _startLogicBoxSelect(type, s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? Colors.red.withAlpha(60) : Colors.red.withAlpha(30),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isSelected ? Colors.red : Colors.red.withAlpha(80), width: isSelected ? 2 : 1),
          boxShadow: isSelected ? [BoxShadow(color: Colors.red.withAlpha(40), blurRadius: 6)] : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: Colors.red),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurface)),
        ]),
      ),
    );
  }

  Widget _toolboxChip(PipelineStepType t, PipelineNode dummy, String tag, ColorScheme scheme, AppStrings s, {bool isSelected = false}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isSelected ? scheme.primary.withAlpha(40) : _nodeColor(t, scheme).withAlpha(180),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isSelected ? scheme.primary : scheme.outlineVariant.withAlpha(60), width: isSelected ? 2 : 1),
        boxShadow: isSelected ? [BoxShadow(color: scheme.primary.withAlpha(40), blurRadius: 6)] : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_stepIcon(t), size: 14, color: scheme.onSurface),
        const SizedBox(width: 4),
        Text(s.isZh ? dummy.label : dummy.labelEn, style: TextStyle(fontSize: 12, color: scheme.onSurface)),
        if (tag.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(tag, style: TextStyle(fontSize: 9, color: scheme.outline, fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }

  // ── 画布浮动控件 ──

  Widget _buildCanvasControls(ColorScheme scheme, AppStrings s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withAlpha(200),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
        boxShadow: [BoxShadow(color: scheme.shadow.withAlpha(20), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _controlBtn(Icons.zoom_in, s.isZh ? '放大' : 'Zoom in', scheme, () => _zoomTo(_currentScale + 0.15)),
        const SizedBox(height: 2),
        SizedBox(
          height: 100,
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: scheme.primary,
                inactiveTrackColor: scheme.outlineVariant.withAlpha(80),
                thumbColor: scheme.primary,
              ),
              child: Slider(
                value: _currentScale.clamp(0.3, 2.0),
                min: 0.3,
                max: 2.0,
                onChanged: (v) => _zoomTo(v),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        _controlBtn(Icons.zoom_out, s.isZh ? '缩小' : 'Zoom out', scheme, () => _zoomTo(_currentScale - 0.15)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Divider(height: 1, color: scheme.outlineVariant.withAlpha(60)),
        ),
        _controlBtn(Icons.auto_fix_high, s.isZh ? '整理' : 'Arrange', scheme, _autoLayout),
        const SizedBox(height: 2),
        _controlBtn(Icons.my_location, s.isZh ? '定位源' : 'Source', scheme, () => _goToSource(s)),
      ]),
    );
  }

  Widget _controlBtn(IconData icon, String tooltip, ColorScheme scheme, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  // ── 底栏 ──

  Widget _buildBottomBar(ColorScheme scheme, AppStrings s) {
    final v = widget.video;
    final srcCount = _nodes.where((n) => n.type == PipelineStepType.start).length;
    final outCount = _nodes.where((n) => n.type == PipelineStepType.output).length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant.withAlpha(50)))),
      child: Row(children: [
        Icon(Icons.info_outline, size: 14, color: scheme.outline),
        const SizedBox(width: 6),
        Text('${v.resolution}  |  ${v.durationStr}  |  ${formatFileSize(v.sizeMb)}',
            style: TextStyle(color: scheme.outline, fontSize: 12)),
        const Spacer(),
        Text(
          s.isZh ? '${_nodes.length} 节点  |  $srcCount 源  |  $outCount 输出  |  ${_connections.length} 连线'
              : '${_nodes.length} nodes  |  $srcCount src  |  $outCount out  |  ${_connections.length} links',
          style: TextStyle(color: scheme.outline, fontSize: 11)),
      ]),
    );
  }
}

// ── 网格背景 ──

class _GridPainter extends CustomPainter {
  final Color color;
  _GridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 0.5;
    const step = 40.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

// ── 连线绘制 ──

class _ConnectionPainter extends CustomPainter {
  final List<PipelineNode> nodes;
  final List<PipelineConnection> connections;
  final Color color;
  final Set<String> selectedNodeIds;

  _ConnectionPainter({required this.nodes, required this.connections, required this.color, required this.selectedNodeIds});

  @override
  void paint(Canvas canvas, Size size) {
    for (final conn in connections) {
      final fromIdx = nodes.indexWhere((n) => n.id == conn.fromNodeId);
      final toIdx = nodes.indexWhere((n) => n.id == conn.toNodeId);
      if (fromIdx < 0 || toIdx < 0) continue;

      final from = nodes[fromIdx];
      final to = nodes[toIdx];

      final p1 = Offset(from.x + _portZoneW + _nodeWFor(from.type) + _portZoneW / 2, from.y + _nodeH / 2);
      final p2 = Offset(to.x + _portZoneW / 2, to.y + _nodeH / 2);
      final dx = (p2.dx - p1.dx).abs() * 0.5;

      final highlighted = selectedNodeIds.contains(conn.fromNodeId) || selectedNodeIds.contains(conn.toNodeId);
      final paint = Paint()
        ..color = highlighted ? color : color.withAlpha(80)
        ..strokeWidth = highlighted ? 2.5 : 1.5
        ..style = PaintingStyle.stroke;

      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..cubicTo(p1.dx + dx, p1.dy, p2.dx - dx, p2.dy, p2.dx, p2.dy);
      canvas.drawPath(path, paint);

      // 箭头
      final arrowPaint = Paint()..color = paint.color..style = PaintingStyle.fill;
      final dir = (p2 - Offset(p2.dx - 10, p2.dy)).direction;
      final a1 = Offset(p2.dx - 8 * math.cos(dir - 0.4), p2.dy - 8 * math.sin(dir - 0.4));
      final a2 = Offset(p2.dx - 8 * math.cos(dir + 0.4), p2.dy - 8 * math.sin(dir + 0.4));
      canvas.drawPath(Path()..moveTo(p2.dx, p2.dy)..lineTo(a1.dx, a1.dy)..lineTo(a2.dx, a2.dy)..close(), arrowPaint);
    }
  }

  @override
  bool shouldRepaint(_ConnectionPainter old) => true;
}

// ── 临时拖拽连线 ──

class _TempLinePainter extends CustomPainter {
  final Offset from, to;
  final Color color;
  _TempLinePainter({required this.from, required this.to, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final dx = (to.dx - from.dx).abs() * 0.5;
    final paint = Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(from.dx, from.dy)
      ..cubicTo(from.dx + dx, from.dy, to.dx - dx, to.dy, to.dx, to.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TempLinePainter old) => old.from != from || old.to != to;
}

// ── 框选绘制 ──

class _LogicBlockPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  _LogicBlockPainter({required this.color, this.strokeWidth = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(8),
    );

    final path = Path()..addRRect(rect);
    const dashLen = 8.0;
    const gapLen = 4.0;

    for (final metric in path.computeMetrics()) {
      double drawn = 0;
      while (drawn < metric.length) {
        final start = drawn;
        final end = (drawn + dashLen).clamp(0, metric.length);
        canvas.drawPath(metric.extractPath(start, end.toDouble()), paint);
        drawn += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_LogicBlockPainter old) => old.color != color || old.strokeWidth != strokeWidth;
}

class _BoxSelectPainter extends CustomPainter {
  final Rect rect;
  final Color color;
  _BoxSelectPainter({required this.rect, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Semi-transparent fill
    final fillPaint = Paint()
      ..color = color.withAlpha(25)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, fillPaint);

    // Dashed border
    final borderPaint = Paint()
      ..color = color.withAlpha(140)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const dashLen = 6.0;
    const gapLen = 4.0;

    void drawDashedLine(Offset start, Offset end) {
      final d = end - start;
      final len = d.distance;
      if (len == 0) return;
      final dir = d / len;
      var drawn = 0.0;
      while (drawn < len) {
        final segEnd = (drawn + dashLen).clamp(0.0, len);
        canvas.drawLine(
          start + dir * drawn,
          start + dir * segEnd,
          borderPaint,
        );
        drawn += dashLen + gapLen;
      }
    }

    drawDashedLine(rect.topLeft, rect.topRight);
    drawDashedLine(rect.topRight, rect.bottomRight);
    drawDashedLine(rect.bottomRight, rect.bottomLeft);
    drawDashedLine(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(_BoxSelectPainter old) => old.rect != rect || old.color != color;
}

class _EditorCsdBtn extends StatefulWidget {
  final IconData icon;
  final Color color;
  final Color? hoverBg;
  final VoidCallback onTap;
  const _EditorCsdBtn({required this.icon, required this.color, this.hoverBg, required this.onTap});
  @override
  State<_EditorCsdBtn> createState() => _EditorCsdBtnState();
}

class _EditorCsdBtnState extends State<_EditorCsdBtn> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 36,
          color: _hovering
              ? (widget.hoverBg ?? widget.color.withAlpha(30))
              : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 18,
            color: _hovering && widget.hoverBg != null ? Colors.white : widget.color,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════
// AI Chat Dialog
// ═══════════════════════════════════════════

class _AiPanel extends StatefulWidget {
  final AppStrings strings;
  final List<PipelineNode> existingNodes;
  final List<PipelineConnection> existingConnections;
  final void Function(List<PipelineNode>, List<PipelineConnection>) onApplyGraph;
  final void Function(List<PipelineNode>, List<PipelineConnection>) onMergeGraph;
  final void Function(String nodeId, Map<String, String> params) onModifyNodeParams;
  final VoidCallback onClearAll;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onSave;
  const _AiPanel({required this.strings, required this.existingNodes, required this.existingConnections, required this.onApplyGraph, required this.onMergeGraph, required this.onModifyNodeParams, required this.onClearAll, required this.onUndo, required this.onRedo, required this.onSave});
  @override
  State<_AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<_AiPanel> {
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<({String role, String content, int? inputTokens, int? outputTokens, List<Map<String, dynamic>>? blocks})> _messages = [];
  bool _loading = false;
  bool _expanded = false;
  List<PipelineNode>? _pendingNodes;
  List<PipelineConnection>? _pendingConnections;
  bool _pendingIsModify = false;

  static const _uuid = Uuid();

  static const _systemPrompt = '''You are an AI assistant for FFmpeg++ node editor.
When the user describes media processing they want, respond with a JSON pipeline graph.

Available node types (PipelineStepType):
- start: Input source node (always first, no params needed)
- avProcess: Video/audio encoding settings
    video_codec: libx264|libx265|libvpx-vp9|libaom-av1|libsvtav1|copy
    gpu: CPU|NVIDIA|AMD|Intel
    preset: ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow
    rate_mode: keep|crf|bitrate (MUST set to "crf" or "bitrate" for crf/video_bitrate to take effect)
    crf: 0-51 (only used when rate_mode="crf")
    video_bitrate: integer kbps (only used when rate_mode="bitrate")
    resolution: original|2160p|1080p|720p|480p|360p|custom
    resolution_w, resolution_h: integers (only when resolution="custom")
    fps: keep|24|25|30|48|50|60|120|custom
    fps_value: number (only when fps="custom")
    audio_codec: aac|libmp3lame|libopus|libvorbis|flac|pcm_s16le|ac3|eac3|copy
    audio_bitrate: integer kbps
    audio_channels: keep|1|2|6|8
    pix_fmt: auto|yuv420p|yuv422p|yuv444p|yuv420p10le|yuv422p10le|nv12|p010le|rgb24
- subtitle: Burn subtitles
    source: external|embedded
    subtitle_file: path (when source=external)
    subtitle_index: integer (when source=embedded)
    font_name, font_size, font_color, outline_width, outline_color
- clip: Trim/cut video (start_time: seconds, end_time: seconds)
- frame: Extract frames
    extract_mode: single|range|all
    time: seconds (when single)
    range_start, range_end: seconds (when range)
    fps_rate: number (frames per second for range/all)
    output_format: png|jpg|bmp|webp
- speed: Change playback speed (speed: 0.25-4.0, or custom_speed: true + custom_speed_value: number for >4x)
- imageConvert: Convert image format (output_format: png|jpg|webp|bmp|tiff, quality: 0-100)
- audioConvert: Convert audio format (audio_codec: aac|libmp3lame|libopus|libvorbis|flac, output_format: m4a|mp3|ogg|flac|wav)
- audioQuality: Audio quality settings (bitrate_mode: keep|custom, audio_bitrate: integer, sample_rate: keep|22050|44100|48000|96000)
- audioSpeed: Audio speed change (atempo: 0.5-2.0)
- audioVolume: Audio volume adjust (volume_db: -30.0 to +30.0 dB)
- audioCompressor: Audio compressor (threshold, ratio, attack, release, makeup, knee)
- audioMetadata: Edit audio metadata (title, artist, album, cover_path, lyrics_path)
- concatMedia: Concatenate media files (mode: copy|reencode, order_mode: index|name)
- imageToVideo: Image sequence to video (framerate: number, output_format: mp4|avi|mkv, video_codec: h264|h265)
- imageCrop: Crop image (crop_x, crop_y, crop_w, crop_h: integers)
- imageRotate: Rotate image (angle: degrees)
- imageScale: Scale image (scale_mode: factor, scale_factor: number)
- imageBrightness: Adjust brightness (brightness: -1.0 to 1.0)
- imageNoise: Add noise to image (noise_strength: integer, noise_type: u|g)
- imageSharpen: Sharpen image (sharpen_strength: 0.0-5.0)
- imageDenoise: Denoise image (denoise_method: nlmeans|hqdn3d, denoise_strength: number)
- imageChannelExtract: Extract color channel (channel: r|g|b, extract_method: colorize|grayscale)
- output: Output node (always last)
    format: keep|mp4|mkv|avi|mov|webm|flv|ts|m4a|mp3|ogg|flac|wav|png|jpg|webp|bmp
    naming_mode: keep|suffix|custom
    naming_value: string (suffix or custom name)
    output_dir: path

Respond with a brief explanation, then a JSON block in this exact format:
```json
{
  "nodes": [
    {"id": "n1", "type": "start", "x": 2900, "y": 3000, "params": {}},
    {"id": "n2", "type": "avProcess", "x": 3150, "y": 3000, "params": {"video_codec": "libx264", "rate_mode": "crf", "crf": 23}},
    {"id": "n3", "type": "output", "x": 3400, "y": 3000, "params": {}}
  ],
  "connections": [
    {"from": "n1", "to": "n2"},
    {"from": "n2", "to": "n3"}
  ]
}
```

Rules:
- Always start with a "start" node and end with an "output" node
- Space nodes horizontally ~250px apart, starting around x=2900, y=3000
- For parallel branches, offset y by ~120px
- Use the simplest pipeline that achieves the goal
- Only include relevant params, omit defaults

You also have these tools you can invoke by including the exact marker in your response:
- [TOOL_CALL:clear_all] — Clear all nodes, connections, and logic blocks from the canvas
- [TOOL_CALL:undo] — Undo the last action on the canvas
- [TOOL_CALL:redo] — Redo the last undone action
- [TOOL_CALL:save] — Save the current pipeline (only if already saved before, no Save As)
- [TOOL_CALL:error_check] — Check the current pipeline for logical errors (missing start/output, disconnected nodes, etc.)
- [TOOL_CALL:ask_user|Your question here|option1,option2,option3] — Ask the user a question with clickable options
- [TOOL_CALL:list_directory|/path/to/dir] — List files in a directory (read-only, max 50 entries)
- [TOOL_CALL:read_file_info|/path/to/file] — Get file metadata: size, modified time, type (read-only)
- [TOOL_CALL:modify_node|nodeId|paramKey=value,paramKey2=value2] — Modify params of an existing canvas node

Graph generation modes:
- Default (Replace): your JSON graph replaces the entire canvas
- Include [MODE:modify] in your response to merge with existing canvas instead of replacing

When the user asks to clear/reset the canvas, undo, redo, or save, include the appropriate marker.
The current canvas state is provided below the conversation automatically.''';

  void _handleToolCalls(String content) {
    final cfg = context.read<AppState>().config;
    final calls = RegExp(r'\[TOOL_CALL:([^\]]+)\]').allMatches(content);
    for (final m in calls) {
      final parts = m.group(1)!.split('|');
      final tool = parts[0];
      switch (tool) {
        case 'clear_all': if (cfg.aiAutoExecute) widget.onClearAll();
        case 'undo': if (cfg.aiAutoExecute) widget.onUndo();
        case 'redo': if (cfg.aiAutoExecute) widget.onRedo();
        case 'save': if (cfg.aiAutoExecute) widget.onSave();
        case 'error_check': if (cfg.aiAutoExecute) _executeErrorCheck();
        case 'ask_user':
          if (cfg.aiAutoExecute && parts.length >= 3) _showAskUser(parts[1], parts[2].split(','));
        case 'list_directory':
          if (cfg.aiReadAccess && parts.length >= 2) _executeListDir(parts[1]);
        case 'read_file_info':
          if (cfg.aiReadAccess && parts.length >= 2) _executeReadFileInfo(parts[1]);
        case 'modify_node':
          if (cfg.aiWriteAccess && parts.length >= 3) {
            final params = <String, String>{};
            for (final p in parts[2].split(',')) {
              final kv = p.split('=');
              if (kv.length == 2) params[kv[0].trim()] = kv[1].trim();
            }
            widget.onModifyNodeParams(parts[1], params);
          }
      }
    }
  }

  void _addToolResult(String toolName, String result) {
    setState(() {
      _messages.add((role: 'assistant', content: '[$toolName] $result',
        inputTokens: null, outputTokens: null,
        blocks: [{'type': 'tool_result', 'name': toolName, 'content': result}]));
    });
    _scrollToBottom();
  }

  void _executeErrorCheck() {
    final nodes = widget.existingNodes;
    final conns = widget.existingConnections;
    final errors = <String>[];
    if (!nodes.any((n) => n.type == PipelineStepType.start)) errors.add('Missing start node');
    if (!nodes.any((n) => n.type == PipelineStepType.output)) errors.add('Missing output node');
    final connectedIds = <String>{};
    for (final c in conns) { connectedIds.add(c.fromNodeId); connectedIds.add(c.toNodeId); }
    for (final n in nodes) {
      if (!connectedIds.contains(n.id) && nodes.length > 1) {
        errors.add('Disconnected: ${n.type.name} (${n.id.substring(0, 8)})');
      }
    }
    _addToolResult('error_check', errors.isEmpty ? 'No errors found.' : errors.join('\n'));
  }

  void _executeListDir(String path) {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) { _addToolResult('list_directory', 'Directory not found: $path'); return; }
      final entries = dir.listSync().take(50).map((e) {
        final stat = e.statSync();
        final isDir = stat.type == FileSystemEntityType.directory;
        return '${isDir ? "[DIR] " : ""}${e.path.split('/').last}  ${isDir ? "" : "${(stat.size / 1024).toStringAsFixed(1)}KB"}';
      }).join('\n');
      _addToolResult('list_directory', entries.isEmpty ? '(empty)' : entries);
    } catch (e) { _addToolResult('list_directory', 'Error: $e'); }
  }

  void _executeReadFileInfo(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) { _addToolResult('read_file_info', 'File not found: $path'); return; }
      final stat = file.statSync();
      _addToolResult('read_file_info', 'Path: $path\nSize: ${(stat.size / (1024 * 1024)).toStringAsFixed(2)} MB\nModified: ${stat.modified}\nType: ${path.split('.').last}');
    } catch (e) { _addToolResult('read_file_info', 'Error: $e'); }
  }

  void _showAskUser(String question, List<String> options) {
    setState(() {
      _messages.add((role: 'assistant', content: '[ASK_USER]$question|${options.join(",")}',
        inputTokens: null, outputTokens: null, blocks: null));
    });
    _scrollToBottom();
  }

  @override
  void dispose() { _ctrl.dispose(); _scrollCtrl.dispose(); super.dispose(); }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  /// Resolve the actual chat endpoint from a user-entered URL.
  /// Accepts bare base URLs and appends the correct path per provider.
  static String _resolveEndpoint(String url, bool isAnthropic) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    // Already a full endpoint — use as-is.
    if (u.endsWith('/chat/completions') || u.endsWith('/messages')) return u;
    if (isAnthropic) {
      // Anthropic Messages API: POST <base>/v1/messages
      return u.endsWith('/v1') ? '$u/messages' : '$u/v1/messages';
    }
    // OpenAI-compatible: POST <base>/chat/completions
    // (works for OpenAI's .../v1 base and DeepSeek's bare base)
    return '$u/chat/completions';
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _loading) return;

    final appState = context.read<AppState>();
    final cfg = appState.config;
    if (cfg.aiApiKey.isEmpty) {
      showToast(context, widget.strings.aiNotConfigured, type: ToastType.warning);
      return;
    }
    appState.logAiRequest(text);

    setState(() {
      _messages.add((role: 'user', content: text, inputTokens: null, outputTokens: null, blocks: null));
      _ctrl.clear();
      _loading = true;
      _pendingNodes = null;
      _pendingConnections = null;
    });
    _scrollToBottom();

    try {
      final isAnthropic = cfg.aiProvider == 'anthropic';
      final uri = Uri.parse(_resolveEndpoint(cfg.aiApiUrl, isAnthropic));
      final canvasJson = jsonEncode({
        'nodes': widget.existingNodes.map((n) => n.toJson()).toList(),
        'connections': widget.existingConnections.map((c) => c.toJson()).toList(),
      });
      final fullPrompt = '$_systemPrompt\n\nCurrent canvas state:\n$canvasJson';

      final headers = <String, String>{'Content-Type': 'application/json'};
      Map<String, dynamic> reqBody;

      if (isAnthropic) {
        headers['x-api-key'] = cfg.aiApiKey;
        headers['anthropic-version'] = '2023-06-01';
        final userMessages = _messages.map((m) => {'role': m.role, 'content': m.content}).toList();
        reqBody = {
          'model': cfg.aiModel,
          'system': fullPrompt,
          'messages': userMessages,
          'temperature': 0.3,
          'max_tokens': 2000,
          'stream': true,
        };
      } else {
        headers['Authorization'] = 'Bearer ${cfg.aiApiKey}';
        final apiMessages = [
          {'role': 'system', 'content': fullPrompt},
          ..._messages.map((m) => {'role': m.role, 'content': m.content}),
        ];
        reqBody = {'model': cfg.aiModel, 'messages': apiMessages, 'temperature': 0.3, 'max_tokens': 2000, 'stream': true, 'stream_options': {'include_usage': true}};
      }

      final request = http.Request('POST', uri);
      request.headers.addAll(headers);
      request.body = jsonEncode(reqBody);
      final client = http.Client();
      final streamed = await client.send(request);

      if (streamed.statusCode != 200) {
        final respBody = await streamed.stream.bytesToString();
        final errMsg = 'Error: ${streamed.statusCode} ${respBody.length > 200 ? respBody.substring(0, 200) : respBody}';
        appState.logAiResponse(errMsg, error: true);
        setState(() {
          _messages.add((role: 'assistant', content: errMsg, inputTokens: null, outputTokens: null, blocks: null));
          _loading = false;
        });
        _scrollToBottom();
        client.close();
        return;
      }

      // Add placeholder assistant message for streaming
      setState(() {
        _messages.add((role: 'assistant', content: '', inputTokens: null, outputTokens: null, blocks: null));
      });
      final msgIdx = _messages.length - 1;
      final buf = StringBuffer();
      int? inTok, outTok;
      String lineBuf = '';

      await for (final chunk in streamed.stream.transform(utf8.decoder)) {
        lineBuf += chunk;
        final lines = lineBuf.split('\n');
        lineBuf = lines.removeLast(); // keep incomplete line

        for (final line in lines) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6).trim();
          if (data == '[DONE]') continue;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            if (isAnthropic) {
              final type = json['type'] as String? ?? '';
              if (type == 'content_block_delta') {
                final delta = json['delta'] as Map<String, dynamic>? ?? {};
                if (delta['type'] == 'text_delta') buf.write(delta['text'] ?? '');
              } else if (type == 'message_delta') {
                final usage = json['usage'] as Map<String, dynamic>? ?? {};
                outTok = usage['output_tokens'] as int?;
              } else if (type == 'message_start') {
                final msg = json['message'] as Map<String, dynamic>? ?? {};
                final usage = msg['usage'] as Map<String, dynamic>? ?? {};
                inTok = usage['input_tokens'] as int?;
              }
            } else {
              // OpenAI-compatible
              final choices = json['choices'] as List? ?? [];
              if (choices.isNotEmpty) {
                final delta = choices[0]['delta'] as Map<String, dynamic>? ?? {};
                if (delta.containsKey('content') && delta['content'] != null) buf.write(delta['content']);
              }
              final usage = json['usage'] as Map<String, dynamic>?;
              if (usage != null) {
                inTok = usage['prompt_tokens'] as int? ?? inTok;
                outTok = usage['completion_tokens'] as int? ?? outTok;
              }
            }
            setState(() {
              _messages[msgIdx] = (role: 'assistant', content: buf.toString(), inputTokens: inTok, outputTokens: outTok, blocks: null);
            });
            _scrollToBottom();
          } catch (_) {}
        }
      }

      client.close();
      final content = buf.toString();
      appState.logAiResponse(content);
      setState(() {
        _messages[msgIdx] = (role: 'assistant', content: content, inputTokens: inTok, outputTokens: outTok, blocks: null);
        _loading = false;
      });
      _scrollToBottom();
      _tryParseGraph(content);
      _handleToolCalls(content);
    } catch (e) {
      appState.logAiResponse('$e', error: true);
      setState(() {
        _messages.add((role: 'assistant', content: 'Error: $e', inputTokens: null, outputTokens: null, blocks: null));
        _loading = false;
      });
      _scrollToBottom();
    }
  }

  void _tryParseGraph(String content) {
    final jsonMatch = RegExp(r'```json\s*([\s\S]*?)```').firstMatch(content);
    if (jsonMatch == null) return;
    try {
      final graph = jsonDecode(jsonMatch.group(1)!);
      final nodesList = graph['nodes'] as List;
      final connsList = graph['connections'] as List;
      final idMap = <String, String>{};
      final nodes = <PipelineNode>[];
      final connections = <PipelineConnection>[];

      for (final n in nodesList) {
        final newId = _uuid.v4();
        idMap[n['id'] as String] = newId;
        final typeStr = n['type'] as String;
        final type = PipelineStepType.values.firstWhere((t) => t.name == typeStr, orElse: () => PipelineStepType.avProcess);
        final params = <String, dynamic>{};
        if (n['params'] != null) params.addAll(Map<String, dynamic>.from(n['params']));
        nodes.add(PipelineNode(id: newId, type: type, x: (n['x'] as num).toDouble(), y: (n['y'] as num).toDouble(), params: params));
      }

      for (final c in connsList) {
        final fromId = idMap[c['from'] as String];
        final toId = idMap[c['to'] as String];
        if (fromId != null && toId != null) {
          connections.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId));
        }
      }

      if (nodes.isNotEmpty) {
        final cfg = context.read<AppState>().config;
        final isModify = content.contains('[MODE:modify]') || cfg.aiGraphMode == 'modify';
        if (cfg.aiAutoExecute) {
          context.read<AppState>().logAiGraphApplied(nodes.length, connections.length);
          if (isModify) {
            widget.onMergeGraph(nodes, connections);
          } else {
            widget.onApplyGraph(nodes, connections);
          }
        } else {
          setState(() { _pendingNodes = nodes; _pendingConnections = connections; _pendingIsModify = isModify; });
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      alignment: Alignment.bottomRight,
      child: _expanded ? _buildExpanded(scheme) : _buildCollapsed(scheme),
    );
  }

  Widget _buildCollapsed(ColorScheme scheme) {
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      shadowColor: scheme.shadow.withAlpha(40),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _expanded = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('AI', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
          ]),
        ),
      ),
    );
  }

  Widget _buildExpanded(ColorScheme scheme) {
    final s = widget.strings;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(16),
      elevation: 8,
      shadowColor: scheme.shadow.withAlpha(60),
      child: Container(
        width: 380, height: 480,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
            child: Row(children: [
              Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(s.aiChatTitle, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                tooltip: s.isZh ? '收起' : 'Collapse',
                onPressed: () => setState(() => _expanded = false),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: _messages.isEmpty
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.auto_awesome, size: 44, color: scheme.outline.withAlpha(80)),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(s.aiChatHint, textAlign: TextAlign.center, style: TextStyle(color: scheme.outline, fontSize: 12)),
                ),
              ]))
            : ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (_, i) => _buildMessage(_messages[i], scheme),
              ),
          ),
          if (_pendingNodes != null) Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Expanded(child: FilledButton.icon(
                onPressed: () {
                  context.read<AppState>().logAiGraphApplied(_pendingNodes!.length, _pendingConnections!.length);
                  if (_pendingIsModify) {
                    widget.onMergeGraph(_pendingNodes!, _pendingConnections!);
                  } else {
                    widget.onApplyGraph(_pendingNodes!, _pendingConnections!);
                  }
                  setState(() { _pendingNodes = null; _pendingConnections = null; });
                },
                icon: const Icon(Icons.check, size: 16),
                label: Text(s.isZh ? '批准' : 'Approve'),
              )),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() { _pendingNodes = null; _pendingConnections = null; }),
                icon: const Icon(Icons.close, size: 16),
                label: Text(s.isZh ? '拒绝' : 'Reject'),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(children: [
              Expanded(child: TextField(
                controller: _ctrl,
                style: TextStyle(fontSize: 13, color: scheme.onSurface),
                decoration: InputDecoration(
                  hintText: s.aiChatHint,
                  hintStyle: TextStyle(fontSize: 12, color: scheme.outline),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onSubmitted: (_) => _send(),
                maxLines: 1,
              )),
              const SizedBox(width: 8),
              _loading
                ? const SizedBox(width: 36, height: 36, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(
                    icon: Icon(Icons.send, size: 20, color: scheme.primary),
                    onPressed: _send,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildMessage(({String role, String content, int? inputTokens, int? outputTokens, List<Map<String, dynamic>>? blocks}) msg, ColorScheme scheme) {
    final isUser = msg.role == 'user';
    Widget bodyWidget;
    if (!isUser && msg.content.startsWith('[ASK_USER]')) {
      final raw = msg.content.substring(10);
      final pipe = raw.indexOf('|');
      final question = pipe >= 0 ? raw.substring(0, pipe) : raw;
      final options = pipe >= 0 ? raw.substring(pipe + 1).split(',') : <String>[];
      bodyWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(question, style: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.5)),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: options.map((opt) =>
              ActionChip(
                label: Text(opt.trim(), style: const TextStyle(fontSize: 11)),
                onPressed: () { _ctrl.text = opt.trim(); _send(); },
              ),
            ).toList()),
          ],
        ],
      );
    } else if (!isUser && msg.blocks != null && msg.blocks!.isNotEmpty) {
      bodyWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: msg.blocks!.map((b) => _buildBlock(b, scheme)).toList(),
      );
    } else {
      bodyWidget = isUser
        ? SelectableText(msg.content, style: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.5))
        : MarkdownBody(
            data: msg.content,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.5),
              code: TextStyle(fontSize: 11, color: scheme.primary, backgroundColor: scheme.surfaceContainerHighest),
              codeblockDecoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
              codeblockPadding: const EdgeInsets.all(8),
              blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outline, width: 3))),
            ),
          );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (!isUser) ...[
                CircleAvatar(radius: 14, backgroundColor: scheme.primaryContainer, child: Icon(Icons.auto_awesome, size: 14, color: scheme.primary)),
                const SizedBox(width: 8),
              ],
              Flexible(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: bodyWidget,
              )),
              if (isUser) ...[
                const SizedBox(width: 8),
                CircleAvatar(radius: 14, backgroundColor: scheme.tertiaryContainer, child: Icon(Icons.person, size: 14, color: scheme.tertiary)),
              ],
            ],
          ),
          if (!isUser && msg.inputTokens != null && msg.content.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 2),
              child: Text(
                '${msg.inputTokens}+${msg.outputTokens}=${(msg.inputTokens ?? 0) + (msg.outputTokens ?? 0)} tokens',
                style: TextStyle(fontSize: 9, color: scheme.outline),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBlock(Map<String, dynamic> block, ColorScheme scheme) {
    final type = block['type'] as String? ?? 'text';
    if (type == 'text') {
      return SelectableText(block['text'] as String? ?? '', style: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.5));
    }
    final label = switch (type) {
      'thinking' => 'Thinking',
      'tool_use' => 'Tool: ${block['name'] ?? 'unknown'}',
      'tool_result' => 'Tool Result',
      _ => type,
    };
    final body = switch (type) {
      'thinking' => block['thinking'] as String? ?? '',
      'tool_use' => const JsonEncoder.withIndent('  ').convert(block['input'] ?? {}),
      'tool_result' => block['content']?.toString() ?? '',
      _ => block.toString(),
    };
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        initiallyExpanded: false,
        dense: true,
        title: Text(label, style: TextStyle(fontSize: 11, color: scheme.outline, fontStyle: FontStyle.italic)),
        children: [SelectableText(body, style: TextStyle(fontSize: 11, color: scheme.onSurface.withAlpha(180), height: 1.4))],
      ),
    );
  }
}
