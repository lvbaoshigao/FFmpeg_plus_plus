import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/graph_executor.dart';
import '../services/ffmpeg_installer.dart';
import '../services/ai_chat_history.dart';
import '../services/pipeline_autosave.dart';
import '../theme/app_theme.dart';
import '../theme/app_strings.dart';
import '../platform/app_platform.dart';
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
import '../widgets/step_editors/extract_audio_step_editor.dart';
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
import '../widgets/step_editors/video_crop_step_editor.dart';
import '../widgets/step_editors/logic_block_editor.dart';
import '../widgets/glass_panel.dart';
import '../widgets/toast.dart';
import '../widgets/gate_symbol_painter.dart';

const _uuid = Uuid();

// 缩略图缓存键：FNV-1a 稳定摘要（String.hashCode 跨运行不稳定且 32 位易碰撞）
String _stableThumbHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

const _nodeW = 200.0;
const _nodeWNarrow = 150.0;
const _nodeH = 68.0;
const _canvasSize = 6000.0;
const _portZoneW = 18.0;

double _nodeWFor(PipelineStepType type) =>
    (type == PipelineStepType.start || type == PipelineStepType.output) ? _nodeWNarrow : _nodeW;
double _totalNodeWFor(PipelineStepType type) => _portZoneW + _nodeWFor(type) + _portZoneW;

/// 逻辑门固定尺寸（正方形，标准逻辑符号比例）
const _gateW = 64.0;
const _gateH = 64.0;

/// 单个节点的总宽度（含端口），逻辑门使用固定小尺寸
double _totalNodeWidth(PipelineNode n) => n.isGate ? _gateW + _portZoneW * 2 : _totalNodeWFor(n.type);

/// 单个节点的总高度，逻辑门使用固定小尺寸
double _nodeHeight(PipelineNode n) => n.isGate ? _gateH : _nodeH;

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
  /// 拖拽的起点端口类型：'dataIn'/'dataOut' 数据端口，
  /// 'enableIn' 使能输入端(顶部)，'statusOut' 状态输出端(底部)，
  /// 'gateIn'/'gateOut' 逻辑门输入/输出端口。
  String _dragPort = 'dataOut';
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
  bool _mobileToolboxOpen = false;
  /// 移动端顶部工具栏恒显（右下折叠按钮已移除，工具迁移到顶部栏）。
  final bool _mobileTopBarVisible = true;
  double _toolboxFraction = 0.4;
  // 画布 / 右面板 水平分割比例（默认画布占 60%）
  double _canvasFraction = 0.6;
  // 移动端横竖屏切换（默认竖屏）
  bool _isLandscape = false;
  // AI 侧边面板是否展开（左侧 ">" 按钮）
  bool _aiDrawerOpen = false;
  // 当前 AI 会话标题（对话后自动总结生成）
  String _aiSessionTitle = '';

  // ── 自动保存草稿 ──
  // 稳定 key：容器模式用「容器名 + 文件id 列表」，单文件模式用 video id。
  String _autosaveKey = ''; // 空 = 未启用自动保存（config 模式）
  Timer? _autosaveTimer; // 防抖定时器，避免每次拖动都落盘
  bool _autosaveIndicator = false; // 显示"已自动保存"提示

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

  // 探测模式：悬停端口显示信号值提示
  bool _probeMode = false;
  String? _probeTooltip;
  Offset? _probeTooltipPos;
  // 隐藏逻辑：隐藏控制连线/逻辑门/红色逻辑端口
  bool _hideLogic = false;

  // Undo/redo
  final List<Map<String, dynamic>> _undoStack = [];
  final List<Map<String, dynamic>> _redoStack = [];

  // jsonEncode/jsonDecode 做深拷贝，避免节点 params 是活引用导致 undo 快照被后续参数编辑回溯改写
  Map<String, dynamic> _snapshot() => jsonDecode(jsonEncode(PipelineGraph(nodes: List.of(_nodes), connections: List.of(_connections), logicBlocks: List.of(_logicBlocks)).toJson())) as Map<String, dynamic>;
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
      _lastSelectedId = null;
      _selectedLogicBlockId = null;
    });
  }

  void _saveGraph() {
    final graph = PipelineGraph(nodes: _nodes, connections: _connections, logicBlocks: _logicBlocks);
    widget.onSave(graph);
    context.read<AppState>().setCurrentPipeline(graph);
    // 防抖自动保存草稿：编辑后 1.2s 无新动作才落盘，避免拖动/快速连续操作时频繁写磁盘。
    _scheduleAutosave(graph);
  }

  void _scheduleAutosave(PipelineGraph graph) {
    _autosaveTimer?.cancel();
    if (_autosaveKey.isEmpty) return; // config 模式不自动保存
    final cfg = context.read<AppState>().config;
    if (!cfg.autosaveEnabled) return; // 用户在设置中禁用了自动保存
    _autosaveTimer = Timer(const Duration(milliseconds: 1200), () {
      final g = graph.toJson();
      PipelineAutosave.save(_autosaveKey, g);
      if (!mounted) return;
      // 调试模式：记录自动保存事件
      if (context.read<AppState>().config.debugMode) {
        context.read<AppState>().addLog('[自动保存] 草稿已保存, key: $_autosaveKey', category: 'info');
      }
      setState(() => _autosaveIndicator = true);
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _autosaveIndicator = false);
      });
    });
  }

  /// 标记草稿变更（自动保存草稿而不触发父组件的持久化保存）。
  /// 用于参数编辑、节点拖拽等"非结构变更"操作。
  void _markDirty() {
    final graph = PipelineGraph(nodes: _nodes, connections: _connections, logicBlocks: _logicBlocks);
    _scheduleAutosave(graph);
  }

  /// 仅「显式保存」或「确认放弃」时清除草稿；普通退出（窗口关闭/崩溃）保留草稿供恢复。
  void _clearDraft() {
    _autosaveTimer?.cancel();
    if (_autosaveKey.isNotEmpty) {
      PipelineAutosave.clear(_autosaveKey);
    }
  }

  /// 计算稳定的草稿 key，并在打开编辑器时检测上一份未保存的草稿：
  /// 若存在草稿，则用草稿覆盖当前图并提示「已恢复未保存的草稿」。
  void _setupAutosave(bool isConfigMode) {
    if (isConfigMode) return; // 配置模板模式不做自动保存恢复
    final name = widget.containerInfo?.name;
    if (name != null && name.isNotEmpty) {
      final fileIds = widget.containerInfo?.fileIds ?? const [];
      _autosaveKey = 'container:$name:${fileIds.join(',')}';
    } else {
      _autosaveKey = 'video:${widget.video.id}';
    }
    _tryRestoreDraft();
  }

  Future<void> _tryRestoreDraft() async {
    final draft = await PipelineAutosave.load(_autosaveKey);
    if (!mounted || draft == null) return;
    try {
      final restored = PipelineGraph.fromJson(draft);
      // 草稿存在说明上次编辑会话异常退出（干净退出会在 dispose 里清除草稿）。
      // 只有草稿确实记录了内容时才恢复，避免把空白草稿盖上正式图。
      if (restored.nodes.isEmpty && restored.connections.isEmpty) return;
      setState(() {
        _nodes.clear(); _nodes.addAll(restored.nodes);
        _connections.clear(); _connections.addAll(restored.connections);
        _logicBlocks.clear(); _logicBlocks.addAll(restored.logicBlocks);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检测到未保存的草稿，已自动恢复')),
      );
    } catch (_) {
      // 草稿损坏则忽略
    }
  }

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows && !isMobilePlatform) {
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
        if (n.type == PipelineStepType.start && !n.isGate) {
          n.params['file_media_type'] = widget.video.fileMediaType.name;
        }
      }
    }
    _setupAutosave(isConfigMode);
    _genThumb();
    _transformCtrl.addListener(_onScaleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _transformCtrl.value = Matrix4.identity()..translateByDouble(-_canvasSize / 2 + 300, -_canvasSize / 2 + 200, 0, 1);
    });
    _appState = context.read<AppState>();
    // 初始化横竖屏偏好
    if (isMobilePlatform) {
      _isLandscape = _appState.config.useNodeEditorLandscape;
      if (_isLandscape) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        // 横屏默认进入：隐藏系统状态栏，画布铺满
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    }
    _appState.mcpOnClearAll = () { _pushUndo(); setState(() { _nodes.clear(); _connections.clear(); _logicBlocks.clear(); _selectedNodeIds.clear(); _saveGraph(); }); };
    _appState.mcpOnUndo = _undo;
    _appState.mcpOnRedo = _redo;
    _appState.mcpOnSave = _saveGraph;
    _appState.mcpOnModifyNode = (nodeId, params) {
      // 节点不存在时返回 false，让 MCP 工具把失败信息回填给 AI（原来静默改写第一个节点）
      final idx = _nodes.indexWhere((n) => n.id == nodeId);
      if (idx < 0) return false;
      _pushUndo();
      setState(() {
        params.forEach((k, v) { _nodes[idx].params[k] = v; });
      });
      _saveGraph();
      return true;
    };
    _appState.mcpOnAddNode = (typeName, x, y) {
      final type = PipelineStepType.values.firstWhere((t) => t.name == typeName, orElse: () => throw ArgumentError('Unknown type: $typeName'));
      final node = PipelineNode(id: _uuid.v4(), type: type, x: x, y: y);
      _pushUndo();
      setState(() => _nodes.add(node));
      _saveGraph();
      return node.id;
    };
    _appState.mcpOnAddGate = (gateName, x, y) {
      LogicGateType? gate;
      for (final t in LogicGateType.values) {
        if (t.name == gateName) { gate = t; break; }
      }
      if (gate == null) throw ArgumentError('Unknown gate type: $gateName');
      final node = PipelineNode(id: _uuid.v4(), type: PipelineStepType.start, gateType: gate.name, x: x, y: y);
      _pushUndo();
      setState(() => _nodes.add(node));
      _saveGraph();
      return node.id;
    };
    _appState.mcpOnDeleteNode = (nodeId) {
      if (!_nodes.any((n) => n.id == nodeId)) throw ArgumentError('Node not found: $nodeId');
      _deleteNode(nodeId);
      _saveGraph();
    };
    _appState.mcpOnConnect = (fromId, toId) {
      if (fromId == toId) return false;
      if (!_nodes.any((n) => n.id == fromId) || !_nodes.any((n) => n.id == toId)) return false;
      if (_connections.any((c) => c.fromNodeId == fromId && c.toNodeId == toId)) return false;
      _pushUndo();
      setState(() => _connections.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId)));
      _saveGraph();
      return true;
    };
    _appState.mcpOnDisconnect = (connId) {
      final idx = _connections.indexWhere((c) => c.id == connId);
      if (idx < 0) return false;
      _pushUndo();
      setState(() => _connections.removeAt(idx));
      _saveGraph();
      return true;
    };
    _appState.mcpOnListNodes = () => _nodes.map((n) => n.toJson()).toList();
    _appState.mcpOnListConnections = () => _connections.map((c) => c.toJson()).toList();
  }

  /// 移动端横竖屏切换：切换时调用系统 Orientation API，离开页面时恢复竖屏。
  void _toggleOrientation() {
    final newVal = !_isLandscape;
    setState(() {
      _isLandscape = newVal;
    });
    // 持久化到配置
    _appState.updateConfig((c) => c..useNodeEditorLandscape = newVal);
    if (newVal) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      // 横屏：隐藏系统状态栏/导航栏，画布铺满整个屏幕
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      // 竖屏：恢复系统栏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void dispose() {
    // 离开页面时恢复竖屏 + 恢复系统栏
    if (isMobilePlatform) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _transformCtrl.removeListener(_onScaleChanged);
    _transformCtrl.dispose();
    // 移除 windowManager 监听，避免 window manager 持有本 State 的强引用导致泄漏
    if (!Platform.isWindows && !isMobilePlatform) {
      windowManager.removeListener(this);
    }
    // 只取消定时器，不在此清除草稿：草稿改为在「显式保存／确认放弃」时清除。
    // 经窗口关闭按钮、崩溃等未确认路径退出时草稿保留，下次打开可恢复。
    _autosaveTimer?.cancel();
    _appState.mcpOnClearAll = null;
    _appState.mcpOnUndo = null;
    _appState.mcpOnRedo = null;
    _appState.mcpOnSave = null;
    _appState.mcpOnModifyNode = null;
    _appState.mcpOnAddNode = null;
    _appState.mcpOnAddGate = null;
    _appState.mcpOnDeleteNode = null;
    _appState.mcpOnConnect = null;
    _appState.mcpOnDisconnect = null;
    _appState.mcpOnListNodes = null;
    _appState.mcpOnListConnections = null;
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
    final f = File('${Directory.systemTemp.path}/ffmpegpp_thumb_${_stableThumbHash(fp)}$suffix.jpg');
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
      final r = await Process.run(FfmpegInstaller.resolveFfmpeg(configured: _appState.config.ffmpegPath), args);
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
      case PipelineStepType.extractAudio: return Icons.music_note;
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
      case PipelineStepType.videoCrop: return Icons.crop_free;
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
    _saveGraph();
    _trackUsage(type);
    if (context.read<AppState>().config.debugMode) {
      context.read<AppState>().addLog('[节点] 添加 ${type.name} @ (${canvasPos.dx.toStringAsFixed(0)}, ${canvasPos.dy.toStringAsFixed(0)}) id=${node.id.substring(0, 8)}', category: 'info');
    }
  }

  void _addGateAt(LogicGateType gate, Offset canvasPos) {
    _pushUndo();
    final node = PipelineNode(
      id: _uuid.v4(),
      type: PipelineStepType.start, // 使用 start 作为占位类型，gateType 标识逻辑门
      x: canvasPos.dx, y: canvasPos.dy,
      gateType: gate.name,
    );
    setState(() => _nodes.add(node));
    _saveGraph();
    if (context.read<AppState>().config.debugMode) {
      context.read<AppState>().addLog('[逻辑门] 添加 ${gate.name} @ (${canvasPos.dx.toStringAsFixed(0)}, ${canvasPos.dy.toStringAsFixed(0)}) id=${node.id.substring(0, 8)}', category: 'info');
    }
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
    _saveGraph();
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
    _saveGraph();
  }

  String _mediaTypeName(MediaType t, bool zh) => switch (t) {
    MediaType.video => zh ? '视频' : 'video',
    MediaType.image => zh ? '图片' : 'image',
    MediaType.audio => zh ? '音频' : 'audio',
  };

  void _addConnection(String fromId, String toId, [String kind = 'data']) {
    if (fromId == toId) return;
    final fromIdx = _nodes.indexWhere((n) => n.id == fromId);
    final toIdx = _nodes.indexWhere((n) => n.id == toId);
    if (fromIdx < 0 || toIdx < 0) return;
    final fromNode = _nodes[fromIdx];
    final toNode = _nodes[toIdx];
    if (_connections.any((c) => c.fromNodeId == fromId && c.toNodeId == toId)) return;
    final zh = context.read<AppState>().config.language == 'zh';

    if (kind == 'control') {
      // 控制连线验证：逻辑门 ↔ 逻辑门 / 逻辑门 → 使能端 / 状态端 → 使能端
      // 非逻辑节点不能直接接收逻辑门连线（只能连到使能端口，由端口拖拽保证）

      // 源端：必须有控制输出能力（逻辑门输出 / 非起始节点的状态输出）
      final fromOk = fromNode.isGate ? fromNode.hasGateOutput : (fromNode.type != PipelineStepType.start);
      if (!fromOk) {
        showToast(context, zh ? '该节点没有控制输出端口' : 'Node has no control output', type: ToastType.error);
        return;
      }

      // 目标端：逻辑门需要检查输入数上限；非逻辑节点只允许连到使能端（非起始节点）
      if (toNode.isGate) {
        final gate = toNode.gate;
        if (gate == null || !toNode.hasGateInput) {
          showToast(context, zh ? '该逻辑门不支持输入' : 'Gate does not accept input', type: ToastType.error);
          return;
        }
        // 检查已有的控制连线数是否达到上限
        final existingInputs = _connections.where((c) => c.toNodeId == toNode.id && c.kind == 'control').length;
        if (existingInputs >= gate.inputCount) {
          showToast(context, zh
              ? '${gate.symbol(true)} 最多 ${gate.inputCount} 个输入，已满'
              : '${gate.symbol(false)} allows max ${gate.inputCount} input(s)',
              type: ToastType.error);
          return;
        }
      } else {
        // 非逻辑节点的红色逻辑输入端（使能端）：接受逻辑门输出或上游节点的状态输出（状态端 → 使能端）。
        // 语义与顶部注释一致：红色端口只传播 1/0，普通节点的状态输出可级联控制下游节点。
        if (toNode.type == PipelineStepType.start) {
          showToast(context, zh ? '源节点没有使能输入端' : 'Source node has no enable input', type: ToastType.error);
          return;
        }
      }

      _pushUndo();
      setState(() {
        _connections.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId, kind: 'control'));
      });
      _saveGraph();
      return;
    }

    // 数据连线验证
    if (!fromNode.hasOutput || !toNode.hasInput) return;

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
    _pushUndo();
    setState(() {
      _connections.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId, kind: kind));
    });
    _saveGraph();
  }

  void _deleteConnection(String connId) {
    // 连线不存在时不压入无变化的撤销快照
    if (!_connections.any((c) => c.id == connId)) return;
    _pushUndo();
    final conn = _connections.firstWhere((c) => c.id == connId);
    setState(() {
      _connections.removeWhere((c) => c.id == connId);
    });
    if (widget.video.filepath.isEmpty && conn.fromNodeId.isNotEmpty) {
      final fromNode = _nodes.where((n) => n.id == conn.fromNodeId).firstOrNull;
      if (fromNode != null && fromNode.type == PipelineStepType.start && !fromNode.isGate) {
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
    _saveGraph();
  }

  PipelineConnection? _hitTestConnection(Offset pos) {
    // 移动端手指热区 ~24-32px；桌面端保持 8px 的精确判定。
    final threshold = isMobilePlatform ? 28.0 : 8.0;
    for (final conn in _connections) {
      final fi = _nodes.indexWhere((n) => n.id == conn.fromNodeId);
      final ti = _nodes.indexWhere((n) => n.id == conn.toNodeId);
      if (fi < 0 || ti < 0) continue;
      final from = _nodes[fi];
      final to = _nodes[ti];
      final isControl = conn.kind == 'control';
      // 与 _ConnectionPainter 一致：控制连线到逻辑门目标时，按顺序计算第几个输入
      final inputIdx = (isControl && to.isGate)
          ? _connections.where((c) => c.toNodeId == conn.toNodeId && c.kind == 'control').toList().indexOf(conn)
          : 0;
      if (inputIdx < 0) continue;
      final p1 = _hitPortPos(from, isOutput: true, isControl: isControl);
      final p2 = _hitPortPos(to, isOutput: false, isControl: isControl, gateInputIndex: inputIdx);
      final dist = _distToWire(pos, p1, p2, orthogonal: isControl);
      if (dist < threshold) return conn;
    }
    return null;
  }

  /// 端口坐标（与 _ConnectionPainter._portPos 保持一致；改动端口布局时需同步两处）。
  Offset _hitPortPos(PipelineNode n, {required bool isOutput, required bool isControl, int gateInputIndex = 0}) {
    if (n.isGate) {
      final g = n.gate;
      final inputCount = g?.inputCount ?? 0;
      if (isOutput) return Offset(n.x + _portZoneW + _gateW + _portZoneW / 2, n.y + _gateH / 2);
      if (inputCount == 0) return Offset(n.x + _portZoneW / 2, n.y + _gateH / 2);
      final idx = gateInputIndex.clamp(0, inputCount - 1);
      return Offset(n.x + _portZoneW / 2, n.y + _gateH * (idx + 1) / (inputCount + 1));
    }
    final colTop = n.y + (_nodeH - 38) / 2;
    final dot1Y = colTop + 8;
    final dot2Y = colTop + 30;
    if (isControl) {
      return isOutput ? Offset(n.x + 16 + _nodeWFor(n.type) + 8, dot2Y) : Offset(n.x + 8, dot2Y);
    }
    return isOutput ? Offset(n.x + 16 + _nodeWFor(n.type) + 8, dot1Y) : Offset(n.x + 8, dot1Y);
  }

  /// 点到连线的距离：数据连线为贝塞尔曲线，控制连线为正交折线（与 _ConnectionPainter 一致）。
  double _distToWire(Offset pt, Offset p1, Offset p2, {required bool orthogonal}) {
    if (orthogonal) {
      const lead = 20.0;
      final dx = p2.dx - p1.dx;
      final midX = p2.dx - (dx >= 0 ? lead : -lead);
      var minDist = _distToSeg(pt, p1, Offset(midX, p1.dy));
      final d2 = _distToSeg(pt, Offset(midX, p1.dy), Offset(midX, p2.dy));
      if (d2 < minDist) minDist = d2;
      final d3 = _distToSeg(pt, Offset(midX, p2.dy), p2);
      if (d3 < minDist) minDist = d3;
      return minDist;
    }
    // 数据贝塞尔：弹性系数 0.4 与 _ConnectionPainter._bezierPath 一致
    final dx = p2.dx - p1.dx;
    final ctrlOffset = dx.abs() * 0.4;
    final sign = dx >= 0 ? 1.0 : -1.0;
    final c1 = Offset(p1.dx + ctrlOffset * sign, p1.dy);
    final c2 = Offset(p2.dx - ctrlOffset * sign, p2.dy);
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

  double _distToSeg(Offset pt, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (pt - a).distance;
    final t = (((pt.dx - a.dx) * ab.dx + (pt.dy - a.dy) * ab.dy) / len2).clamp(0.0, 1.0).toDouble();
    return (pt - (a + ab * t)).distance;
  }

  void _showConnectionMenu(Offset screenPos, PipelineConnection conn) {
    final s = AppStrings.of(context.read<AppState>().config.language);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(screenPos.dx, screenPos.dy, screenPos.dx + 1, screenPos.dy + 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      constraints: isMobilePlatform
          ? const BoxConstraints(minWidth: 120, maxWidth: 160)
          : const BoxConstraints(minWidth: 160, maxWidth: 240),
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
    _clearDraft();
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

  /// 从 .fppx 文件加载节点配置到画布（覆盖当前画布）
  Future<void> _importConfig(AppStrings s) async {
    final zh = s.isZh;
    final scheme = Theme.of(context).colorScheme;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: zh ? '选择配置文件' : 'Select Config File',
      type: FileType.custom,
      allowedExtensions: ['fppx'],
    );
    if (result == null || result.files.isEmpty || result.files.first.path == null) return;
    final path = result.files.first.path!;

    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      final fppx = FppxExporter.import(bytes);
      if (fppx == null) {
        showToast(context, zh ? '无法解析该文件' : 'Cannot parse this file', type: ToastType.error);
        return;
      }
      if (fppx.errors.isNotEmpty) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(zh ? '配置加载失败' : 'Load Failed', style: TextStyle(color: scheme.onSurface)),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              ...fppx.errors.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $e', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              )),
            ]),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s.isZh ? '知道了' : 'OK'))],
          ),
        );
        return;
      }
      final graph = fppx.graph;
      if (graph == null) {
        showToast(context, zh ? '该文件不是节点配置' : 'Not a node config', type: ToastType.error);
        return;
      }
      if (fppx.warnings.isNotEmpty) {
        showToast(context, fppx.warnings.join('\n'), type: ToastType.warning);
      }
      // 覆盖当前画布
      _pushUndo();
      setState(() {
        _nodes.clear();
        _nodes.addAll(graph.nodes);
        _connections.clear();
        _connections.addAll(graph.connections);
        _logicBlocks.clear();
        _logicBlocks.addAll(graph.logicBlocks);
        _selectedNodeIds.clear();
        _lastSelectedId = null;
      });
      if (mounted) {
        showToast(context, zh ? '已加载 ${_nodes.length} 个节点' : 'Loaded ${_nodes.length} nodes', type: ToastType.success);
      }
    } catch (e) {
      if (mounted) showToast(context, zh ? '加载失败: $e' : 'Load failed: $e', type: ToastType.error);
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
    if (result == true) _clearDraft();
    return result ?? false;
  }

  Offset _screenToCanvas(Offset screen) {
    final inv = Matrix4.inverted(_transformCtrl.value);
    final x = inv.storage[0] * screen.dx + inv.storage[4] * screen.dy + inv.storage[12];
    final y = inv.storage[1] * screen.dx + inv.storage[5] * screen.dy + inv.storage[13];
    return Offset(x, y);
  }

  // ── 缩放/整理/定位 ──

  void _zoomTo(double newScale) {
    final rb = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final viewCenter = rb.size.center(Offset.zero);
    final canvasCenter = _screenToCanvas(viewCenter);
    final clamped = newScale.clamp(0.3, 2.0);
    _transformCtrl.value = Matrix4.identity()
      ..translateByDouble(viewCenter.dx, viewCenter.dy, 0, 1)
      ..scaleByDouble(clamped, clamped, 1, 1)
      ..translateByDouble(-canvasCenter.dx, -canvasCenter.dy, 0, 1);
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
      if (n.x + _totalNodeWidth(n) > maxX) maxX = n.x + _totalNodeWidth(n);
      if (n.y + _nodeHeight(n) > maxY) maxY = n.y + _nodeHeight(n);
    }
    final contentW = maxX - minX + 80;
    final contentH = maxY - minY + 80;
    final scale = math.min(viewSize.width / contentW, viewSize.height / contentH).clamp(0.3, 2.0);
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    _transformCtrl.value = Matrix4.identity()
      ..translateByDouble(viewSize.width / 2, viewSize.height / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1);
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
    _saveGraph();
    WidgetsBinding.instance.addPostFrameCallback((_) => _zoomToFit());
  }

  void _goToSource(AppStrings s) {
    final startNodes = _nodes.where((n) => n.type == PipelineStepType.start && !n.isGate).toList();
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
      ..translateByDouble(viewCenter.dx, viewCenter.dy, 0, 1)
      ..scaleByDouble(_currentScale, _currentScale, 1, 1)
      ..translateByDouble(-nodeCenterX, -nodeCenterY, 0, 1);
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
      maxX = math.max(maxX, n.x + _totalNodeWidth(n));
      maxY = math.max(maxY, n.y + _nodeHeight(n));
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
    PipelineStepType.extractAudio,
    PipelineStepType.videoCrop,
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
      if (idx >= 0) {
        top[idx] = PipelineStepType.output;
      } else {
        top[3] = PipelineStepType.output;
      }
    }
    return top;
  }

  void _showCanvasMenu(Offset screenPos) {
    final s = AppStrings.of(context.read<AppState>().config.language);
    final scheme = Theme.of(context).colorScheme;
    final canvasPos = _screenToCanvas(screenPos);
    final top5 = _top5Types();

    PopupMenuItem<PipelineStepType> makeItem(PipelineStepType t) {
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
      constraints: isMobilePlatform
          ? const BoxConstraints(minWidth: 120, maxWidth: 160)
          : const BoxConstraints(minWidth: 160, maxWidth: 240),
      items: [
        ...top5.map(makeItem),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: null,
          enabled: false,
          height: 0,
          child: PopupMenuButton<PipelineStepType>(
            tooltip: '',
            offset: const Offset(200, 0),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            itemBuilder: (_) => _allNodeTypes.map(makeItem).toList(),
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
      constraints: isMobilePlatform
          ? const BoxConstraints(minWidth: 120, maxWidth: 160)
          : const BoxConstraints(minWidth: 160, maxWidth: 240),
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
    // 任何参数编辑变化都会触发自动保存草稿（不持久化到父组件）
    void onChanged() { setState(() {}); _markDirty(); }
    final v = widget.video;

    // 逻辑门节点：显示门信息编辑器（符号、说明、输入输出）
    if (node.isGate && node.gate != null) {
      if (node.gate == LogicGateType.timeTrigger) {
        return _buildTimeTriggerEditor(node, isZh);
      }
      return _buildGateInfoEditor(node, isZh);
    }

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
      case PipelineStepType.extractAudio:
        editor = ExtractAudioStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh,
            videoPath: v.filepath, videoDuration: v.duration);
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
      case PipelineStepType.videoCrop:
        editor = VideoCropStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh,
            videoPath: v.filepath, videoWidth: v.width, videoHeight: v.height, fps: v.fps);
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
            TextFormField(
              key: ValueKey('${node.id}_selected_indices'),
              initialValue: selectedIndices,
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
          TextFormField(
            key: ValueKey('${node.id}_node_name'),
            initialValue: nodeName,
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
                  onTap: () {
                    setState(() {
                      if (c == null) {
                        node.params.remove('node_color');
                      } else {
                        node.params['node_color'] = c;
                      }
                    });
                    onChanged();
                  },
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
            if (context.read<AppState>().config.aiEnabled) ...[
              _buildTopAiBar(scheme, s),
              const SizedBox(width: 4),
            ],
            IconButton(
              icon: const Icon(Icons.file_upload_outlined, size: 20),
              tooltip: s.isZh ? '导出配置' : 'Export Config',
              onPressed: _nodes.isEmpty ? null : () => _exportConfig(s),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              // 保存按钮：仅软盘图标，不显示文字
              child: IconButton.filled(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                tooltip: s.save,
                style: IconButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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

  /// 画布顶层的 AI 工具条：配置一键选择 + 自动/询问模式 + AI 抽屉开关。
  /// 操作全局配置（AI 面板自动跟随），避免挤在 AI 面板头部。
  Widget _buildTopAiBar(ColorScheme scheme, AppStrings s) {
    final cfg = context.read<AppState>().config;
    final profiles = cfg.aiProfiles.where((p) => p.enabled).toList();
    final activeProfile = profiles.where((p) => p.id == cfg.activeAiProfileId).firstOrNull;
    final showModel = activeProfile?.model ?? cfg.aiModel;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // AI 抽屉开关 + 会话标题（可点击，带展开/折叠动画）
      Tooltip(
        message: s.isZh ? (_aiDrawerOpen ? '收起 AI 面板' : '展开 AI 面板') : (_aiDrawerOpen ? 'Collapse AI panel' : 'Expand AI panel'),
        child: InkWell(
          onTap: () => setState(() => _aiDrawerOpen = !_aiDrawerOpen),
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _aiDrawerOpen ? scheme.primaryContainer.withAlpha(140) : scheme.surfaceContainerHighest.withAlpha(90),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  _aiDrawerOpen ? Icons.chevron_right : Icons.smart_toy,
                  key: ValueKey(_aiDrawerOpen ? 'open' : 'closed'),
                  size: 16,
                  color: _aiDrawerOpen ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              // 会话标题（有则显示，AnimatedSize 展开/折叠）
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerLeft,
                child: _aiSessionTitle.isEmpty
                    ? const SizedBox(width: 0)
                    : Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: Text(
                            _aiSessionTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary),
                          ),
                        ),
                      ),
              ),
            ]),
          ),
        ),
      ),
      const SizedBox(width: 6),
      // 配置一键选择（写入全局 activeAiProfileId，AI 面板跟随）
      Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withAlpha(90),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
        ),
        child: PopupMenuButton<String>(
          tooltip: s.isZh ? 'AI 配置 / 模型' : 'AI Profile / Model',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 140),
          onSelected: (v) {
            if (v == '__custom_model__') {
              _promptTopCustomModel(scheme, s);
            } else if (v.startsWith('model:')) {
              context.read<AppState>().updateConfig((c) => c..aiModel = v.substring(6));
            } else {
              final id = v.startsWith('profile:') ? v.substring(8) : '';
              context.read<AppState>().updateConfig((c) => c..activeAiProfileId = id);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem<String>(enabled: false,
                child: Text(s.isZh ? '配置' : 'Profiles',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: scheme.outline))),
            for (final p in profiles)
              PopupMenuItem(value: 'profile:${p.id}',
                  child: Row(children: [
                    Icon(cfg.activeAiProfileId == p.id ? Icons.radio_button_checked : Icons.radio_button_off,
                        size: 13, color: cfg.activeAiProfileId == p.id ? scheme.primary : scheme.outline),
                    const SizedBox(width: 6),
                    Flexible(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12))),
                  ])),
            if (profiles.isNotEmpty) const PopupMenuDivider(),
            PopupMenuItem(value: 'profile:',
                child: Text(s.isZh ? '默认配置' : 'Default', style: const TextStyle(fontSize: 12))),
            const PopupMenuDivider(),
            PopupMenuItem<String>(enabled: false,
                child: Text(s.isZh ? '模型' : 'Model',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: scheme.outline))),
            PopupMenuItem(value: 'model:$showModel',
                child: Row(children: [
                  Icon(Icons.psychology_outlined, size: 13, color: scheme.primary),
                  const SizedBox(width: 6),
                  Flexible(child: Text(showModel, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12))),
                ])),
            PopupMenuItem(value: '__custom_model__',
                child: Text(s.isZh ? '自定义模型...' : 'Custom model...', style: const TextStyle(fontSize: 12))),
          ],
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.tune, size: 13, color: scheme.primary),
            const SizedBox(width: 4),
            Flexible(child: Text(
              '${activeProfile?.name ?? (s.isZh ? '默认' : 'Default')} · $showModel',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurface))),
            Icon(Icons.arrow_drop_down, size: 14, color: scheme.outline),
          ]),
        ),
      ),
      const SizedBox(width: 6),
      // 自动 / 询问 模式切换（写入全局 aiApproveMode）
      GestureDetector(
        onTap: () => context.read<AppState>().updateConfig((c) {
          c.aiApproveMode = (c.aiApproveMode == 'auto') ? 'ask' : 'auto';
          return c;
        }),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: cfg.aiApproveMode == 'auto' ? scheme.primaryContainer.withAlpha(140) : scheme.secondaryContainer.withAlpha(140),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(cfg.aiApproveMode == 'auto' ? Icons.bolt : Icons.help_outline, size: 13, color: scheme.primary),
            const SizedBox(width: 4),
            Text(cfg.aiApproveMode == 'auto' ? (s.isZh ? '自动' : 'Auto') : (s.isZh ? '询问' : 'Ask'),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          ]),
        ),
      ),
    ]);
  }

  /// 顶层自定义模型弹窗（写全局 aiModel）。
  Future<void> _promptTopCustomModel(ColorScheme scheme, AppStrings s) async {
    final cfg = context.read<AppState>().config;
    final ctrl = TextEditingController(text: cfg.aiModel);
    final result = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(s.isZh ? '自定义模型' : 'Custom Model', style: const TextStyle(fontSize: 14)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(isDense: true, border: OutlineInputBorder(),
              hintText: s.isZh ? '输入模型名，如 deepseek-reasoner' : 'e.g. deepseek-reasoner'),
          onSubmitted: (v) => Navigator.pop(dCtx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx), child: Text(s.isZh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dCtx, ctrl.text.trim()), child: Text(s.isZh ? '确定' : 'OK')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      await context.read<AppState>().updateConfig((c) => c..aiModel = result);
    }
    ctrl.dispose();
  }

  // ── Body with CSD title bar ──

  Widget _buildBody(ColorScheme scheme, AppStrings s) {
    // 横屏沉浸式（状态栏已隐藏）时不再预留顶部安全区，画布铺满整个屏幕
    final topPad = Platform.isWindows
        ? 0.0
        : (isMobilePlatform
            ? (_isLandscape ? 0.0 : MediaQuery.of(context).padding.top)
            : 36.0);
    final content = Padding(
      padding: EdgeInsets.only(top: topPad),
      child: Column(children: [
        // 移动端：顶部栏已移除（舍弃最顶层菜单栏），系统返回手势/实体 back 键
        // 由 PopScope 拦截处理；横竖屏切换与返回按钮已移至画布浮动控件。
        Expanded(child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: LayoutBuilder(builder: (ctx, cons) {
            // 移动端（横竖屏通用）：画布 + 贴右边界的窄竖直 sidebar，
            // 元素工具箱与属性面板收纳为右侧边栏，宽度约屏幕 1/2。
            if (isMobilePlatform) {
              // 移动端全画布布局：顶部/底部浮动菜单栏，工具箱/属性为弹出层
              return Stack(children: [
                _buildCanvas(scheme, s),
                // 顶部浮动菜单栏（默认收起 → 上滑出屏 + 透明；右下角"≡"按钮展开）
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    offset: _mobileTopBarVisible ? Offset.zero : const Offset(0, -1.4),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: _mobileTopBarVisible ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !_mobileTopBarVisible,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Center(child: _buildMobileTopBar(scheme, s)),
                        ),
                      ),
                    ),
                  ),
                ),
                // 底部浮动菜单栏 - 左侧缩放（右下角工具条已移除，工具迁移到顶部栏）
                Positioned(
                  bottom: 8, left: 8,
                  child: _buildMobileBottomLeftBar(scheme, s),
                ),
                // 底部中央文件信息条
                Positioned(
                  bottom: 8, left: 0, right: 0,
                  child: Center(child: _buildMobileFileInfo(scheme, s)),
                ),
                // 工具箱弹出层（点击顶部"+"按钮展开）
                if (_mobileToolboxOpen)
                  Positioned.fill(
                    child: _buildMobileToolboxSheet(scheme, s),
                  ),
                // 属性编辑底部弹层（选中节点时自动弹出）
                if (_selectedNode != null || _selectedLogicBlockId != null)
                  Positioned(
                    left: 0, right: 0, bottom: 0,
                    child: _buildMobilePropertiesSheet(scheme, s),
                  ),
              ]);
            }
            // 横屏/桌面模式：原有的水平并排布局
            const dividerW = 6.0;
            final totalW = cons.maxWidth - dividerW;
            final canvasW = totalW * _canvasFraction;
            final rightW = totalW * (1 - _canvasFraction);
            return Row(children: [
              SizedBox(width: canvasW, child: _buildCanvas(scheme, s)),
              // 可拖动分割线
              MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (d) => setState(() {
                    _canvasFraction = ((_canvasFraction * totalW + d.delta.dx) / totalW).clamp(0.15, 0.85);
                  }),
                  child: Container(
                    width: dividerW,
                    color: Colors.transparent,
                    child: Center(child: Container(
                      width: 3, height: 36,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant.withAlpha(90),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    )),
                  ),
                ),
              ),
              SizedBox(width: rightW, child: _buildRightPanel(scheme, s)),
            ]);
          }),
        )),
        if (!isMobilePlatform) _buildBottomBar(scheme, s),
      ]),
    );
    if (Platform.isWindows || isMobilePlatform) return content;
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
    if (Platform.isMacOS) {
      // macOS 惯例用 Cmd（meta）而不是 Ctrl
      return keys.contains(LogicalKeyboardKey.metaLeft) || keys.contains(LogicalKeyboardKey.metaRight);
    }
    return keys.contains(LogicalKeyboardKey.controlLeft) || keys.contains(LogicalKeyboardKey.controlRight);
  }

  Widget _buildCanvas(ColorScheme scheme, AppStrings s) {
    final aiEnabled = context.read<AppState>().config.aiEnabled;
    // 画布背景：跟随全局(global)时透明显示页面全局背景/壁纸/玻璃；
    // 否则用指定实色填充画布
    final canvasBg = context.read<AppState>().config.canvasBg;
    final canvasFill = switch (canvasBg) {
      'gray' => const Color(0xFF2B2B2B),
      'black' => const Color(0xFF0A0A0A), // 接近纯黑但不刺眼
      'white' => const Color(0xFFF0F0F0), // 比纯白暗一点
      _ => null, // global：透明
    };
    // 网格线颜色随背景自适应
    final gridColor = switch (canvasBg) {
      'black' => const Color(0xFF555555).withAlpha(180), // 黑底白偏灰
      'white' => const Color(0xFFBBBBBB).withAlpha(160), // 白底灰线
      'gray' => scheme.outlineVariant.withAlpha(60),
      _ => scheme.outlineVariant.withAlpha(25), // global
    };

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
            _transformCtrl.value = _transformCtrl.value.clone()..translateByDouble(delta.dx, delta.dy, 0, 1);
          }
        }
        // Left-click box-select drag
        if (_isBoxSelecting && _boxSelectStart != null && (e.buttons & kPrimaryMouseButton) != 0) {
          final canvasPos = _screenToCanvas(e.localPosition);
          setState(() {
            _boxSelectRect = Rect.fromPoints(_boxSelectStart!, canvasPos);
          });
        }
        // 探测模式：按下移动时也更新
        if (_probeMode) _updateProbe(e.localPosition);
      },
      // 悬停探测：无按键时鼠标移动触发
      onPointerHover: (e) {
        if (_probeMode) _updateProbe(e.localPosition);
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
                final nodeRect = Rect.fromLTWH(n.x, n.y, _totalNodeWidth(n), _nodeHeight(n));
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
            Positioned.fill(child: CustomPaint(painter: _GridPainter(
              color: gridColor,
              fill: canvasFill,
            ))),
            // 连线
            CustomPaint(
              size: Size(_canvasSize, _canvasSize),
              painter: _ConnectionPainter(
                nodes: _nodes,
                connections: _hideLogic
                    ? _connections.where((c) => c.kind != 'control').toList()
                    : _connections,
                color: scheme.primary.withAlpha(140),
                controlColor: scheme.tertiary.withAlpha(180),
                selectedNodeIds: _selectedNodeIds,
              ),
            ),
            // 临时拖拽连线
            if (_dragFromNodeId != null && _dragLineEnd != null)
              CustomPaint(
                size: Size(_canvasSize, _canvasSize),
                painter: _TempLinePainter(
                  from: _dragLineStart(),
                  to: _dragLineEnd!,
                  color: _dragPort.contains('gate') || _dragPort.contains('status') || _dragPort.contains('enable')
                      ? scheme.tertiary.withAlpha(120)
                      : scheme.primary.withAlpha(100),
                  isControl: _dragPort.contains('gate') || _dragPort.contains('status') || _dragPort.contains('enable'),
                ),
              ),
            // 节点
            for (final node in _nodes)
              if (!(_hideLogic && node.isGate))
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
            // 探测模式：在端口位置显示信号提示（画布坐标系，随缩放平移）
            if (_probeMode && _probeTooltip != null && _probeTooltipPos != null)
              Positioned(
                left: _probeTooltipPos!.dx + 10,
                top: _probeTooltipPos!.dy - 12,
                child: IgnorePointer(child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.inverseSurface.withAlpha(230),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _probeTooltip!,
                      style: TextStyle(fontSize: 11, color: scheme.onInverseSurface),
                    ),
                  ),
                )),
              ),
          ]),
        ),
      ),
    );

    // Wrap canvas area with Focus for Ctrl+A
    final focusedCanvas = GestureDetector(
      // 移动端：长按画布空白处 = 右键画布菜单
      onLongPressStart: isMobilePlatform
          ? (d) {
              final canvasPos = _screenToCanvas(d.localPosition);
              final hitNode = _findNodeAtCanvasPos(canvasPos);
              if (hitNode != null) return; // 由节点自身的 onLongPressStart 处理
              final hitConn = _hitTestConnection(canvasPos);
              if (hitConn != null) {
                _showConnectionMenu(d.globalPosition, hitConn);
              } else {
                _showCanvasMenu(d.globalPosition);
              }
            }
          : null,
      child: Focus(
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
      ),
    );

    final inner = Column(children: [
      // 移动端顶部工具栏/分隔线移除：改由浮动菜单栏承载（见 _buildBody 的
      // _buildMobileTopBar），避免新旧两套工具栏在画布顶部互相重叠。
      if (!isMobilePlatform) ...[
      Row(children: [
        SizedBox(
          width: isMobilePlatform ? MediaQuery.of(context).size.width * 0.5 : double.infinity,
          child: Padding(
            padding: isMobilePlatform
              ? const EdgeInsets.fromLTRB(6, 6, 6, 2)
              : const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(children: [
          if (!Platform.isWindows && !isMobilePlatform) ...[
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
          if (isMobilePlatform) ...[
            IconButton(
              icon: Icon(Icons.undo, size: 14, color: _undoStack.isEmpty ? scheme.outlineVariant : scheme.onSurfaceVariant),
              tooltip: s.isZh ? '撤销' : 'Undo',
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              padding: EdgeInsets.zero,
              onPressed: _undoStack.isEmpty ? null : _undo,
            ),
            IconButton(
              icon: Icon(Icons.redo, size: 14, color: _redoStack.isEmpty ? scheme.outlineVariant : scheme.onSurfaceVariant),
              tooltip: s.isZh ? '重做' : 'Redo',
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              padding: EdgeInsets.zero,
              onPressed: _redoStack.isEmpty ? null : _redo,
            ),
            IconButton(
              icon: Icon(Icons.save_outlined, size: 14, color: scheme.onSurface),
              tooltip: s.save,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              padding: EdgeInsets.zero,
              onPressed: _save,
            ),
            const Spacer(),
            // 溢出菜单：把 PC 工具栏全部功能（导出/导入配置、探测模式、隐藏逻辑线）
            // 收进同一入口，保证移动端 1/2 宽菜单栏下功能不缺失。
            PopupMenuButton<String>(
              tooltip: s.isZh ? '更多' : 'More',
              icon: Icon(Icons.more_vert, size: 14, color: scheme.onSurface),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onSelected: (v) {
                switch (v) {
                  case 'export':
                    if (_nodes.isNotEmpty) _exportConfig(s);
                    break;
                  case 'import':
                    _importConfig(s);
                    break;
                  case 'probe':
                    setState(() => _probeMode = !_probeMode);
                    break;
                  case 'hide':
                    setState(() => _hideLogic = !_hideLogic);
                    break;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem<String>(
                  value: 'export',
                  enabled: _nodes.isNotEmpty,
                  child: Row(children: [
                    Icon(Icons.file_upload_outlined, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(s.isZh ? '导出配置' : 'Export Config'),
                  ]),
                ),
                PopupMenuItem<String>(
                  value: 'import',
                  child: Row(children: [
                    Icon(Icons.file_download_outlined, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(s.importConfig),
                  ]),
                ),
                PopupMenuItem<String>(
                  value: 'probe',
                  child: Row(children: [
                    Icon(Icons.search, size: 16, color: _probeMode ? scheme.primary : scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(s.isZh ? '探测模式' : 'Probe'),
                    if (_probeMode) ...[const Spacer(), Icon(Icons.check, size: 14, color: scheme.primary)],
                  ]),
                ),
                PopupMenuItem<String>(
                  value: 'hide',
                  child: Row(children: [
                    Icon(Icons.route, size: 16, color: _hideLogic ? scheme.error : scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(s.isZh ? '隐藏逻辑线' : 'Hide logic'),
                    if (_hideLogic) ...[const Spacer(), Icon(Icons.check, size: 14, color: scheme.error)],
                  ]),
                ),
              ],
            ),
          ],
          if (!isMobilePlatform) ...[
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
          const SizedBox(width: 6),
          // 探测模式按钮：悬停端口显示信号提示
          Tooltip(
            message: s.isZh ? '探测模式：悬停端口显示信号' : 'Probe: hover ports to inspect signals',
            waitDuration: const Duration(milliseconds: 300),
            child: IconButton(
              icon: Icon(Icons.search, size: 16, color: _probeMode ? scheme.primary : scheme.onSurfaceVariant),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: _probeMode ? scheme.primary.withAlpha(40) : null,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: () => setState(() => _probeMode = !_probeMode),
            ),
          ),
          // 隐藏逻辑线按钮：隐藏/显示控制连线+逻辑门+红色逻辑端口
          Tooltip(
            message: s.isZh ? '隐藏逻辑线（控制连线、逻辑门、逻辑端口）' : 'Hide logic (control wires, gates, logic ports)',
            waitDuration: const Duration(milliseconds: 300),
            child: IconButton(
              icon: Icon(Icons.route, size: 16, color: _hideLogic ? scheme.error : scheme.onSurfaceVariant),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: _hideLogic ? scheme.error.withAlpha(40) : null,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: () => setState(() => _hideLogic = !_hideLogic),
            ),
          ),
          const Spacer(),
          if (!Platform.isWindows) ...[
            IconButton(
              icon: Icon(Icons.file_download_outlined, size: 18, color: scheme.onSurface),
              tooltip: s.importConfig,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: () => _importConfig(s),
            ),
            IconButton(
              icon: Icon(Icons.file_upload_outlined, size: 18, color: scheme.onSurface),
              tooltip: s.isZh ? '导出配置' : 'Export Config',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: _nodes.isEmpty ? null : () => _exportConfig(s),
            ),
            const SizedBox(width: 4),
            // 保存按钮：仅软盘图标，不显示文字
            IconButton(
              icon: Icon(Icons.save_outlined, size: 18, color: scheme.onSurface),
              tooltip: s.save,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: _save,
            ),
          ],
          if (Platform.isWindows)
            Text(s.isZh ? '右键添加节点' : 'Right-click to add',
                style: TextStyle(fontSize: 10, color: scheme.outline)),
          ],
        ]),
          ),
        ),
      ]),
      const Divider(height: 1, indent: 12, endIndent: 12),
      ],
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
        child: DragTarget<Object>(
          onAcceptWithDetails: (details) {
            final rb = context.findRenderObject() as RenderBox;
            final local = rb.globalToLocal(details.offset);
            final canvasPos = _screenToCanvas(local);
            final data = details.data;
            if (data is PipelineStepType) {
              _addNodeAt(data, canvasPos);
            } else if (data is LogicGateType) {
              _addGateAt(data, canvasPos);
            }
          },
          builder: (ctx, candidateData, rejectedData) => Stack(children: [
            focusedCanvas,
            if (context.read<AppState>().config.debugMode)
              Positioned(
                left: 8, bottom: 8, right: 80,
                child: IgnorePointer(child: Text(
                  GraphExecutor.describeGraph(PipelineGraph(nodes: _nodes, connections: _connections, logicBlocks: _logicBlocks)),
                  // 移动端：调试(探测)状态描述不换行，单行省略；桌面端保持原样。
                  maxLines: isMobilePlatform ? 1 : null,
                  overflow: isMobilePlatform ? TextOverflow.ellipsis : null,
                  style: TextStyle(fontSize: 10, color: scheme.onSurface.withAlpha(128), height: 1.4),
                )),
              ),
            Positioned(
              right: 10, bottom: aiEnabled ? 60 : 10,
              child: _buildCanvasControls(scheme, s),
            ),
            // 左侧中间 ">" 按钮：展开/收起 AI 侧边面板（仅桌面端内嵌抽屉；
            // 移动端改为浮动按钮触发的底部弹层，见 _openAiSheet）
            if (aiEnabled && !isMobilePlatform)
              Positioned(
                left: 0, top: 0, bottom: 0,
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // AI 侧边抽屉（收起时宽度 0）
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    width: _aiDrawerOpen ? 420 : 0,
                    child: _aiDrawerOpen
                        ? _AiPanel(
                            key: const ValueKey('ai-drawer'),
                            startExpanded: true,
                            onCollapseRequested: () => setState(() => _aiDrawerOpen = false),
                            onTitleGenerated: (t) => setState(() => _aiSessionTitle = t),
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
                      if (_nodes.isEmpty) return;
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
                  onAddNode: (type, x, y) {
                    final stepType = PipelineStepType.values.firstWhere((t) => t.name == type, orElse: () => throw ArgumentError('Unknown type: $type'));
                    final node = PipelineNode(id: _uuid.v4(), type: stepType, x: x, y: y);
                    _pushUndo();
                    setState(() => _nodes.add(node));
                    _saveGraph();
                    return node.id;
                  },
                  onAddGate: (gateName, x, y) {
                    final gate = LogicGateType.values.asNameMap()[gateName];
                    if (gate == null) throw ArgumentError('Unknown gate type: $gateName');
                    final node = PipelineNode(
                      id: _uuid.v4(),
                      type: PipelineStepType.start,
                      x: x, y: y,
                      gateType: gate.name,
                    );
                    _pushUndo();
                    setState(() => _nodes.add(node));
                    _saveGraph();
                    return node.id;
                  },
                  onSetGateParams: (nodeId, params) {
                    final idx = _nodes.indexWhere((n) => n.id == nodeId);
                    if (idx < 0) return false;
                    _pushUndo();
                    setState(() {
                      params.forEach((k, v) { _nodes[idx].params[k] = v; });
                    });
                    _saveGraph();
                    return true;
                  },
                  onDeleteNode: (nodeId) {
                    _deleteNode(nodeId);
                    _saveGraph();
                  },
                  onConnectNodes: (fromId, toId) {
                    if (fromId == toId) return false;
                    if (!_nodes.any((n) => n.id == fromId) || !_nodes.any((n) => n.id == toId)) return false;
                    if (_connections.any((c) => c.fromNodeId == fromId && c.toNodeId == toId)) return false;
                    _pushUndo();
                    setState(() => _connections.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId)));
                    _saveGraph();
                    return true;
                  },
                  onDisconnectNodes: (connId) {
                    final idx = _connections.indexWhere((c) => c.id == connId);
                    if (idx < 0) return false;
                    _pushUndo();
                    setState(() => _connections.removeAt(idx));
                    _saveGraph();
                    return true;
                  },
                    onCancelTasks: () => context.read<AppState>().cancelProcessing(),
                          )
                        : const SizedBox.shrink(),
                  ),
                  // 展开/收起切换按钮（左侧中间）
                  Align(
                    alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: () => setState(() => _aiDrawerOpen = !_aiDrawerOpen),
                      child: Container(
                        width: 18, height: 52,
                        decoration: BoxDecoration(
                          color: scheme.surface.withAlpha(200),
                          borderRadius: BorderRadius.circular(0),
                          boxShadow: [BoxShadow(color: Colors.black.withAlpha(40), blurRadius: 6, offset: const Offset(1, 0))],
                        ),
                        child: Icon(
                          _aiDrawerOpen ? Icons.chevron_left : Icons.chevron_right,
                          size: 16,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                ]),
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

  void _onPortDragStart(String nodeId, String portKind) {
    setState(() {
      _dragFromNodeId = nodeId;
      _dragPort = portKind;
    });
  }

  void _onPortDragUpdate(Offset globalPos) {
    setState(() => _dragLineEnd = _canvasFromGlobal(globalPos));
  }

  /// 探测模式：根据鼠标位置判断悬停在哪个端口上，并给出信号提示
  void _updateProbe(Offset localPos) {
    if (!mounted) return;
    try {
      _updateProbeInner(localPos);
    } catch (_) {
      // 探测异常不影响渲染，避免灰屏
      if (mounted && (_probeTooltip != null || _probeTooltipPos != null)) {
        setState(() { _probeTooltip = null; _probeTooltipPos = null; });
      }
    }
  }

  void _updateProbeInner(Offset localPos) {
    final canvasPos = _screenToCanvas(localPos);
    final zh = context.read<AppState>().config.language == 'zh';
    const hitR = 14.0;

    for (final n in _nodes.reversed) {
      if (n.isGate) {
        final g = n.gate;
        if (g == null) continue;
        // 逻辑门输出端口（右侧端口区中心）
        final go = Offset(n.x + _portZoneW + _gateW + _portZoneW / 2, n.y + _gateH / 2);
        if ((canvasPos - go).distance <= hitR) {
          final outVal = _gateOutputValue(n);
          setState(() {
            _probeTooltip = zh ? '输出: ${g.symbol(true)} = $outVal' : 'Output: ${g.symbol(false)} = $outVal';
            _probeTooltipPos = go;
          });
          return;
        }
        // 逻辑门输入端口（spaceEvenly 布局，恒1/恒0 无输入）
        final inputCount = g.inputCount;
        for (var i = 0; i < inputCount; i++) {
          final portY = n.y + _gateH * (i + 1) / (inputCount + 1);
          final gi = Offset(n.x + _portZoneW / 2, portY);
          if ((canvasPos - gi).distance <= hitR) {
            final v = _gateInputValue(n, i);
            setState(() {
              _probeTooltip = zh ? '输入$i: $v' : 'Input$i: $v';
              _probeTooltipPos = gi;
            });
            return;
          }
        }
      } else {
        // 普通节点：端口列垂直居中于 _nodeH，上下两个 16px 圆点
        final colTop = n.y + (_nodeH - 38) / 2;
        const dotR = 8.0;
        const gap = 6.0;
        final dot1Y = colTop + dotR;
        final dot2Y = colTop + 16 + gap + dotR;
        final rx = n.x + 16 + _nodeWFor(n.type) + 8;
        final lx = n.x + 8;
        // 右侧：数据输出(上) / 状态输出(下)
        final dataOut = Offset(rx, dot1Y);
        if ((canvasPos - dataOut).distance <= hitR && n.hasOutput) {
          setState(() {
            _probeTooltip = zh ? '数据输出: ${n.outputType?.name ?? '?'}' : 'Data out: ${n.outputType?.name ?? '?'}';
            _probeTooltipPos = dataOut;
          });
          return;
        }
        final statusOut = Offset(rx, dot2Y);
        if ((canvasPos - statusOut).distance <= hitR && n.type != PipelineStepType.start) {
          setState(() {
            _probeTooltip = zh ? '状态输出: 1 (成功)' : 'Status out: 1 (success)';
            _probeTooltipPos = statusOut;
          });
          return;
        }
        // 左侧：数据输入(上) / 使能输入(下)
        final dataIn = Offset(lx, dot1Y);
        if ((canvasPos - dataIn).distance <= hitR && n.hasInput) {
          setState(() {
            _probeTooltip = zh ? '数据输入: ${n.inputTypes.isNotEmpty ? n.inputTypes.first.name : '?'}' : 'Data in: ${n.inputTypes.isNotEmpty ? n.inputTypes.first.name : '?'}';
            _probeTooltipPos = dataIn;
          });
          return;
        }
        final enableIn = Offset(lx, dot2Y);
        if ((canvasPos - enableIn).distance <= hitR && n.type != PipelineStepType.start) {
          setState(() {
            _probeTooltip = zh ? '使能输入: 1 (悬空默认)' : 'Enable in: 1 (default)';
            _probeTooltipPos = enableIn;
          });
          return;
        }
      }
    }
    // 没有悬停在端口上
    if (_probeTooltip != null || _probeTooltipPos != null) {
      setState(() { _probeTooltip = null; _probeTooltipPos = null; });
    }
  }

  /// 计算逻辑门输入信号值（带防环）
  String _gateInputValue(PipelineNode n, int index) {
    final conns = _connections.where((c) => c.toNodeId == n.id && c.kind == 'control').toList();
    if (index < conns.length) {
      final src = _nodes.where((s) => s.id == conns[index].fromNodeId).firstOrNull;
      if (src != null && src.isGate) {
        return _gateOutputValue(src, <String>{n.id});
      }
      return '1';
    }
    return '?';
  }

  /// 计算逻辑门输出信号值（根据输入与门类型），visited 防止环路导致栈溢出
  String _gateOutputValue(PipelineNode n, [Set<String>? visited]) {
    final v = visited ?? <String>{};
    if (v.contains(n.id)) return '?'; // 检测到环路，返回未知
    v.add(n.id);
    try {
      final g = n.gate;
      if (g == null) return '?';
      if (g.isConstant) {
        return g == LogicGateType.const1 ? '1' : '0';
      }
      final inputs = _connections.where((c) => c.toNodeId == n.id && c.kind == 'control').toList();
      final values = inputs.map((c) {
        final src = _nodes.where((s) => s.id == c.fromNodeId).firstOrNull;
        if (src != null && src.isGate) {
          return int.tryParse(_gateOutputValue(src, v)) ?? 0;
        }
        // 状态输出源视为 1
        return 1;
      }).toList();
      if (values.isEmpty) return '?';
      final all1 = values.every((x) => x == 1);
      final any1 = values.any((x) => x == 1);
      switch (g) {
        case LogicGateType.and: return all1 ? '1' : '0';
        case LogicGateType.or: return any1 ? '1' : '0';
        case LogicGateType.nand: return all1 ? '0' : '1';
        case LogicGateType.nor: return any1 ? '0' : '1';
        case LogicGateType.not: return values.first == 1 ? '0' : '1';
        case LogicGateType.xor: return values.where((x) => x == 1).length % 2 == 1 ? '1' : '0';
        case LogicGateType.xnor: return values.where((x) => x == 1).length % 2 == 1 ? '0' : '1';
        case LogicGateType.timeTrigger: return _timeTriggerValue(n);
        default: return '?';
      }
    } finally {
      v.remove(n.id);
    }
  }

  /// 时间触发器：根据节点参数（日期/起始时间/结束时间）判断当前系统时间是否命中。
  /// 参数：tt_date(yyyy-MM-dd，空=每天), tt_start(HH:mm), tt_end(HH:mm，空=精确时刻)
  String _timeTriggerValue(PipelineNode n) {
    final now = DateTime.now();
    final dateStr = (n.params['tt_date'] as String?) ?? '';
    if (dateStr.isNotEmpty) {
      final today = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      if (today != dateStr) return '0';
    }
    final start = (n.params['tt_start'] as String?) ?? '';
    if (start.isEmpty) return '0';
    final s = _parseHM(start);
    final cur = now.hour * 60 + now.minute;
    final end = (n.params['tt_end'] as String?) ?? '';
    if (end.isEmpty) return cur == s ? '1' : '0';
    final e = _parseHM(end);
    if (s <= e) return (cur >= s && cur <= e) ? '1' : '0';
    // 跨天范围（如 22:00-06:00）
    return (cur >= s || cur <= e) ? '1' : '0';
  }

  int _parseHM(String hm) {
    final parts = hm.split(':');
    if (parts.length != 2) return -1;
    return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
  }

  /// 时间触发器配置对话框：日期选择器 + 时间选择器

  /// 逻辑门信息编辑器（非时间触发器的普通门）：显示 ANSI 符号、功能说明、
  /// 真值表与端口说明。参数不可编辑，仅展示信息。
  Widget _buildGateInfoEditor(PipelineNode node, bool isZh) {
    final scheme = Theme.of(context).colorScheme;
    final gate = node.gate!;
    final iec = context.read<AppState>().config.gateStd == 'iec';
    final zh = isZh;

    final (String name, String desc, List<List<String>> truthTable) = switch (gate) {
      LogicGateType.and => (
        zh ? '与门 (AND)' : 'AND Gate',
        zh ? '所有输入为 1 时输出 1，否则输出 0' : 'Outputs 1 only when ALL inputs are 1',
        [
          [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
          ['0 · 0', '0'],
          ['0 · 1', '0'],
          ['1 · 0', '0'],
          ['1 · 1', '1'],
        ],
      ),
      LogicGateType.or => (
        zh ? '或门 (OR)' : 'OR Gate',
        zh ? '任一输入为 1 时输出 1，否则输出 0' : 'Outputs 1 when ANY input is 1',
        [
          [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
          ['0 · 0', '0'],
          ['0 · 1', '1'],
          ['1 · 0', '1'],
          ['1 · 1', '1'],
        ],
      ),
      LogicGateType.not => (
        zh ? '非门 (NOT)' : 'NOT Gate',
        zh ? '输入取反：输入 1 输出 0，输入 0 输出 1' : 'Inverts the input signal',
        [
          [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
          ['0', '1'],
          ['1', '0'],
        ],
      ),
      LogicGateType.nand => (
        zh ? '与非门 (NAND)' : 'NAND Gate',
        zh ? '与门的取反：所有输入为 1 时输出 0，否则输出 1' : 'AND then inverted: outputs 0 only when ALL inputs are 1',
        [
          [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
          ['0 · 0', '1'],
          ['0 · 1', '1'],
          ['1 · 0', '1'],
          ['1 · 1', '0'],
        ],
      ),
      LogicGateType.nor => (
        zh ? '或非门 (NOR)' : 'NOR Gate',
        zh ? '或门的取反：任一输入为 1 时输出 0，否则输出 1' : 'OR then inverted: outputs 0 when ANY input is 1',
        [
          [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
          ['0 · 0', '1'],
          ['0 · 1', '0'],
          ['1 · 0', '0'],
          ['1 · 1', '0'],
        ],
      ),
      LogicGateType.xor => (
        zh ? '异或门 (XOR)' : 'XOR Gate',
        zh ? '输入不同时输出 1，相同时输出 0' : 'Outputs 1 when inputs differ, 0 when they match',
        [
          [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
          ['0 · 0', '0'],
          ['0 · 1', '1'],
          ['1 · 0', '1'],
          ['1 · 1', '0'],
        ],
      ),
      LogicGateType.xnor => (
        zh ? '同或门 (XNOR)' : 'XNOR Gate',
        zh ? '输入相同时输出 1，不同时输出 0' : 'Outputs 1 when inputs match, 0 when they differ',
        [
          [zh ? '输入' : 'IN', zh ? '输出' : 'OUT'],
          ['0 · 0', '1'],
          ['0 · 1', '0'],
          ['1 · 0', '0'],
          ['1 · 1', '1'],
        ],
      ),
      LogicGateType.const1 => (
        zh ? '恒 1 (HIGH)' : 'Constant 1 (HIGH)',
        zh ? '恒定输出 1，无需输入，常用于强制启用下游' : 'Always outputs 1, no inputs needed',
        [
          [zh ? '输出' : 'OUT'],
          ['1'],
        ],
      ),
      LogicGateType.const0 => (
        zh ? '恒 0 (LOW)' : 'Constant 0 (LOW)',
        zh ? '恒定输出 0，无需输入，常用于禁用下游' : 'Always outputs 0, no inputs needed',
        [
          [zh ? '输出' : 'OUT'],
          ['0'],
        ],
      ),
      LogicGateType.timeTrigger => (
        zh ? '时间触发器' : 'Time Trigger',
        '',
        const [],
      ),
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 标题 + 符号
        Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withAlpha(160),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.tertiary.withAlpha(100)),
            ),
            child: _gateIcon(gate, iec, scheme, width: 44, height: 44),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(fontSize: 11, color: scheme.outline, height: 1.4)),
          ])),
        ]),
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 12),

        // 端口信息
        _infoRow(scheme, Icons.login, zh ? '输入端口' : 'Inputs',
            gate.isConstant
                ? (zh ? '无（恒值输出）' : 'None (constant output)')
                : '${gate.inputCount} × ${zh ? '红色逻辑端口' : 'red logic port'}'),
        const SizedBox(height: 8),
        _infoRow(scheme, Icons.logout, zh ? '输出端口' : 'Output',
            zh ? '1 × 右侧红色逻辑端口' : '1 × red logic port on the right'),

        // 真值表
        if (truthTable.length > 1) ...[
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Text(zh ? '真值表' : 'Truth Table',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const SizedBox(height: 8),
          Center(child: _truthTable(scheme, truthTable)),
        ],
      ]),
    );
  }

  Widget _infoRow(ColorScheme scheme, IconData icon, String label, String value) {
    return Row(children: [
      Icon(icon, size: 14, color: scheme.primary),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      const Spacer(),
      Flexible(child: Text(value, textAlign: TextAlign.right,
          style: TextStyle(fontSize: 12, color: scheme.onSurface))),
    ]);
  }

  Widget _truthTable(ColorScheme scheme, List<List<String>> rows) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(60),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Table(
        columnWidths: const {0: FlexColumnWidth(), 1: FlexColumnWidth()},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder.all(color: scheme.outlineVariant.withAlpha(80), width: 0.8),
        children: [
          for (var i = 0; i < rows.length; i++)
            TableRow(
              decoration: BoxDecoration(
                color: i == 0 ? scheme.primaryContainer.withAlpha(120) : null,
              ),
              children: rows[i].map((cell) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Text(cell, textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: i == 0 ? scheme.onPrimaryContainer : scheme.onSurface,
                      fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w400,
                      fontFamily: AppTheme.monoFont,
                    )),
              )).toList(),
            ),
        ],
      ),
    );
  }

  DateTime? _parseDate(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  /// 逻辑门节点的属性面板标题
  String _gatePropertyTitle(PipelineNode node, AppStrings s) {
    final gate = node.gate;
    if (gate == null) return s.isZh ? '逻辑门' : 'Logic Gate';
    return switch (gate) {
      LogicGateType.and => s.isZh ? '与门 (AND)' : 'AND Gate',
      LogicGateType.or => s.isZh ? '或门 (OR)' : 'OR Gate',
      LogicGateType.not => s.isZh ? '非门 (NOT)' : 'NOT Gate',
      LogicGateType.nand => s.isZh ? '与非门 (NAND)' : 'NAND Gate',
      LogicGateType.nor => s.isZh ? '或非门 (NOR)' : 'NOR Gate',
      LogicGateType.xor => s.isZh ? '异或门 (XOR)' : 'XOR Gate',
      LogicGateType.xnor => s.isZh ? '同或门 (XNOR)' : 'XNOR Gate',
      LogicGateType.const1 => s.isZh ? '恒 1' : 'Constant 1',
      LogicGateType.const0 => s.isZh ? '恒 0' : 'Constant 0',
      LogicGateType.timeTrigger => s.isZh ? '时间触发器' : 'Time Trigger',
    };
  }

  /// 时间触发器右面板编辑器（日期/时间选择，实时修改节点参数）
  Widget _buildTimeTriggerEditor(PipelineNode node, bool isZh) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    var dateStr = (node.params['tt_date'] as String?) ?? '';
    var startStr = (node.params['tt_start'] as String?) ?? '09:00';
    var endStr = (node.params['tt_end'] as String?) ?? '';
    final startHM = _parseHM(startStr);
    var startTime = startHM >= 0 ? TimeOfDay(hour: startHM ~/ 60, minute: startHM % 60) : const TimeOfDay(hour: 9, minute: 0);
    final endHM = _parseHM(endStr);
    var endTime = endHM >= 0 ? TimeOfDay(hour: endHM ~/ 60, minute: endHM % 60) : null;

    void doSave() {
      _pushUndo();
      setState(() {
        node.params['tt_date'] = dateStr;
        node.params['tt_start'] = '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}';
        if (endTime != null) {
          node.params['tt_end'] = '${endTime!.hour.toString().padLeft(2, '0')}:${endTime!.minute.toString().padLeft(2, '0')}';
        } else {
          node.params.remove('tt_end');
        }
      });
      _saveGraph();
    }

    return StatefulBuilder(
      builder: (ctx, setDlg) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 日期卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withAlpha(50),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.primary.withAlpha(60)),
            ),
            child: Row(children: [
              Icon(Icons.calendar_today_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(isZh ? '日期' : 'Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                const SizedBox(height: 2),
                GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: _parseDate(dateStr) ?? now,
                      firstDate: DateTime(now.year - 1),
                      lastDate: DateTime(now.year + 2),
                    );
                    if (picked != null) {
                      setDlg(() => dateStr = '${picked.year.toString().padLeft(4, '0')}-'
                          '${picked.month.toString().padLeft(2, '0')}-'
                          '${picked.day.toString().padLeft(2, '0')}');
                      doSave();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.surface.withAlpha(160),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      dateStr.isEmpty ? (isZh ? '每天（不限日期）' : 'Every day (no date)') : dateStr,
                      style: TextStyle(fontSize: 12, color: dateStr.isEmpty ? scheme.outline : scheme.primary),
                    ),
                  ),
                ),
              ])),
              if (dateStr.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () { setDlg(() => dateStr = ''); doSave(); },
                  tooltip: isZh ? '清除日期' : 'Clear',
                ),
            ]),
          ),
          const SizedBox(height: 10),

          // 起始时间卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer.withAlpha(50),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.secondary.withAlpha(60)),
            ),
            child: Row(children: [
              Icon(Icons.play_arrow, size: 18, color: scheme.secondary),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(isZh ? '起始时间' : 'Start Time', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                const SizedBox(height: 2),
                GestureDetector(
                  onTap: () async {
                    final t = await showTimePicker(context: ctx, initialTime: startTime, initialEntryMode: TimePickerEntryMode.input);
                    if (t != null) { setDlg(() => startTime = t); doSave(); }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.surface.withAlpha(160),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.schedule, size: 14),
                      const SizedBox(width: 4),
                      Text('${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
                ),
              ])),
            ]),
          ),
          const SizedBox(height: 10),

          // 结束时间卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: endTime != null ? scheme.tertiaryContainer.withAlpha(50) : scheme.surfaceContainerHighest.withAlpha(30),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: endTime != null ? scheme.tertiary.withAlpha(60) : scheme.outlineVariant.withAlpha(60)),
            ),
            child: Row(children: [
              Icon(Icons.stop, size: 18, color: endTime != null ? scheme.tertiary : scheme.outline),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(isZh ? '结束时间' : 'End Time', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                const SizedBox(height: 2),
                if (endTime == null)
                  GestureDetector(
                    onTap: () { setDlg(() => endTime = TimeOfDay(hour: startTime.hour, minute: (startTime.minute + 1) % 60)); doSave(); },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: scheme.surface.withAlpha(160),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(isZh ? '精确时刻（无结束时间）' : 'Exact moment (no end)',
                          style: TextStyle(fontSize: 11, color: scheme.outline)),
                    ),
                  )
                else
                  Row(children: [
                    GestureDetector(
                      onTap: () async {
                        final t = await showTimePicker(context: ctx, initialTime: endTime!, initialEntryMode: TimePickerEntryMode.input);
                        if (t != null) { setDlg(() => endTime = t); doSave(); }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: scheme.surface.withAlpha(160),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.schedule, size: 14),
                          const SizedBox(width: 4),
                          Text('${endTime!.hour.toString().padLeft(2, '0')}:${endTime!.minute.toString().padLeft(2, '0')}',
                              style: const TextStyle(fontSize: 13)),
                        ]),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () { setDlg(() => endTime = null); doSave(); },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: scheme.error.withAlpha(30),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(Icons.close, size: 14, color: scheme.error),
                      ),
                    ),
                  ]),
              ])),
            ]),
          ),
          const SizedBox(height: 12),

          // 说明
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(60),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 14, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(
                isZh ? '当系统时间匹配日期和起始时间范围时，输出 1（控制信号高电平），否则输出 0。'
                    '无结束时间时，仅在起始时精确时刻输出 1。'
                  : 'Outputs 1 (control signal HIGH) when system time matches the date and time range. '
                    'Without end time, outputs 1 at the exact start time.',
                style: TextStyle(fontSize: 11, color: scheme.outline, height: 1.4),
              )),
            ]),
          ),
        ]),
      ),
    );
  }

  /// 计算拖拽连线的起点端口坐标
  /// 端口布局：左侧上方=数据输入，左侧下方=使能输入（红），
  /// 右侧上方=数据输出，右侧下方=状态输出（红）
  Offset _dragLineStart() {
    if (_dragFromNodeId == null) return Offset.zero;
    final node = _nodes.firstWhere((n) => n.id == _dragFromNodeId, orElse: () => PipelineNode(id: '', type: PipelineStepType.start));

    // 逻辑门节点
    if (node.isGate) {
      final g = node.gate;
      final inputCount = g?.inputCount ?? 0;
      if (_dragPort == 'gateOut') {
        return Offset(node.x + _portZoneW + _gateW + _portZoneW / 2, node.y + _gateH / 2);
      }
      // gateIn：第一个输入圆圈位置（spaceEvenly）
      if (inputCount > 0) {
        return Offset(node.x + _portZoneW / 2, node.y + _gateH / (inputCount + 1));
      }
      return Offset(node.x + _portZoneW / 2, node.y + _gateH / 2);
    }

    // 普通节点：端口列垂直居中于 _nodeH，上下两个 16px 圆点
    final colTop = node.y + (_nodeH - 38) / 2;
    const dotR = 8.0;
    const gap = 6.0;
    final dot1Y = colTop + dotR;              // 上方圆点（数据）
    final dot2Y = colTop + 16 + gap + dotR;   // 下方圆点（控制）
    switch (_dragPort) {
      case 'dataOut':
        return Offset(node.x + 16 + _nodeWFor(node.type) + 8, dot1Y);
      case 'dataIn':
        return Offset(node.x + 8, dot1Y);
      case 'statusOut':
        return Offset(node.x + 16 + _nodeWFor(node.type) + 8, dot2Y);
      case 'enableIn':
        return Offset(node.x + 8, dot2Y);
      default:
        return Offset(node.x, node.y);
    }
  }

  void _onPortDragEnd() {    if (_dragFromNodeId != null && _dragLineEnd != null) {
      final target = _findNodeAtCanvasPos(_dragLineEnd!);
      if (target != null && target.id != _dragFromNodeId) {
        // 根据端口类型决定连接方向和类型
        switch (_dragPort) {
          case 'dataOut':
            _addConnection(_dragFromNodeId!, target.id, 'data');
          case 'dataIn':
            _addConnection(target.id, _dragFromNodeId!, 'data');
          case 'statusOut':
            // 状态输出 → 使能输入 / 逻辑门输入
            _addConnection(_dragFromNodeId!, target.id, 'control');
          case 'enableIn':
            // 使能输入 ← 来自状态输出或逻辑门输出
            _addConnection(target.id, _dragFromNodeId!, 'control');
          case 'gateOut':
            _addConnection(_dragFromNodeId!, target.id, 'control');
          case 'gateIn':
            _addConnection(target.id, _dragFromNodeId!, 'control');
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
    if (node.isGate && node.gate != null) {
      return _buildGateWidget(node, node.gate!, selected, scheme, s);
    }

    // 端口构建器：isOutput=true 右侧，false 左侧；isControl=true 红色控制端口
    Widget portCircle(bool isOutput, bool isControl) {
      // 隐藏逻辑模式下不显示红色控制端口
      if (_hideLogic && isControl) return const SizedBox(width: 16, height: 16);
      final hasPort = isControl
          ? (isOutput
              ? node.type != PipelineStepType.start // 状态输出：非起始节点
              : node.type != PipelineStepType.start) // 使能输入：非起始节点
          : (isOutput ? node.hasOutput : node.hasInput);
      final portKind = isControl
          ? (isOutput ? 'statusOut' : 'enableIn')
          : (isOutput ? 'dataOut' : 'dataIn');
      final portColor = isControl
          ? const Color(0xFFD32F2F) // 红色控制端口
          : (isOutput ? scheme.primary : scheme.secondary);
      return GestureDetector(
        onPanStart: hasPort ? (_) => _onPortDragStart(node.id, portKind) : null,
        onPanUpdate: hasPort ? (d) => _onPortDragUpdate(d.globalPosition) : null,
        onPanEnd: hasPort ? (_) => _onPortDragEnd() : null,
        child: MouseRegion(
          cursor: hasPort ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Container(
            width: 16, height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasPort ? portColor : Colors.transparent,
              border: hasPort ? Border.all(color: scheme.surface, width: 2) : null,
              boxShadow: hasPort && isControl ? [BoxShadow(color: portColor.withAlpha(60), blurRadius: 4)] : null,
            ),
          ),
        ),
      );
    }

    // 左侧端口列（上方=数据输入，下方=使能输入）
    Widget leftPorts = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        portCircle(false, false), // 数据输入
        const SizedBox(height: 6),
        portCircle(false, true),  // 使能输入（红）
      ],
    );

    // 右侧端口列（上方=数据输出，下方=状态输出）
    Widget rightPorts = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        portCircle(true, false),  // 数据输出
        const SizedBox(height: 6),
        portCircle(true, true),   // 状态输出（红）
      ],
    );

    // 源节点特殊处理：左侧无端口（无数据输入、无使能输入）
    if (node.type == PipelineStepType.start) {
      leftPorts = Column(mainAxisSize: MainAxisSize.min, children: [
        portCircle(false, false), // 数据输入（隐藏）
        const SizedBox(height: 6),
        portCircle(false, true),  // 使能输入（隐藏）
      ]);
    }
    // 输出节点特殊处理：右侧无端口（无数据输出），但有状态输出
    if (node.type == PipelineStepType.output) {
      rightPorts = Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
        portCircle(true, false),  // 数据输出（隐藏）
        const SizedBox(height: 6),
        portCircle(true, true),   // 状态输出（红）
      ]);
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
                if (_selectedNodeIds.contains(node.id)) {
                  _selectedNodeIds.remove(node.id);
                  _lastSelectedId = _selectedNodeIds.isEmpty ? null : _selectedNodeIds.last;
                } else {
                  _selectedNodeIds.add(node.id);
                  _lastSelectedId = node.id;
                }
              } else {
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
                for (final n in _nodes) {
                  if (_selectedNodeIds.contains(n.id)) { n.x += dx; n.y += dy; }
                }
              } else { node.x += dx; node.y += dy; }
            });
          },
          onPanEnd: (_) => _markDirty(),
          onSecondaryTapUp: (d) => _showNodeMenu(d.globalPosition, node.id),
          onLongPressStart: isMobilePlatform
              ? (d) => _showNodeMenu(d.globalPosition, node.id)
              : null,
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
                      fontWeight: FontWeight.w600, color: scheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                  )),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [leftPorts, centerZone(), rightPorts],
    );
  }

  /// 逻辑门图标：ANSI/IEEE 使用 tabler-icons 的 outline 矢量图（MIT 许可，出处见「关于 → 引用」），
  /// IEC 及恒1/恒0/时间触发器沿用程序化绘制。
  Widget _gateIcon(LogicGateType gate, bool iec, ColorScheme scheme, {required double width, required double height}) {
    if (!iec) {
      final name = switch (gate) {
        LogicGateType.and => 'and',
        LogicGateType.or => 'or',
        LogicGateType.not => 'not',
        LogicGateType.nand => 'nand',
        LogicGateType.nor => 'nor',
        LogicGateType.xor => 'xor',
        LogicGateType.xnor => 'xnor',
        _ => null,
      };
      if (name != null) {
        return SvgPicture.asset(
          'rele/logic_gates/$name.svg',
          width: width,
          height: height,
          colorFilter: ColorFilter.mode(scheme.onTertiaryContainer, BlendMode.srcIn),
        );
      }
    }
    return CustomPaint(
      size: Size(width, height),
      painter: GateSymbolPainter(
        gate: gate, iec: iec,
        color: scheme.onTertiaryContainer,
      ),
    );
  }

  /// 构建逻辑门节点 widget（比常规节点小，ANSI 符号绘制）
  Widget _buildGateWidget(PipelineNode node, LogicGateType gate, bool selected, ColorScheme scheme, AppStrings s) {
    final inputCount = gate.inputCount;
    // 符号标准：ANSI/IEEE（特色形状）或 IEC（矩形框）
    final iec = context.read<AppState>().config.gateStd == 'iec';

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
              if (_selectedNodeIds.contains(node.id)) {
                _selectedNodeIds.remove(node.id);
                _lastSelectedId = _selectedNodeIds.isEmpty ? null : _selectedNodeIds.last;
              } else {
                _selectedNodeIds.add(node.id);
                _lastSelectedId = node.id;
              }
            } else {
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
              for (final n in _nodes) {
                if (_selectedNodeIds.contains(n.id)) {
                  n.x += dx;
                  n.y += dy;
                }
              }
            } else {
              node.x += dx;
              node.y += dy;
            }
          });
        },
        onPanEnd: (_) => _markDirty(),
        onSecondaryTapUp: (d) => _showNodeMenu(d.globalPosition, node.id),
          onLongPressStart: isMobilePlatform
              ? (d) => _showNodeMenu(d.globalPosition, node.id)
              : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 左侧输入端口（AND/OR/NAND/NOR=2个，NOT=1个，const=0个）
            if (inputCount > 0)
              SizedBox(
                width: _portZoneW,
                height: _gateH,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(inputCount, (i) {
                    return GestureDetector(
                      onPanStart: (_) => _onPortDragStart(node.id, 'gateIn'),
                      onPanUpdate: (d) => _onPortDragUpdate(d.globalPosition),
                      onPanEnd: (_) => _onPortDragEnd(),
                      child: Container(
                        width: 14, height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFD32F2F), // 红色逻辑端口
                          border: Border.all(color: scheme.surface, width: 1.5),
                        ),
                      ),
                    );
                  }),
                ),
              )
            else
              const SizedBox(width: _portZoneW, height: _gateH),
            // 中心：ANSI 符号
            GestureDetector(
              onPanStart: (_) => _pushUndo(),
              onPanUpdate: (d) {
                final scale = _transformCtrl.value.getMaxScaleOnAxis();
                final dx = d.delta.dx / scale;
                final dy = d.delta.dy / scale;
                setState(() {
                  if (_selectedNodeIds.contains(node.id)) {
                    for (final n in _nodes) {
                      if (_selectedNodeIds.contains(n.id)) {
                        n.x += dx;
                        n.y += dy;
                      }
                    }
                  } else {
                    node.x += dx;
                    node.y += dy;
                  }
                });
              },
              onPanEnd: (_) => _markDirty(),
              child: Container(
                width: _gateW,
                height: _gateH,
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer.withAlpha(selected ? 220 : 160),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? scheme.tertiary : scheme.tertiary.withAlpha(80),
                    width: selected ? 2 : 1,
                  ),
                ),
                child: gate == LogicGateType.timeTrigger
                    ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        _gateIcon(gate, iec, scheme, width: _gateW, height: _gateH - 18),
                        const SizedBox(height: 1),
                        // FittedBox.scaleDown：字号被全局放大后仍能等比缩回，避免文字被 64px 容器裁切
                        Flexible(
                          fit: FlexFit.loose,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(s.isZh ? '时间触发' : 'Time Trigger',
                                maxLines: 1,
                                style: TextStyle(fontSize: 10, color: scheme.onTertiaryContainer, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ])
                    : Center(
                        child: _gateIcon(gate, iec, scheme, width: _gateW, height: _gateH),
                      ),
              ),
            ),
            // 右侧输出端口
            SizedBox(
              width: _portZoneW,
              height: _gateH,
              child: Center(
                child: GestureDetector(
                  onPanStart: (_) => _onPortDragStart(node.id, 'gateOut'),
                  onPanUpdate: (d) => _onPortDragUpdate(d.globalPosition),
                  onPanEnd: (_) => _onPortDragEnd(),
                  child: Container(
                    width: 16, height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFD32F2F), // 红色逻辑端口
                      border: Border.all(color: scheme.surface, width: 1.5),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  PipelineNode? _findNodeAtCanvasPos(Offset pos) {
    for (final n in _nodes.reversed) {
      if (pos.dx >= n.x && pos.dx <= n.x + _totalNodeWidth(n) && pos.dy >= n.y && pos.dy <= n.y + _nodeHeight(n)) {
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
      const dividerH = 10.0;
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
                // 逻辑门分组
                const SizedBox(height: 4),
                Wrap(spacing: 3, runSpacing: 3, children: [
                  for (final g in LogicGateType.values) _buildGateToolboxItem(g, scheme, s),
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

        // ── 可拖动分割线（元素 / 属性之间调整大小） ──
        MouseRegion(
          cursor: SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) => setState(() {
              _toolboxFraction = ((_toolboxFraction * usable + d.delta.dy) / usable).clamp(0.15, 0.85);
            }),
            child: Container(
              height: 10,
              color: Colors.transparent,
              child: Center(child: Container(
                width: 44, height: 4,
                decoration: BoxDecoration(
                  color: scheme.primary.withAlpha(90),
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
                    ? (node.isGate && node.gate != null
                        ? _gatePropertyTitle(node, s)
                        : (s.isZh ? node.label : node.labelEn))
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
                      onChanged: () { setState(() {}); _markDirty(); },
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
    return Draggable<Object>(
      data: t,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          // 移动端：芯片保持比例（方正胶囊，不压扁），字号/内边距仍可读。
          padding: EdgeInsets.symmetric(horizontal: isMobilePlatform ? 8 : 10, vertical: isMobilePlatform ? 6 : 6),
          decoration: BoxDecoration(color: _nodeColor(t, scheme), borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_stepIcon(t), size: isMobilePlatform ? 12 : 14, color: scheme.onSurface),
            SizedBox(width: isMobilePlatform ? 3 : 4),
            Text(s.isZh ? dummy.label : dummy.labelEn, style: TextStyle(fontSize: isMobilePlatform ? 9 : 11, color: scheme.onSurface, decoration: TextDecoration.none)),
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
        padding: EdgeInsets.symmetric(horizontal: isMobilePlatform ? 8 : 10, vertical: isMobilePlatform ? 5 : 5),
        decoration: BoxDecoration(
          color: isSelected ? Colors.red.withAlpha(60) : Colors.red.withAlpha(30),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isSelected ? Colors.red : Colors.red.withAlpha(80), width: isSelected ? 2 : 1),
          boxShadow: isSelected ? [BoxShadow(color: Colors.red.withAlpha(40), blurRadius: 6)] : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: isMobilePlatform ? 12 : 14, color: Colors.red),
          SizedBox(width: isMobilePlatform ? 3 : 4),
          Text(label, style: TextStyle(fontSize: isMobilePlatform ? 9 : 12, color: scheme.onSurface)),
        ]),
      ),
    );
  }

  /// 构建逻辑门工具箱项（可拖拽到画布）
  Widget _buildGateToolboxItem(LogicGateType gate, ColorScheme scheme, AppStrings s) {
    final sym = gate.symbol(s.isZh);
    return Draggable<Object>(
      data: gate,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: isMobilePlatform ? 7 : 8, vertical: isMobilePlatform ? 4 : 4),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer.withAlpha(180),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: scheme.tertiary.withAlpha(120)),
          ),
          child: Text(sym, style: TextStyle(fontSize: isMobilePlatform ? 10 : 11, fontWeight: FontWeight.w700, color: scheme.onTertiaryContainer, decoration: TextDecoration.none)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: _gateChip(gate, scheme, s)),
      child: _gateChip(gate, scheme, s),
    );
  }

  Widget _gateChip(LogicGateType gate, ColorScheme scheme, AppStrings s) {
    final sym = gate.symbol(s.isZh);
    final name = gate.name.toUpperCase();
    return Tooltip(
      message: name,
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isMobilePlatform ? 6 : 7, vertical: isMobilePlatform ? 3 : 3),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer.withAlpha(gate.isConstant ? 120 : 80),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: scheme.tertiary.withAlpha(60)),
        ),
        child: Text(sym, style: TextStyle(fontSize: isMobilePlatform ? 9 : 10, fontWeight: FontWeight.w700, color: scheme.onTertiaryContainer)),
      ),
    );
  }

  Widget _toolboxChip(PipelineStepType t, PipelineNode dummy, String tag, ColorScheme scheme, AppStrings s, {bool isSelected = false}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.symmetric(horizontal: isMobilePlatform ? 8 : 10, vertical: isMobilePlatform ? 5 : 5),
      decoration: BoxDecoration(
        color: isSelected ? scheme.primary.withAlpha(40) : _nodeColor(t, scheme).withAlpha(180),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isSelected ? scheme.primary : scheme.outlineVariant.withAlpha(60), width: isSelected ? 2 : 1),
        boxShadow: isSelected ? [BoxShadow(color: scheme.primary.withAlpha(40), blurRadius: 6)] : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_stepIcon(t), size: isMobilePlatform ? 12 : 14, color: scheme.onSurface),
        SizedBox(width: isMobilePlatform ? 3 : 4),
        Text(s.isZh ? dummy.label : dummy.labelEn, style: TextStyle(fontSize: isMobilePlatform ? 9 : 12, color: scheme.onSurface)),
        if (tag.isNotEmpty) ...[
          SizedBox(width: isMobilePlatform ? 2 : 4),
          Text(tag, style: TextStyle(fontSize: isMobilePlatform ? 5 : 9, color: scheme.outline, fontWeight: FontWeight.w600)),
        ],
      ]),
    );
  }

  // ── AI 面板构建（移动端底部弹层复用同一套回调接线） ──

  Widget _buildAiPanel(
    AppStrings s, {
    Key? key,
    bool startExpanded = false,
    VoidCallback? onCollapseRequested,
    ValueChanged<String>? onTitleGenerated,
  }) {
    return _AiPanel(
      key: key,
      startExpanded: startExpanded,
      onCollapseRequested: onCollapseRequested,
      onTitleGenerated: onTitleGenerated,
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
          final remappedConns = aiConns.map((c) => (
            from: idRemap[c.fromNodeId] ?? c.fromNodeId,
            to: idRemap[c.toNodeId] ?? c.toNodeId,
          )).toSet();
          final aiNodeIds = remappedConns.expand((c) => [c.from, c.to]).toSet();
          _connections.removeWhere((c) {
            if (!aiNodeIds.contains(c.fromNodeId) || !aiNodeIds.contains(c.toNodeId)) return false;
            if (remappedConns.any((r) => r.from == c.fromNodeId && r.to == c.toNodeId)) return false;
            return true;
          });
          _connections.addAll(newConns);
        });
      },
      onModifyNodeParams: (nodeId, params) {
        _pushUndo();
        setState(() {
          if (_nodes.isEmpty) return;
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
      onAddNode: (type, x, y) {
        final stepType = PipelineStepType.values.firstWhere((t) => t.name == type, orElse: () => throw ArgumentError('Unknown type: $type'));
        final node = PipelineNode(id: _uuid.v4(), type: stepType, x: x, y: y);
        _pushUndo();
        setState(() => _nodes.add(node));
        _saveGraph();
        return node.id;
      },
      onAddGate: (gateName, x, y) {
        final gate = LogicGateType.values.asNameMap()[gateName];
        if (gate == null) throw ArgumentError('Unknown gate type: $gateName');
        final node = PipelineNode(
          id: _uuid.v4(),
          type: PipelineStepType.start,
          x: x, y: y,
          gateType: gate.name,
        );
        _pushUndo();
        setState(() => _nodes.add(node));
        _saveGraph();
        return node.id;
      },
      onSetGateParams: (nodeId, params) {
        final idx = _nodes.indexWhere((n) => n.id == nodeId);
        if (idx < 0) return false;
        _pushUndo();
        setState(() {
          params.forEach((k, v) { _nodes[idx].params[k] = v; });
        });
        _saveGraph();
        return true;
      },
      onDeleteNode: (nodeId) {
        _deleteNode(nodeId);
        _saveGraph();
      },
      onConnectNodes: (fromId, toId) {
        if (fromId == toId) return false;
        if (!_nodes.any((n) => n.id == fromId) || !_nodes.any((n) => n.id == toId)) return false;
        if (_connections.any((c) => c.fromNodeId == fromId && c.toNodeId == toId)) return false;
        _pushUndo();
        setState(() => _connections.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId)));
        _saveGraph();
        return true;
      },
      onDisconnectNodes: (connId) {
        final idx = _connections.indexWhere((c) => c.id == connId);
        if (idx < 0) return false;
        _pushUndo();
        setState(() => _connections.removeAt(idx));
        _saveGraph();
        return true;
      },
      onCancelTasks: () => context.read<AppState>().cancelProcessing(),
    );
  }

  /// 移动端：打开 AI 助手。竖屏用底部弹层；横屏用从左往右滑入的侧边栏（不满屏）。
  void _openAiSheet(AppStrings s) {
    final scheme = Theme.of(context).colorScheme;
    final panelContent =
        _buildAiPanel(s, key: const ValueKey('ai-sheet'), startExpanded: true);

    Widget header(BuildContext ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(children: [
            Icon(Icons.smart_toy, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(s.aiChatTitle,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface))),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              color: scheme.onSurfaceVariant,
              onPressed: () => Navigator.of(ctx).pop(),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
          ]),
        );

    if (_isLandscape) {
      // 横屏：左侧滑入面板，不占满整个屏幕
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        barrierColor: Colors.black.withValues(alpha: 0.24),
        transitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (ctx, anim, anim2) {
          final w = MediaQuery.of(ctx).size.width;
          final panelW = (w * 0.55).clamp(280.0, 460.0);
          return Align(
            alignment: Alignment.centerLeft,
            child: Material(
              color: Colors.transparent,
              child: Padding(
                // 横屏软键盘弹出时整体上移，避免输入框被键盘遮挡
                padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
                child: Container(
                  width: panelW,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
                    border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    header(ctx),
                    Expanded(child: panelContent),
                  ]),
                ),
              ),
            ),
          );
        },
        transitionBuilder: (ctx, anim, anim2, child) {
          final offset = Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
          return SlideTransition(position: offset, child: child);
        },
      );
      return;
    }

    // 竖屏：底部弹层（顶部留白，可见半透明遮罩后的画布）
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.24),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(ctx).padding.top + 18),
        child: Container(
          height: MediaQuery.of(ctx).size.height * 0.86,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: scheme.outlineVariant.withAlpha(120), borderRadius: BorderRadius.circular(2)),
            ),
            header(ctx),
            Expanded(child: panelContent),
            // Android 手势导航：isScrollControlled 的底部弹层不会自动避让系统
            // 导航条，这里显式预留底部安全区，避免输入框被手势条遮挡。
            SizedBox(height: MediaQuery.of(ctx).padding.bottom),
          ]),
        ),
      ),
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
      child: ConstrainedBox(
        // 移动端屏幕矮/横屏时，整列工具可能溢出被裁掉（"右侧小工具显示不全"），
        // 用大量高约束 + 可滚动包裹，保证所有按钮始终可达。
        // 移动端横屏可用高度更小，进一步下调系数，避免右侧工具列被裁掉。
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * (isMobilePlatform ? (_isLandscape ? 0.48 : 0.62) : 0.86)),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        // 移动端：返回按钮（舍弃顶部栏后以浮动按钮替代）
        if (isMobilePlatform) ...[
          _controlBtn(Icons.arrow_back, s.isZh ? '返回' : 'Back', scheme, () async {
            final nav = Navigator.of(context);
            if (await _onWillPop()) nav.pop();
          }),
          const SizedBox(height: 2),
          // AI 助手（按钮触发底部弹层，可预览节点编辑器状态）
          if (context.read<AppState>().config.aiEnabled) ...[
            _controlBtn(Icons.smart_toy, s.isZh ? 'AI 助手' : 'AI Assistant', scheme,
                () => _openAiSheet(s), color: scheme.primary),
            const SizedBox(height: 2),
          ],
          // 横竖屏切换（移动端专属）
          _controlBtn(
            _isLandscape ? Icons.phone_android_outlined : Icons.screen_rotation_alt_outlined,
            _isLandscape ? (s.isZh ? '切换到竖屏' : 'Switch to portrait') : (s.isZh ? '切换到横屏' : 'Switch to landscape'),
            scheme, _toggleOrientation,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, color: scheme.outlineVariant.withAlpha(60)),
          ),
        ],
        // 放大缩小改在画布左下角浮动按钮；移动端右侧工具列不再重复（避免误触）。
        _controlBtn(Icons.auto_fix_high, s.isZh ? '整理' : 'Arrange', scheme, _autoLayout),
        const SizedBox(height: 2),
        _controlBtn(Icons.my_location, s.isZh ? '定位源' : 'Source', scheme, () => _goToSource(s)),
          ]),
        ),
      ),
    );
  }

  Widget _controlBtn(IconData icon, String tooltip, ColorScheme scheme, VoidCallback onTap, {Color? color}) {
    // 移动端横屏：缩小按钮 padding 与图标，降低整列高度，防止溢出。
    final compact = isMobilePlatform && _isLandscape;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(compact ? 3 : 6),
          child: Icon(icon, size: compact ? 14 : 18, color: color ?? scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  // ── 底栏 ──

  Widget _buildBottomBar(ColorScheme scheme, AppStrings s) {
    final v = widget.video;
    final srcCount = _nodes.where((n) => n.type == PipelineStepType.start && !n.isGate).length;
    final outCount = _nodes.where((n) => n.type == PipelineStepType.output).length;
    final countsText = s.isZh
        ? '${_nodes.length} 节点  |  $srcCount 源  |  $outCount 输出  |  ${_connections.length} 连线'
        : '${_nodes.length} nodes  |  $srcCount src  |  $outCount out  |  ${_connections.length} links';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant.withAlpha(50)))),
      // 移动端：左半文件信息条 + 右半最右为节点/源/输出/连线数据（底部信息条约 1/2 + 数据右置）。
      child: isMobilePlatform
          ? Row(children: [
              Expanded(child: Row(children: [
                Icon(Icons.info_outline, size: 13, color: scheme.outline),
                const SizedBox(width: 5),
                Expanded(
                  child: Text('${v.resolution}  |  ${v.durationStr}  |  ${formatFileSize(v.sizeMb)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.outline, fontSize: 11)),
                ),
                if (_autosaveIndicator) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.cloud_done_outlined, size: 13, color: Colors.green.shade400),
                ],
              ])),
              Flexible(
                child: Text(countsText,
                    textAlign: TextAlign.right,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.outline, fontSize: 11)),
              ),
            ])
          : Row(children: [
              Icon(Icons.info_outline, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Flexible(
                child: Text('${v.resolution}  |  ${v.durationStr}  |  ${formatFileSize(v.sizeMb)}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.outline, fontSize: 12)),
              ),
              if (_autosaveIndicator) ...[
                const SizedBox(width: 12),
                Icon(Icons.cloud_done_outlined, size: 14, color: Colors.green.shade400),
                const SizedBox(width: 4),
                Text(s.isZh ? '已自动保存' : 'Auto-saved',
                    style: TextStyle(fontSize: 10, color: Colors.green.shade400)),
              ],
              const Spacer(),
              Text(countsText, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.outline, fontSize: 11)),
            ]),
    );
  }

  // ── 移动端专用：顶部浮动菜单栏 ──

  Widget _buildMobileTopBar(ColorScheme scheme, AppStrings s) {
    final cfg = context.read<AppState>().config;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surface.withAlpha(220),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
        boxShadow: [BoxShadow(color: scheme.shadow.withAlpha(30), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _mobileBarBtn(Icons.arrow_back, () async {
          final nav = Navigator.of(context);
          if (await _onWillPop()) nav.pop();
        }, scheme, size: 18, pad: 4),
        const SizedBox(width: 2),
        // 撤销/重做：原画布顶部工具栏在移动端移除后，迁移到顶部浮动菜单栏。
        IconButton(
          icon: Icon(Icons.undo, size: 17, color: _undoStack.isEmpty ? scheme.outlineVariant : scheme.onSurfaceVariant),
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          padding: EdgeInsets.zero,
          onPressed: _undoStack.isEmpty ? null : _undo,
        ),
        IconButton(
          icon: Icon(Icons.redo, size: 17, color: _redoStack.isEmpty ? scheme.outlineVariant : scheme.onSurfaceVariant),
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          padding: EdgeInsets.zero,
          onPressed: _redoStack.isEmpty ? null : _redo,
        ),
        const SizedBox(width: 2),
        // 自右下角工具条迁移：自动整理 + 定位源
        _mobileBarBtn(Icons.auto_fix_high, _autoLayout, scheme, size: 18, pad: 4),
        const SizedBox(width: 2),
        _mobileBarBtn(Icons.my_location, () => _goToSource(s), scheme, size: 18, pad: 4),
        const SizedBox(width: 2),
        _mobileBarBtn(
          _mobileToolboxOpen ? Icons.close : Icons.add,
          () => setState(() => _mobileToolboxOpen = !_mobileToolboxOpen),
          scheme, color: scheme.primary, size: 20, pad: 4,
        ),
        if (cfg.aiEnabled) ...[
          const SizedBox(width: 2),
          _mobileBarBtn(Icons.smart_toy, () => _openAiSheet(s), scheme, color: scheme.primary, size: 18, pad: 4),
        ],
        const SizedBox(width: 2),
        _mobileBarBtn(Icons.save_outlined, _save, scheme, size: 18, pad: 4),
        const SizedBox(width: 2),
        SizedBox(
          width: 28, height: 28,
          child: PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            icon: Icon(Icons.more_vert, size: 18, color: scheme.onSurfaceVariant),
            onSelected: (v) {
              switch (v) {
                case 'export':
                  if (_nodes.isNotEmpty) _exportConfig(s);
                  break;
                case 'import':
                  _importConfig(s);
                  break;
                case 'probe':
                  setState(() => _probeMode = !_probeMode);
                  break;
                case 'hide':
                  setState(() => _hideLogic = !_hideLogic);
                  break;
                case 'orientation':
                  _toggleOrientation();
                  break;
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'export', enabled: _nodes.isNotEmpty, child: Row(children: [
                Icon(Icons.file_upload_outlined, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(s.isZh ? '导出配置' : 'Export Config', style: const TextStyle(fontSize: 13)),
              ])),
              PopupMenuItem(value: 'import', child: Row(children: [
                Icon(Icons.file_download_outlined, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(s.importConfig, style: const TextStyle(fontSize: 13)),
              ])),
              PopupMenuItem(value: 'probe', child: Row(children: [
                Icon(Icons.search, size: 16, color: _probeMode ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(s.isZh ? '探测模式' : 'Probe', style: const TextStyle(fontSize: 13)),
                if (_probeMode) ...[const Spacer(), Icon(Icons.check, size: 14, color: scheme.primary)],
              ])),
              PopupMenuItem(value: 'hide', child: Row(children: [
                Icon(Icons.route, size: 16, color: _hideLogic ? scheme.error : scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(s.isZh ? '隐藏逻辑线' : 'Hide logic', style: const TextStyle(fontSize: 13)),
                if (_hideLogic) ...[const Spacer(), Icon(Icons.check, size: 14, color: scheme.error)],
              ])),
              PopupMenuItem(value: 'orientation', child: Row(children: [
                Icon(Icons.screen_rotation, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(_isLandscape ? (s.isZh ? '切换到竖屏' : 'Switch to portrait') : (s.isZh ? '切换到横屏' : 'Switch to landscape'),
                    style: const TextStyle(fontSize: 13)),
              ])),
            ],
          ),
        ),
      ]),
    );
  }

  // ── 移动端专用：底部左侧缩放条 ──

  Widget _buildMobileBottomLeftBar(ColorScheme scheme, AppStrings s) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surface.withAlpha(220),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
        boxShadow: [BoxShadow(color: scheme.shadow.withAlpha(30), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _mobileBarBtn(Icons.zoom_out, () => _zoomTo(_currentScale - 0.15), scheme, size: 16, pad: 4),
        const SizedBox(width: 2),
        _mobileBarBtn(Icons.zoom_in, () => _zoomTo(_currentScale + 0.15), scheme, size: 16, pad: 4),
      ]),
    );
  }

  // ── 移动端专用：底部中央文件信息 ──

  Widget _buildMobileFileInfo(ColorScheme scheme, AppStrings s) {
    final v = widget.video;
    final nodesLabel = s.isZh ? '节点' : 'nodes';
    // 左下缩放悬浮条约占 80px，中央信息条扣除这部分宽度，
    // 避免窄屏下长文本撑满整行，与缩放按钮重叠。
    final reserved = 90.0;
    final maxW = math.max(96.0, MediaQuery.of(context).size.width - reserved);
    return Container(
      height: 24,
      constraints: BoxConstraints(maxWidth: maxW),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withAlpha(180),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '${v.resolution} | ${v.durationStr} | ${formatFileSize(v.sizeMb)} | ${_nodes.length} $nodesLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 9, color: scheme.outline),
      ),
    );
  }

  Widget _mobileBarBtn(IconData icon, VoidCallback onTap, ColorScheme scheme, {Color? color, double size = 20, double pad = 6}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Icon(icon, size: size, color: color ?? scheme.onSurfaceVariant),
      ),
    );
  }

  // ── 移动端专用：工具箱弹出层 ──

  Widget _buildMobileToolboxSheet(ColorScheme scheme, AppStrings s) {
    return GestureDetector(
      onTap: () => setState(() => _mobileToolboxOpen = false),
      child: Container(
        color: Colors.black.withAlpha(120),
        child: GestureDetector(
          onTap: () {},
          child: Center(
            child: Container(
              width: 320,
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surface.withAlpha(240),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
                boxShadow: [BoxShadow(color: scheme.shadow.withAlpha(60), blurRadius: 16, offset: const Offset(0, 4))],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Icon(Icons.widgets_outlined, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(s.isZh ? '添加节点' : 'Add Node',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: scheme.outline),
                    onPressed: () => setState(() => _mobileToolboxOpen = false),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                ]),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        _buildToolboxItem(PipelineStepType.start, scheme, s),
                        _buildToolboxItem(PipelineStepType.output, scheme, s),
                      ]),
                      const SizedBox(height: 10),
                      _categoryLabel(scheme, Icons.videocam_outlined, s.isZh ? '视频' : 'Video'),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final t in _videoTypes) _buildToolboxItem(t, scheme, s),
                      ]),
                      const SizedBox(height: 10),
                      _categoryLabel(scheme, Icons.audiotrack_outlined, s.isZh ? '音频' : 'Audio'),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final t in _audioTypes) _buildToolboxItem(t, scheme, s),
                      ]),
                      const SizedBox(height: 10),
                      _categoryLabel(scheme, Icons.image_outlined, s.isZh ? '图片' : 'Image'),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final t in _imageTypes) _buildToolboxItem(t, scheme, s),
                      ]),
                      const SizedBox(height: 10),
                      _categoryLabel(scheme, Icons.account_tree_outlined, s.isZh ? '逻辑' : 'Logic'),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        _buildLogicToolboxItem(LogicBlockType.loop, scheme, s),
                        _buildLogicToolboxItem(LogicBlockType.selectiveLoop, scheme, s),
                      ]),
                      const SizedBox(height: 6),
                      Wrap(spacing: 4, runSpacing: 4, children: [
                        for (final g in LogicGateType.values) _buildGateToolboxItem(g, scheme, s),
                      ]),
                      if (widget.containerInfo != null) ...[
                        const SizedBox(height: 10),
                        _categoryLabel(scheme, Icons.folder_special_outlined, s.isZh ? '容器' : 'Container'),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final t in _containerTypes) _buildToolboxItem(t, scheme, s),
                        ]),
                      ],
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ── 移动端专用：属性编辑底部弹层 ──

  Widget _buildMobilePropertiesSheet(ColorScheme scheme, AppStrings s) {
    final node = _selectedNode;
    final logicBlock = _selectedLogicBlockId != null
        ? _logicBlocks.where((b) => b.id == _selectedLogicBlockId).firstOrNull
        : null;
    if (node == null && logicBlock == null) return const SizedBox.shrink();

    final title = logicBlock != null
        ? logicBlock.label(s.isZh)
        : node!.isGate && node.gate != null
            ? _gatePropertyTitle(node, s)
            : (s.isZh ? node.label : node.labelEn);

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface.withAlpha(240),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
        boxShadow: [BoxShadow(color: scheme.shadow.withAlpha(60), blurRadius: 16, offset: const Offset(0, -2))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(
            logicBlock != null
                ? (logicBlock.type == LogicBlockType.loop ? Icons.repeat : Icons.shuffle)
                : _stepIcon(node!.type),
            size: 16,
            color: scheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: scheme.outline),
            onPressed: () => setState(() {
              _selectedNodeIds.clear();
              _lastSelectedId = null;
              _selectedLogicBlockId = null;
            }),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ]),
        const SizedBox(height: 8),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(4),
            child: logicBlock != null
                ? LogicBlockEditor(
                    key: ValueKey(logicBlock.id),
                    block: logicBlock,
                    childNodes: _nodes.where((n) => logicBlock.childNodeIds.contains(n.id)).toList(),
                    onChanged: () { setState(() {}); _markDirty(); },
                    isZh: s.isZh,
                  )
                : _buildStepEditor(node!, s.isZh),
          ),
        ),
      ]),
    );
  }
}

// ── 网格背景 ──

class _GridPainter extends CustomPainter {
  final Color color;
  final Color? fill;
  _GridPainter({required this.color, this.fill});

  @override
  void paint(Canvas canvas, Size size) {
    if (fill != null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = fill!);
    }
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
  bool shouldRepaint(_GridPainter old) => old.color != color || old.fill != fill;
}

// ── 连线绘制 ──

class _ConnectionPainter extends CustomPainter {
  final List<PipelineNode> nodes;
  final List<PipelineConnection> connections;
  final Color color;
  final Color controlColor;
  final Set<String> selectedNodeIds;

  _ConnectionPainter({required this.nodes, required this.connections, required this.color,
    required this.selectedNodeIds, this.controlColor = const Color(0xFFFF8F00)});

  @override
  void paint(Canvas canvas, Size size) {
    for (final conn in connections) {
      final fromIdx = nodes.indexWhere((n) => n.id == conn.fromNodeId);
      final toIdx = nodes.indexWhere((n) => n.id == conn.toNodeId);
      if (fromIdx < 0 || toIdx < 0) continue;

      final from = nodes[fromIdx];
      final to = nodes[toIdx];
      final isControl = conn.kind == 'control';
      // 到逻辑门目标时，计算该连线是第几个输入（用于对准圆圈）
      final inputIdx = (isControl && to.isGate)
          ? connections.where((c) => c.toNodeId == conn.toNodeId && c.kind == 'control').toList().indexOf(conn)
          : 0;
      if (inputIdx < 0) continue;

      final p1 = _portPos(from, isOutput: true, isControl: isControl);
      final p2 = _portPos(to, isOutput: false, isControl: isControl, gateInputIndex: inputIdx);

      final highlighted = selectedNodeIds.contains(conn.fromNodeId) || selectedNodeIds.contains(conn.toNodeId);
      final connColor = isControl
          ? (highlighted ? controlColor : controlColor.withAlpha(120))
          : (highlighted ? color : color.withAlpha(80));
      final paint = Paint()
        ..color = connColor
        ..strokeWidth = highlighted ? 2.5 : 1.5
        ..style = PaintingStyle.stroke;

      if (isControl) {
        // 控制连线：正交（曼哈顿）折线，转角圆角，虚线
        final path = _orthogonalPath(p1, p2, radius: 6);
        paint.strokeWidth = highlighted ? 2.0 : 1.2;
        _drawDashedPathOnPath(canvas, path, paint);
      } else {
        // 数据连线：贝塞尔曲线
        final path = _bezierPath(p1, p2);
        canvas.drawPath(path, paint);
      }

      // 箭头（根据路径终点方向）
      double arrowDir;
      if (isControl) {
        final dx = p2.dx - p1.dx;
        const lead = 20.0;
        final midX = p2.dx - (dx >= 0 ? lead : -lead);
        arrowDir = (p2 - Offset(midX, 0)).direction;
      } else {
        final dx = p2.dx - p1.dx;
        final ctrlOffset = dx.abs() * 0.4;
        final sign = dx >= 0 ? 1.0 : -1.0;
        arrowDir = math.atan2(0.0, ctrlOffset * sign);
      }
      final arrowPaint = Paint()..color = connColor..style = PaintingStyle.fill;
      final a1 = Offset(p2.dx - 8 * math.cos(arrowDir - 0.4), p2.dy - 8 * math.sin(arrowDir - 0.4));
      final a2 = Offset(p2.dx - 8 * math.cos(arrowDir + 0.4), p2.dy - 8 * math.sin(arrowDir + 0.4));
      canvas.drawPath(Path()..moveTo(p2.dx, p2.dy)..lineTo(a1.dx, a1.dy)..lineTo(a2.dx, a2.dy)..close(), arrowPaint);
    }
  }

  /// 根据节点类型和连线类型计算端口坐标
  /// 端口布局（与 widget 一致）：
  ///   普通节点左右两侧各有 16px 端口列（上下两个 16px 圆点，间距 6px），
  ///   节点中心区域高 _nodeH，端口列垂直居中。
  ///   左侧上方=数据输入，左侧下方=使能输入（红）
  ///   右侧上方=数据输出，右侧下方=状态输出（红）
  ///   逻辑门：左侧端口区宽 _portZoneW（恒1/恒0 为 4px 占位），多个输入
  ///   用 spaceEvenly 排布；右侧输出端口区宽 _portZoneW。
  Offset _portPos(PipelineNode n, {required bool isOutput, required bool isControl, int gateInputIndex = 0}) {
    // 逻辑门节点
    if (n.isGate) {
      final g = n.gate;
      final inputCount = g?.inputCount ?? 0;
      if (isOutput) {
        // 输出：右侧端口区（恒门左侧占位不同，但右侧端口区相同）
        return Offset(n.x + _portZoneW + _gateW + _portZoneW / 2, n.y + _gateH / 2);
      }
      // 输入：左侧端口区，spaceEvenly 布局的第 gateInputIndex 个圆圈
      if (inputCount == 0) {
        // 恒1/恒0 无输入
        return Offset(n.x + _portZoneW / 2, n.y + _gateH / 2);
      }
      final idx = gateInputIndex.clamp(0, inputCount - 1);
      final cy = n.y + _gateH * (idx + 1) / (inputCount + 1);
      return Offset(n.x + _portZoneW / 2, cy);
    }

    // 普通节点：左/右侧端口列（16px 圆点，两列上下排布，垂直居中）
    // 端口列总高 = 16 + 6 + 16 = 38，垂直居中于 _nodeH=68 → top 偏移 15
    final colTop = n.y + (_nodeH - 38) / 2;
    const dotR = 8.0; // 16px 圆点半径
    const gap = 6.0;
    final dot1Y = colTop + dotR;
    final dot2Y = colTop + 16 + gap + dotR;

    if (isControl) {
      if (isOutput) {
        // 状态输出：右侧下方
        return Offset(n.x + 16 + _nodeWFor(n.type) + 8, dot2Y);
      } else {
        // 使能输入：左侧下方
        return Offset(n.x + 8, dot2Y);
      }
    }
    if (isOutput) {
      // 数据输出：右侧上方
      return Offset(n.x + 16 + _nodeWFor(n.type) + 8, dot1Y);
    } else {
      // 数据输入：左侧上方
      return Offset(n.x + 8, dot1Y);
    }
  }

  /// 数据连线贝塞尔曲线：从 p1 到 p2 的水平弹性曲线
  Path _bezierPath(Offset p1, Offset p2) {
    final dx = p2.dx - p1.dx;
    final ctrlOffset = dx.abs() * 0.4;
    final sign = dx >= 0 ? 1.0 : -1.0;
    return Path()
      ..moveTo(p1.dx, p1.dy)
      ..cubicTo(p1.dx + ctrlOffset * sign, p1.dy,
               p2.dx - ctrlOffset * sign, p2.dy,
               p2.dx, p2.dy);
  }

  /// PCB 式正交布线：从 p1 到 p2 的曼哈顿折线（先水平后垂直，转角圆角）。
  /// 修正：仅当相邻段足够长时才加圆角，避免产生微小凸起。
  Path _orthogonalPath(Offset p1, Offset p2, {double radius = 6}) {
    const lead = 20.0;
    final dx = p2.dx - p1.dx;
    final midX = p2.dx - (dx >= 0 ? lead : -lead);
    final r = radius.clamp(1.0, lead);
    final path = Path()..moveTo(p1.dx, p1.dy);

    // 三段折线坐标：p1 → (midX, p1.y) → (midX, p2.y) → p2
    final hLen = (midX - p1.dx).abs(); // 水平段长度
    final vLen = (p2.dy - p1.dy).abs(); // 垂直段长度

    // 转角 1（p1 → h 转角 → v 转角）：p1 → (midX, p1.y) 的圆角处理
    if (hLen > r * 2) {
      // 有足够空间做圆角
      path.lineTo(midX - (dx >= 0 ? r : -r), p1.dy);
      if (vLen > r * 2) {
        // 两段都够长：完整圆角
        if (dx >= 0) {
          path.quadraticBezierTo(midX, p1.dy, midX, p1.dy + (p2.dy >= p1.dy ? r : -r));
        } else {
          path.quadraticBezierTo(midX, p1.dy, midX, p1.dy + (p2.dy >= p1.dy ? r : -r));
        }
      } else {
        // 垂直段太短：不做圆角（直接方角）
        path.lineTo(midX, p1.dy);
      }
    } else {
      // 水平段太短：不做圆角
      path.lineTo(midX, p1.dy);
    }

    // 垂直段
    if (vLen > r * 2) {
      // 垂直段够长：先画到离目标 r 处，再加圆角过渡到水平
      final vUp = p2.dy >= p1.dy;
      path.lineTo(midX, p2.dy - (vUp ? r : -r));
      // 转角 2：（v 转角 → h 转角 → p2）的圆角
      if (hLen > r * 2) {
        // 水平段也够长：完整圆角
        path.quadraticBezierTo(midX, p2.dy, midX + (dx >= 0 ? r : -r), p2.dy);
      } else {
        // 水平段太短：不做圆角
        path.lineTo(midX, p2.dy);
      }
    } else {
      // 垂直段太短：不做圆角，直接画到目标 y
      path.lineTo(midX, p2.dy);
    }

    // 最后水平到终点
    path.lineTo(p2.dx, p2.dy);
    return path;
  }

  /// 在给定路径上绘制虚线
  void _drawDashedPathOnPath(Canvas canvas, Path path, Paint paint) {
    const dashLen = 6.0;
    const gapLen = 3.0;
    for (final metric in path.computeMetrics()) {
      double drawn = 0;
      while (drawn < metric.length) {
        final end = (drawn + dashLen).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(drawn, end), paint);
        drawn += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_ConnectionPainter old) => true;
}

// ── 临时拖拽连线 ──

class _TempLinePainter extends CustomPainter {
  final Offset from, to;
  final Color color;
  final bool isControl;
  _TempLinePainter({required this.from, required this.to, required this.color, this.isControl = false});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    if (isControl) {
      // 控制连线：正交折线 + 虚线拖拽预览
      const lead = 20.0;
      final dx = to.dx - from.dx;
      final midX = to.dx - (dx >= 0 ? lead : -lead);
      final path = Path()..moveTo(from.dx, from.dy)
        ..lineTo(midX, from.dy)
        ..lineTo(midX, to.dy)
        ..lineTo(to.dx, to.dy);
      const dashLen = 6.0;
      const gapLen = 3.0;
      for (final metric in path.computeMetrics()) {
        double drawn = 0;
        while (drawn < metric.length) {
          final end = (drawn + dashLen).clamp(0.0, metric.length);
          canvas.drawPath(metric.extractPath(drawn, end), paint);
          drawn += dashLen + gapLen;
        }
      }
    } else {
      // 数据连线：贝塞尔曲线拖拽预览
      final dx = to.dx - from.dx;
      final ctrlOffset = dx.abs() * 0.4;
      final sign = dx >= 0 ? 1.0 : -1.0;
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..cubicTo(from.dx + ctrlOffset * sign, from.dy,
                 to.dx - ctrlOffset * sign, to.dy,
                 to.dx, to.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_TempLinePainter old) => old.from != from || old.to != to || old.isControl != isControl;
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
  final String Function(String type, double x, double y) onAddNode;
  final String Function(String gateName, double x, double y) onAddGate;
  final bool Function(String nodeId, Map<String, String> params) onSetGateParams;
  final void Function(String nodeId) onDeleteNode;
  final bool Function(String fromId, String toId) onConnectNodes;
  final bool Function(String connId) onDisconnectNodes;
  final VoidCallback onCancelTasks;
  final bool startExpanded;
  final VoidCallback? onCollapseRequested;
  final ValueChanged<String>? onTitleGenerated;
  const _AiPanel({super.key, required this.strings, required this.existingNodes, required this.existingConnections, required this.onApplyGraph, required this.onMergeGraph, required this.onModifyNodeParams, required this.onClearAll, required this.onUndo, required this.onRedo, required this.onSave, required this.onAddNode, required this.onAddGate, required this.onSetGateParams, required this.onDeleteNode, required this.onConnectNodes, required this.onDisconnectNodes, required this.onCancelTasks, this.startExpanded = false, this.onCollapseRequested, this.onTitleGenerated});  @override
  State<_AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<_AiPanel> {
  @override
  void initState() {
    super.initState();
    _expanded = widget.startExpanded;
  }

  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<({String role, String content, int? inputTokens, int? outputTokens, List<Map<String, dynamic>>? blocks})> _messages = [];
  bool _loading = false;
  bool _expanded = false;
  // 工具侧边栏：true=展开显示工具列表，false=折叠成窄条
  bool _toolsOpen = false;
  // 被禁用的工具（右键工具项 → 禁用）。禁用 = 从系统提示词移除 + 调用被拦截。
  final Set<String> _disabledTools = {};
  List<PipelineNode>? _pendingNodes;
  List<PipelineConnection>? _pendingConnections;
  bool _pendingIsModify = false;

  // ── 会话级供应商/模型覆盖（默认跟随全局配置，可在面板内切换，仅影响本会话） ──
  String? _sessionProvider;
  String? _sessionModel;
  // 会话级模式：'auto' 自动批准图应用；'ask' 每次询问（可豁免白名单操作）。
  // null = 跟随全局 aiApproveMode。
  String? _sessionApproveMode;
  // 会话级配置项 id（null = 跟随全局 activeAiProfileId / 默认字段）
  String? _sessionProfileId;
  // 是否已生成过会话标题（避免每轮都生成）
  bool _titleGenerated = false;

  // ── token / 速度统计 ──
  int _totalInputTokens = 0;
  int _totalOutputTokens = 0;
  double? _lastGenSpeed; // 字符/秒
  final _genStart = Stopwatch();

  // ── Markdown 样式缓存 ──
  // 关键：流式回复每收到一个 token 都会 setState 重建整棵消息列表。若每次
  // 都新建一份 MarkdownStyleSheet，flutter_markdown 会判为样式变化而对
  // *所有*消息重解析，造成滚动/输入期间卡顿与闪烁。这里按主题关键色做缓存，
  // 主题不变时复用同一实例。
  MarkdownStyleSheet? _mdStyle;
  ({
    Brightness brightness,
    Color primary,
    Color onSurface,
    Color onSurfaceVariant,
    Color primaryContainer,
    Color surfaceContainerHighest,
    Color outline,
    Color outlineVariant,
  })? _mdStyleKey;


  static const _uuid = Uuid();

  String get _effectiveProvider => _sessionProvider ?? context.read<AppState>().config.aiProvider;
  String get _effectiveModel => _sessionModel ?? context.read<AppState>().config.aiModel;
  String get _effectiveApproveMode => _sessionApproveMode ?? context.read<AppState>().config.aiApproveMode;

  /// 当前生效的配置项（会话级 > 全局 active > 默认字段）。
  AiProfile? get _effectiveProfile {
    final cfg = context.read<AppState>().config;
    final id = _sessionProfileId ?? cfg.activeAiProfileId;
    if (id.isEmpty) return null;
    for (final p in cfg.aiProfiles) {
      if (p.id == id && p.enabled) return p;
    }
    return null;
  }

  /// 询问模式下，某操作是否在"无需确认"白名单里。
  bool _shouldSkipAsk(String key) => context.read<AppState>().config.aiAskSkipTools.contains(key);

  /// 可插入的工具模板（供工具侧边栏展示/一键插入）
  static const List<({String name, String desc, String template, bool needsPath})> _toolTemplates = [
    (name: 'clear_all', desc: '清空画布', template: '[TOOL_CALL:clear_all]', needsPath: false),
    (name: 'undo', desc: '撤销', template: '[TOOL_CALL:undo]', needsPath: false),
    (name: 'redo', desc: '重做', template: '[TOOL_CALL:redo]', needsPath: false),
    (name: 'save', desc: '保存', template: '[TOOL_CALL:save]', needsPath: false),
    (name: 'error_check', desc: '画布错误检查', template: '[TOOL_CALL:error_check]', needsPath: false),
    (name: 'ask_user', desc: '向用户提问', template: '[TOOL_CALL:ask_user|问题|选项1,选项2]', needsPath: false),
    (name: 'list_directory', desc: '列出目录文件（只读）', template: '[TOOL_CALL:list_directory|路径]', needsPath: true),
    (name: 'read_file_info', desc: '读取文件信息（只读）', template: '[TOOL_CALL:read_file_info|路径]', needsPath: true),
    (name: 'probe_video', desc: '探测媒体文件', template: '[TOOL_CALL:probe_video|路径]', needsPath: true),
    (name: 'pick_file', desc: '让用户选择文件（如字幕、封面）', template: '[TOOL_CALL:pick_file|用途|扩展名1,扩展名2]', needsPath: true),
    (name: 'modify_node', desc: '修改节点参数', template: '[TOOL_CALL:modify_node|节点ID|key=val]', needsPath: false),
    (name: 'add_node', desc: '添加节点', template: '[TOOL_CALL:add_node|类型|x|y]', needsPath: false),
    (name: 'add_gate', desc: '添加逻辑门(and/or/not/nand/nor/const1/const0/time_trigger)', template: '[TOOL_CALL:add_gate|门类型|x|y]', needsPath: false),
    (name: 'set_gate_params', desc: '修改逻辑门参数(如时间触发器 tt_date/tt_start/tt_end)', template: '[TOOL_CALL:set_gate_params|节点ID|key=val]', needsPath: false),
    (name: 'get_gate_types', desc: '列出逻辑门类型', template: '[TOOL_CALL:get_gate_types]', needsPath: false),
    (name: 'delete_node', desc: '删除节点', template: '[TOOL_CALL:delete_node|节点ID]', needsPath: false),
    (name: 'connect_nodes', desc: '连接节点', template: '[TOOL_CALL:connect_nodes|from|to]', needsPath: false),
    (name: 'disconnect_nodes', desc: '断开连线', template: '[TOOL_CALL:disconnect_nodes|连线ID]', needsPath: false),
    (name: 'list_nodes', desc: '列出画布节点', template: '[TOOL_CALL:list_nodes]', needsPath: false),
    (name: 'list_connections', desc: '列出画布连线', template: '[TOOL_CALL:list_connections]', needsPath: false),
    (name: 'get_node_types', desc: '列出节点类型', template: '[TOOL_CALL:get_node_types]', needsPath: false),
    (name: 'list_tasks', desc: '查看任务队列', template: '[TOOL_CALL:list_tasks]', needsPath: false),
    (name: 'cancel_tasks', desc: '取消所有任务', template: '[TOOL_CALL:cancel_tasks]', needsPath: false),
    (name: 'get_graph_stats', desc: '画布统计信息', template: '[TOOL_CALL:get_graph_stats]', needsPath: false),
    (name: 'list_containers', desc: '列出所有容器', template: '[TOOL_CALL:list_containers]', needsPath: false),
    (name: 'list_videos', desc: '列出已加载的视频文件', template: '[TOOL_CALL:list_videos]', needsPath: false),
    (name: 'read_logs', desc: '读取最近日志', template: '[TOOL_CALL:read_logs]', needsPath: false),
    (name: 'get_task_info', desc: '查看任务详情', template: '[TOOL_CALL:get_task_info|任务ID]', needsPath: false),
    (name: 'rename_node', desc: '重命名节点', template: '[TOOL_CALL:rename_node|节点ID|新名称]', needsPath: false),
  ];
  /// 系统提示词固定头部。
  static const _promptHead = '''You are FFmpeg++ Graph Assistant, an expert FFmpeg pipeline designer for a node-based video/audio/image editor. The user describes media-processing goals in their own language; ALWAYS reply in the SAME language the user used.

## Output protocol (strict)
1. First write 1-3 short sentences explaining your plan (plain text, in the user's language).
2. Then output EXACTLY ONE JSON pipeline graph inside a single ```json fenced block. Never emit the JSON outside the fence, never emit a second graph.
3. You may also emit tool calls (see Tools) before/after the graph. Each tool call is a single line marker.
4. Keep the graph minimal: only include nodes the user asked for; omit params that equal defaults.

## Media flow compatibility
Nodes carry media types; a connection is only valid when output type matches input type:
- start → (video|audio|image) → ... → output
- Video producers/processors: avProcess, subtitle, clip, speed, videoCrop, frame (frame outputs image)
- Audio: audioConvert, audioQuality, audioSpeed, audioVolume, audioCompressor, audioMetadata, extractAudio
- Image: imageConvert, imageCrop, imageRotate, imageScale, imageBrightness, imageNoise, imageSharpen, imageDenoise, imageChannelExtract
- Composite: concatMedia (same-type inputs), imageToVideo (images → video)
Never connect a video node to an audio node or vice versa.

## Node types & key params
Control:
- start (no params; always first, exactly one)
- output (always last, exactly one): format, naming_mode (auto|manual), naming_value, output_dir

Video:
- avProcess: video_codec (libx264|libx265|libvpx-vp9|libaom-av1|h264_nvenc|hevc_nvenc|mpeg4), gpu (CPU or GPU name), preset (ultrafast..veryslow), rate_mode (crf|cbr|vbr), crf (0-51, lower=better quality; default 23), video_bitrate, resolution (e.g. "1920x1080"), fps, audio_codec, audio_bitrate, audio_channels, pix_fmt
- subtitle: source (external|embedded), subtitle_file, subtitle_index, font_name, font_size, font_color, outline_width, outline_color
- clip: start_time, end_time (seconds; include start_time when clipping a range)
- speed: speed (0.25-4.0)
- videoCrop: crop_mode (keep|remove), crop_x, crop_y, crop_w, crop_h

Audio:
- audioConvert: audio_codec (aac|libmp3lame|libopus|libvorbis|flac|pcm_s16le), output_format (m4a|mp3|ogg|flac|wav)
- audioQuality: bitrate_mode, audio_bitrate, sample_rate
- audioSpeed: atempo (0.5-2.0)
- audioVolume: volume_db (-30 to +30)
- audioCompressor: threshold, ratio, attack, release, makeup, knee
- audioMetadata: title, artist, album, cover_path, lyrics_path
- extractAudio: extract_mode (full|clip), start_time, end_time, audio_codec, output_format

Image:
- imageConvert: output_format (png|jpg|webp|bmp|ico), quality (1-100)
- imageCrop: crop_x, crop_y, crop_w, crop_h
- imageRotate: angle (90|180|270)
- imageScale: scale_mode (percent|fixed|fit), scale_factor
- imageBrightness: brightness (-1 to 1)
- imageNoise: noise_strength, noise_type
- imageSharpen: sharpen_strength (0-5)
- imageDenoise: denoise_method, denoise_strength
- imageChannelExtract: channel (r|g|b), extract_method

Composite:
- concatMedia: mode (copy|reencode), order_mode
- imageToVideo: framerate, output_format, video_codec
- frame: extract_mode (single|range|all), time, range_start, range_end, fps_rate, output_format

## JSON schema
{"nodes":[{"id":"n1","type":"start","x":2900,"y":3000,"params":{}},{"id":"n2","type":"avProcess","x":3150,"y":3000,"params":{"video_codec":"libx264","rate_mode":"crf","crf":23}},{"id":"n3","type":"output","x":3400,"y":3000,"params":{}}],"connections":[{"from":"n1","to":"n2"},{"from":"n2","to":"n3"}]}
Node layout: first node at x=2900,y=3000; each following node +250px on x; parallel branches offset y by ~120px. ids must be unique ("n1","n2",...). Exactly one start and one output; every other node must have at least one incoming and one outgoing connection.

## Examples
- "把这视频转成 h265 减小体积" → start → avProcess{video_codec:libx265, rate_mode:crf, crf:28} → output{format:mp4}
- "提取视频里的音频为 mp3" → start → extractAudio{extract_mode:full, audio_codec:libmp3lame, output_format:mp3} → output{format:mp3}
- "每2秒截一帧图" → start → frame{extract_mode:all, fps_rate:0.5, output_format:jpg} → output{format:jpg}

## Tools (emit exact markers inline; the system executes them and feeds results back)
__TOOLS__

Permissions: read-only tools (list_directory, read_file_info, probe_video) require "Read Access"; editing tools (modify_node, add_node, delete_node, connect_nodes, disconnect_nodes) require "Write Access"; action tools (clear_all, undo, redo, save, error_check, ask_user, cancel_tasks) require "Auto-execute Tools" — all toggles are in Settings → AI. list_nodes / list_connections / get_node_types / list_tasks always work. If a tool is blocked by permissions, the system silently skips it — mention that to the user instead of relying on it.

## Modes & confirmation
Default: the JSON graph REPLACES the entire canvas. To MERGE with the existing canvas instead, put the marker [MODE:modify] on its own line before the JSON. The current canvas state is appended below the conversation automatically — read it before editing so you don't destroy existing work.

Session modes:
- Auto mode: your JSON graph is applied immediately, and action tools run right away.
- Ask mode: applying a graph and running destructive tools asks the user for confirmation. If the user denies, adapt your next answer (the denial is fed back as a tool result).
Use [TOOL_CALL:list_nodes] / [TOOL_CALL:list_connections] to inspect the canvas before proposing edits, and [TOOL_CALL:clear_all] to start fresh (it also asks in Ask mode).''';

  /// 工具段每一行（按行过滤禁用工具）。
  static const List<String> _toolPromptLines = [
    '[TOOL_CALL:clear_all] [TOOL_CALL:undo] [TOOL_CALL:redo] [TOOL_CALL:save]',
    '[TOOL_CALL:error_check] — validate current canvas',
    '[TOOL_CALL:ask_user|question|opt1,opt2,opt3] — ask the user (needs Allow-AI-to-ask enabled in Settings)',
    '[TOOL_CALL:list_directory|path] — list files (read-only)',
    '[TOOL_CALL:read_file_info|path] — file metadata (read-only)',
    '[TOOL_CALL:probe_video|path] — probe media metadata (read-only)',
    '[TOOL_CALL:pick_file|purpose|ext1,ext2] — ask the user to pick a file (e.g. subtitle, cover); user must approve',
    '[TOOL_CALL:modify_node|nodeId|key=val,key2=val2] — edit node params',
    '[TOOL_CALL:add_node|type|x|y] — add a node, returns its ID',
    '[TOOL_CALL:delete_node|nodeId] — delete a node + its connections',
    '[TOOL_CALL:connect_nodes|fromId|toId] — connect two nodes',
    '[TOOL_CALL:disconnect_nodes|connId] — remove a connection',
    '[TOOL_CALL:list_nodes] [TOOL_CALL:list_connections] [TOOL_CALL:get_node_types]',
    '[TOOL_CALL:add_gate|type|x|y] — add logic gate (and/or/not/nand/nor/const1/const0/time_trigger)',
    '[TOOL_CALL:set_gate_params|nodeId|key=val,key2=val2] — modify gate params (e.g. tt_date/tt_start/tt_end)',
    '[TOOL_CALL:get_gate_types] — list logic gate types',
    '[TOOL_CALL:list_tasks] — task queue status',
    '[TOOL_CALL:cancel_tasks] — cancel running tasks',
    '[TOOL_CALL:get_task_info|taskId] — task detail',
    '[TOOL_CALL:get_graph_stats] — canvas statistics',
    '[TOOL_CALL:list_videos] [TOOL_CALL:list_containers] — loaded media/containers (read-only)',
    '[TOOL_CALL:read_logs] — recent app logs',
    '[TOOL_CALL:rename_node|nodeId|name] — rename a node (write)',
  ];

  /// 每行对应的工具名。
  static const Map<String, List<String>> _toolLineTools = {
    '[TOOL_CALL:clear_all] [TOOL_CALL:undo] [TOOL_CALL:redo] [TOOL_CALL:save]': ['clear_all', 'undo', 'redo', 'save'],
    '[TOOL_CALL:error_check] — validate current canvas': ['error_check'],
    '[TOOL_CALL:ask_user|question|opt1,opt2,opt3] — ask the user (needs Allow-AI-to-ask enabled in Settings)': ['ask_user'],
    '[TOOL_CALL:list_directory|path] — list files (read-only)': ['list_directory'],
    '[TOOL_CALL:read_file_info|path] — file metadata (read-only)': ['read_file_info'],
    '[TOOL_CALL:probe_video|path] — probe media metadata (read-only)': ['probe_video'],
    '[TOOL_CALL:pick_file|purpose|ext1,ext2] — ask the user to pick a file (e.g. subtitle, cover); user must approve': ['pick_file'],
    '[TOOL_CALL:modify_node|nodeId|key=val,key2=val2] — edit node params': ['modify_node'],
    '[TOOL_CALL:add_node|type|x|y] — add a node, returns its ID': ['add_node'],
    '[TOOL_CALL:delete_node|nodeId] — delete a node + its connections': ['delete_node'],
    '[TOOL_CALL:connect_nodes|fromId|toId] — connect two nodes': ['connect_nodes'],
    '[TOOL_CALL:disconnect_nodes|connId] — remove a connection': ['disconnect_nodes'],
    '[TOOL_CALL:list_nodes] [TOOL_CALL:list_connections] [TOOL_CALL:get_node_types]': ['list_nodes', 'list_connections', 'get_node_types'],
    '[TOOL_CALL:add_gate|type|x|y] — add logic gate (and/or/not/nand/nor/const1/const0/time_trigger)': ['add_gate'],
    '[TOOL_CALL:set_gate_params|nodeId|key=val,key2=val2] — modify gate params (e.g. tt_date/tt_start/tt_end)': ['set_gate_params'],
    '[TOOL_CALL:get_gate_types] — list logic gate types': ['get_gate_types'],
    '[TOOL_CALL:list_tasks] — task queue status': ['list_tasks'],
    '[TOOL_CALL:cancel_tasks] — cancel running tasks': ['cancel_tasks'],
    '[TOOL_CALL:get_task_info|taskId] — task detail': ['get_task_info'],
    '[TOOL_CALL:get_graph_stats] — canvas statistics': ['get_graph_stats'],
    '[TOOL_CALL:list_videos] [TOOL_CALL:list_containers] — loaded media/containers (read-only)': ['list_videos', 'list_containers'],
    '[TOOL_CALL:read_logs] — recent app logs': ['read_logs'],
    '[TOOL_CALL:rename_node|nodeId|name] — rename a node (write)': ['rename_node'],
  };

  /// 动态系统提示词：过滤掉被禁用的工具行。
  String get _systemPrompt {
    final lines = <String>[];
    for (final line in _toolPromptLines) {
      final tools = _toolLineTools[line] ?? const <String>[];
      final disabled = tools.any((t) => _disabledTools.contains(t));
      if (!disabled) lines.add(line);
    }
    return _promptHead.replaceAll('__TOOLS__', lines.join('\n'));
  }


  /// 右键工具项：禁用 / 启用。禁用后该工具从系统提示词移除，且调用被拦截。
  void _toggleToolEnabled(String tool, AppStrings s) {
    setState(() {
      if (_disabledTools.contains(tool)) {
        _disabledTools.remove(tool);
      } else {
        _disabledTools.add(tool);
      }
    });
    showToast(context, _disabledTools.contains(tool)
        ? s.isZh ? '已禁用工具: $tool' : 'Tool disabled: $tool'
        : s.isZh ? '已启用工具: $tool' : 'Tool enabled: $tool',
        type: ToastType.info);
  }

  /// 询问模式下是否需要确认该工具。auto 模式或命中白名单则直接执行。
  bool _shouldConfirmTool(String tool) {
    if (_effectiveApproveMode == 'auto') return false;
    // 只读工具从不询问
    const readOnly = {'list_directory', 'read_file_info', 'probe_video', 'list_nodes', 'list_connections', 'get_node_types', 'list_tasks', 'get_gate_types', 'get_graph_stats', 'list_videos', 'list_containers', 'read_logs', 'get_task_info'};
    if (readOnly.contains(tool)) return false;
    // 白名单 key 映射
    final key = switch (tool) {
      'save' => 'save',
      'undo' || 'redo' => 'undo_redo',
      'error_check' => 'error_check',
      'clear_all' => 'clear_all',
      _ => 'tools',
    };
    return !_shouldSkipAsk(key);
  }

  /// 弹确认框；用户同意后执行 [action]，拒绝则记录结果。
  Future<void> _confirmThen(String tool, String desc, VoidCallback action) async {
    final s = widget.strings;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(s.isZh ? 'AI 请求执行操作' : 'AI requests to run an action',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        content: Text(
          s.isZh ? 'AI 想执行: $desc\n\n确定允许吗？' : 'AI wants to: $desc\n\nAllow it?',
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(s.isZh ? '拒绝' : 'Deny')),
          FilledButton(onPressed: () => Navigator.pop(dCtx, true), child: Text(s.isZh ? '允许' : 'Allow')),
        ],
      ),
    );
    if (ok == true) {
      action();
    } else {
      _addToolResult('confirm', s.isZh ? '用户拒绝执行 $desc' : 'User denied: $desc');
    }
  }

  void _handleToolCalls(String content) {
    final cfg = context.read<AppState>().config;
    final calls = RegExp(r'\[TOOL_CALL:([^\]]+)\]').allMatches(content);
    for (final m in calls) {
      final parts = m.group(1)!.split('|');
      final tool = parts[0];
      // 调试模式：记录 AI 工具调用
      if (cfg.debugMode) {
        final argPreview = parts.length > 1 ? parts.sublist(1).join('|').replaceAll(RegExp(r'\s+'), ' ') : '';
        context.read<AppState>().addLog('[AI工具] $tool${argPreview.isNotEmpty ? ' args: $argPreview' : ''}', category: 'info');
      }
      // 被禁用的工具：即使 AI 调用了也不执行（也不告诉 AI 结果）
      if (_disabledTools.contains(tool)) {
        _addToolResult('blocked', 'Tool $tool is disabled by user');
        continue;
      }
      // 询问确认：破坏性工具在 ask 模式且不在白名单时需用户确认
      final confirm = _shouldConfirmTool(tool);
      void run(VoidCallback action) {
        // action 工具（clear_all/undo/redo/save/error_check/ask_user/cancel_tasks）在
        // auto 模式下需开启 "Auto-execute Tools" 权限（与系统提示词声明一致）；
        // ask 模式仍走确认框。权限不足时跳过并回填结果，避免 AI 误以为已执行。
        const actionTools = {'clear_all', 'undo', 'redo', 'save', 'error_check', 'ask_user', 'cancel_tasks'};
        if (actionTools.contains(tool) && _effectiveApproveMode == 'auto' && !cfg.aiAutoExecute) {
          _addToolResult(tool, 'Blocked: action tools require "Auto-execute Tools" permission');
          return;
        }
        if (confirm) {
          _confirmThen(tool, tool, action);
        } else {
          action();
        }
      }
      switch (tool) {
        case 'clear_all':
          run(() => widget.onClearAll());
        case 'undo':
          run(() => widget.onUndo());
        case 'redo':
          run(() => widget.onRedo());
        case 'save':
          run(() => widget.onSave());
        case 'error_check':
          run(() => _executeErrorCheck());
        case 'ask_user':
          // 需在设置→AI→权限 开启"允许 AI 询问用户"才执行
          if (cfg.aiAllowAsk && parts.length >= 3) run(() => _showAskUser(parts[1], parts[2].split(',')));
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
            run(() => widget.onModifyNodeParams(parts[1], params));
          }
        case 'add_node':
          if (cfg.aiWriteAccess && parts.length >= 2) {
            run(() {
              try {
                final x = parts.length >= 3 ? double.tryParse(parts[2]) ?? 200 : 200.0;
                final y = parts.length >= 4 ? double.tryParse(parts[3]) ?? 200 : 200.0;
                final nodeId = widget.onAddNode(parts[1], x, y);
                _addToolResult('add_node', 'Created node $nodeId (type: ${parts[1]})');
              } catch (e) { _addToolResult('add_node', 'Error: $e'); }
            });
          }
        case 'delete_node':
          if (cfg.aiWriteAccess && parts.length >= 2) {
            run(() {
              try { widget.onDeleteNode(parts[1]); _addToolResult('delete_node', 'Deleted node ${parts[1]}'); }
              catch (e) { _addToolResult('delete_node', 'Error: $e'); }
            });
          }
        case 'connect_nodes':
          if (cfg.aiWriteAccess && parts.length >= 3) {
            run(() {
              final ok = widget.onConnectNodes(parts[1], parts[2]);
              _addToolResult('connect_nodes', ok ? 'Connected ${parts[1]} → ${parts[2]}' : 'Failed to connect');
            });
          }
        case 'disconnect_nodes':
          if (cfg.aiWriteAccess && parts.length >= 2) {
            run(() {
              final ok = widget.onDisconnectNodes(parts[1]);
              _addToolResult('disconnect_nodes', ok ? 'Disconnected ${parts[1]}' : 'Connection not found');
            });
          }
        case 'list_nodes':
          final nodesJson = widget.existingNodes.map((n) => n.toJson()).toList();
          _addToolResult('list_nodes', jsonEncode(nodesJson));
        case 'list_connections':
          final connsJson = widget.existingConnections.map((c) => c.toJson()).toList();
          _addToolResult('list_connections', jsonEncode(connsJson));
        case 'get_node_types':
          final types = PipelineStepType.values.map((t) => t.name).toList();
          _addToolResult('get_node_types', types.join(', '));
        case 'list_tasks':
          final tasks = context.read<AppState>().tasks;
          final taskList = tasks.map((t) => {'id': t.id, 'filename': t.filename, 'status': t.status.name, 'progress': '${t.progress.toStringAsFixed(1)}%'}).toList();
          _addToolResult('list_tasks', jsonEncode(taskList));
        case 'cancel_tasks':
          run(() { widget.onCancelTasks(); _addToolResult('cancel_tasks', 'All tasks cancelled'); });
        case 'probe_video':
          if (cfg.aiReadAccess && parts.length >= 2) _executeProbeVideo(parts[1]);
        case 'pick_file':
          // 让用户选择文件（如字幕/封面），需用户同意；弹文件选择框并返回路径
          run(() async {
            final purpose = parts.length >= 2 ? parts[1] : '';
            final exts = parts.length >= 3 ? parts[2].split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList() : null;
            final r = await FilePicker.platform.pickFiles(
              type: exts == null || exts.isEmpty ? FileType.any : FileType.custom,
              allowedExtensions: exts,
              dialogTitle: purpose.isEmpty ? (widget.strings.isZh ? '请选择一个文件' : 'Pick a file') : purpose,
            );
            if (r != null && r.files.isNotEmpty && r.files.first.path != null) {
              _addToolResult('pick_file', 'User picked: ${r.files.first.path}');
            } else {
              _addToolResult('pick_file', 'User cancelled file selection');
            }
          });
        case 'add_gate':
          if (cfg.aiWriteAccess && parts.length >= 2) {
            run(() {
              try {
                final gateType = _parseGateType(parts[1]);
                if (gateType == null) {
                  _addToolResult('add_gate', 'Error: unknown gate type "${parts[1]}". Valid: and, or, not, nand, nor, const1, const0, time_trigger');
                  return;
                }
                final x = parts.length >= 3 ? double.tryParse(parts[2]) ?? 200 : 200.0;
                final y = parts.length >= 4 ? double.tryParse(parts[3]) ?? 200 : 200.0;
                final nodeId = widget.onAddGate(gateType.name, x, y);
                _addToolResult('add_gate', 'Created gate $nodeId (type: ${parts[1]})');
              } catch (e) { _addToolResult('add_gate', 'Error: $e'); }
            });
          }
        case 'set_gate_params':
          if (cfg.aiWriteAccess && parts.length >= 3) {
            final params = <String, String>{};
            for (final p in parts[2].split(',')) {
              final kv = p.split('=');
              if (kv.length == 2) params[kv[0].trim()] = kv[1].trim();
            }
            run(() {
              widget.onModifyNodeParams(parts[1], params);
              _addToolResult('set_gate_params', 'Gate ${parts[1]} params updated');
            });
          }
        case 'get_gate_types':
          final gateTypes = LogicGateType.values.map((t) => t.name).toList();
          _addToolResult('get_gate_types', gateTypes.join(', '));
        case 'get_graph_stats':
          final nodes = widget.existingNodes;
          final conns = widget.existingConnections;
          final srcCount = nodes.where((n) => n.type == PipelineStepType.start && !n.isGate).length;
          final outCount = nodes.where((n) => n.type == PipelineStepType.output).length;
          final gateCount = nodes.where((n) => n.isGate).length;
          _addToolResult('get_graph_stats', 'nodes: ${nodes.length}, gates: $gateCount, connections: ${conns.length}, start: $srcCount, output: $outCount');
        case 'list_containers':
          final containers = context.read<AppState>().containers;
          final containerList = containers.map((c) => {'id': c.id, 'name': c.name, 'fileCount': c.fileCount}).toList();
          _addToolResult('list_containers', jsonEncode(containerList));
        case 'list_videos':
          final videos = context.read<AppState>().videos;
          final videoList = videos.map((v) => {'id': v.id, 'filename': v.filename, 'sizeMb': v.sizeMb, 'parsed': v.parsed}).toList();
          _addToolResult('list_videos', jsonEncode(videoList));
        case 'read_logs':
          final logs = context.read<AppState>().logEntries;
          final recent = logs.length > 30 ? logs.sublist(logs.length - 30) : logs;
          final logText = recent.map((l) => '[${l.timestamp.hour.toString().padLeft(2, '0')}:${l.timestamp.minute.toString().padLeft(2, '0')}] ${l.message}').join('\n');
          _addToolResult('read_logs', logText.isEmpty ? '(no logs)' : logText);
        case 'get_task_info':
          if (parts.length >= 2) {
            final taskId = parts[1];
            final tasks = context.read<AppState>().tasks;
            final task = tasks.where((t) => t.id == taskId).firstOrNull;
            if (task != null) {
              _addToolResult('get_task_info', jsonEncode({
                'id': task.id, 'filename': task.filename, 'status': task.status.name,
                'progress': '${task.progress.toStringAsFixed(1)}%',
                'inputPath': task.inputPath, 'outputPath': task.outputPath,
              }));
            } else {
              _addToolResult('get_task_info', 'Task not found: $taskId');
            }
          }
        case 'rename_node':
          if (cfg.aiWriteAccess && parts.length >= 3) {
            final nodeId = parts[1];
            final name = parts[2];
            run(() {
              widget.onModifyNodeParams(nodeId, {'node_name': name});
              _addToolResult('rename_node', 'Node $nodeId renamed to "$name"');
            });
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
    if (!nodes.any((n) => n.type == PipelineStepType.start && !n.isGate)) errors.add('Missing start node');
    if (!nodes.any((n) => n.type == PipelineStepType.output)) errors.add('Missing output node');
    final connectedIds = <String>{};
    for (final c in conns) { connectedIds.add(c.fromNodeId); connectedIds.add(c.toNodeId); }
    for (final n in nodes) {
      if (!connectedIds.contains(n.id) && nodes.length > 1) {
        errors.add('Disconnected: ${n.type.name} (${n.id.length > 8 ? n.id.substring(0, 8) : n.id})');
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

  Future<void> _executeProbeVideo(String path) async {
    try {
      final resp = await context.read<AppState>().backend.probe(path);
      if (resp['success'] == true) {
        _addToolResult('probe_video', jsonEncode(resp['data'] ?? resp));
      } else {
        _addToolResult('probe_video', 'Error: ${resp['error'] ?? 'probe failed'}');
      }
    } catch (e) { _addToolResult('probe_video', 'Error: $e'); }
  }

  void _showAskUser(String question, List<String> options) {
    setState(() {
      _messages.add((role: 'assistant', content: '[ASK_USER]$question|${options.join(",")}',
        inputTokens: null, outputTokens: null, blocks: null));
    });
    _scrollToBottom();
  }

  /// 解析字符串为 LogicGateType（兼容 name 和别名）。
  LogicGateType? _parseGateType(String s) {
    // 直接匹配 name
    for (final t in LogicGateType.values) {
      if (t.name == s) return t;
    }
    // 别名
    switch (s) {
      case 'and': return LogicGateType.and;
      case 'or': return LogicGateType.or;
      case 'not': return LogicGateType.not;
      case 'nand': return LogicGateType.nand;
      case 'nor': return LogicGateType.nor;
      case 'xor': case 'exclusive_or': return LogicGateType.xor;
      case 'xnor': case 'exclusive_nor': return LogicGateType.xnor;
      case 'const1': case 'const_1': case 'constant_1': case 'high': return LogicGateType.const1;
      case 'const0': case 'const_0': case 'constant_0': case 'low': return LogicGateType.const0;
      case 'time_trigger': case 'timer': return LogicGateType.timeTrigger;
    }
    return null;
  }

  @override
  void dispose() {
    // 面板关闭时自动把当前会话存入历史，方便下次继续
    final userMsgs = _messages.where((m) => m.role == 'user').toList();
    if (userMsgs.isNotEmpty) {
      final title = userMsgs.first.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      final t = title.length > 24 ? '${title.substring(0, 24)}…' : title;
      AiChatHistory.saveSession(
        title: t,
        provider: _effectiveProvider,
        model: _effectiveModel,
        messages: _messages.map((m) => {
          'role': m.role,
          'content': m.content,
          'inputTokens': m.inputTokens,
          'outputTokens': m.outputTokens,
        }).toList(),
      );
    }
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    // 面板可能在流式响应中途被关闭（_scrollCtrl 已 dispose），避免触碰已销毁的控制器
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
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
    // 优先使用当前选中的配置项（会话级 > 全局 active > 默认字段）
    final profile = _effectiveProfile;
    final effKey = profile?.apiKey.isNotEmpty == true ? profile!.apiKey : cfg.aiApiKey;
    final effProvider = profile?.provider ?? _effectiveProvider;
    final effModel = profile?.model ?? _effectiveModel;
    final effUrl = profile?.apiUrl.isNotEmpty == true ? profile!.apiUrl : cfg.aiApiUrl;
    final effMaxTokens = profile?.maxTokens ?? cfg.aiMaxTokens;
    final effTemp = profile?.temperature ?? cfg.aiTemperature;
    if (effKey.isEmpty) {
      showToast(context, widget.strings.aiNotConfigured, type: ToastType.warning);
      return;
    }
    // 历史上限：长会话（尤其工具调用密集）裁剪最旧消息，避免请求体积与内存无限增长
    const maxHistory = 100;
    if (_messages.length > maxHistory) {
      _messages.removeRange(0, _messages.length - maxHistory);
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
    _genStart..reset()..start();
    // 在 async 前读取配置，避免 async gap 后使用 context
    final showThinking = context.read<AppState>().config.aiShowThinking;

    http.Client? sendClient;
    try {
      final isAnthropic = effProvider == 'anthropic';
      final uri = Uri.parse(_resolveEndpoint(effUrl, isAnthropic));
      final canvasJson = jsonEncode({
        'nodes': widget.existingNodes.map((n) => n.toJson()).toList(),
        'connections': widget.existingConnections.map((c) => c.toJson()).toList(),
      });
      final customPrompt = cfg.aiSystemPrompt;
      final basePrompt = customPrompt.isNotEmpty ? '$customPrompt\n\n$_systemPrompt' : _systemPrompt;
      final fullPrompt = '$basePrompt\n\nCurrent canvas state:\n$canvasJson';

      final headers = <String, String>{'Content-Type': 'application/json'};
      Map<String, dynamic> reqBody;

      if (isAnthropic) {
        headers['x-api-key'] = effKey;
        headers['anthropic-version'] = '2023-06-01';
        final userMessages = _messages
            .where((m) => m.role == 'user' || m.role == 'assistant')
            .map((m) => {'role': m.role, 'content': m.content})
            .toList();
        // Ensure alternating user/assistant for Anthropic API
        final mergedMessages = <Map<String, dynamic>>[];
        for (final msg in userMessages) {
          if (mergedMessages.isNotEmpty && mergedMessages.last['role'] == msg['role']) {
            mergedMessages.last['content'] = '${mergedMessages.last['content']}\n${msg['content']}';
          } else {
            mergedMessages.add(Map.of(msg));
          }
        }
        reqBody = {
          'model': effModel,
          'system': fullPrompt,
          'messages': mergedMessages,
          'temperature': effTemp,
          'max_tokens': effMaxTokens,
          'stream': true,
        };
      } else {
        headers['Authorization'] = 'Bearer $effKey';
        final apiMessages = [
          {'role': 'system', 'content': fullPrompt},
          ..._messages.map((m) => {'role': m.role, 'content': m.content}),
        ];
        reqBody = {'model': effModel, 'messages': apiMessages, 'temperature': effTemp, 'max_tokens': effMaxTokens, 'stream': true, 'stream_options': {'include_usage': true}};
      }

      final request = http.Request('POST', uri);
      request.headers.addAll(headers);
      request.body = jsonEncode(reqBody);
      final client = http.Client();
      sendClient = client;
      final streamed = await client.send(request);

      if (streamed.statusCode != 200) {
        final respBody = await streamed.stream.bytesToString();
        final errMsg = 'Error: ${streamed.statusCode} ${respBody.length > 200 ? respBody.substring(0, 200) : respBody}';
        appState.logAiResponse(errMsg, error: true);
        if (mounted) {
          setState(() {
            _messages.add((role: 'assistant', content: errMsg, inputTokens: null, outputTokens: null, blocks: null));
            _loading = false;
          });
        }
        _scrollToBottom();
        return;  // sendClient 由外层 finally 统一关闭
      }

      // Add placeholder assistant message for streaming
      if (!mounted) return;  // sendClient 由外层 finally 统一关闭
      setState(() {
        _messages.add((role: 'assistant', content: '', inputTokens: null, outputTokens: null, blocks: null));
      });
      final msgIdx = _messages.length - 1;
      final buf = StringBuffer();
      // 思考过程缓冲（DeepSeek-R1 / o1 的 reasoning_content，或 Claude 的 thinking）
      final thinkBuf = StringBuffer();
      final thinkWatch = Stopwatch();
      int? inTok, outTok;
      String lineBuf = '';

      await for (final chunk in streamed.stream.transform(utf8.decoder)) {
        if (!mounted) break;  // 面板已关闭则停止消费，连接交由外层 finally 关闭
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
              if (type == 'content_block_start') {
                final cb = json['content_block'] as Map<String, dynamic>? ?? {};
                if (showThinking && cb['type'] == 'thinking') {
                  if (thinkBuf.isEmpty) thinkWatch.start();
                  thinkBuf.write(cb['thinking'] ?? '');
                }
              } else if (type == 'content_block_delta') {
                final delta = json['delta'] as Map<String, dynamic>? ?? {};
                if (delta['type'] == 'text_delta') {
                  buf.write(delta['text'] ?? '');
                } else if (showThinking && delta['type'] == 'thinking_delta') {
                  if (thinkBuf.isEmpty) thinkWatch.start();
                  thinkBuf.write(delta['thinking'] ?? '');
                }
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
                // 思考过程：DeepSeek-R1 用 reasoning_content，OpenAI o1 用 reasoning
                final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
                if (showThinking && reasoning != null && reasoning.toString().isNotEmpty) {
                  if (thinkBuf.isEmpty) thinkWatch.start();
                  thinkBuf.write(reasoning);
                }
              }
              final usage = json['usage'] as Map<String, dynamic>?;
              if (usage != null) {
                inTok = usage['prompt_tokens'] as int? ?? inTok;
                outTok = usage['completion_tokens'] as int? ?? outTok;
              }
            }
            if (mounted) {
              setState(() {
                _messages[msgIdx] = (role: 'assistant', content: buf.toString(), inputTokens: inTok, outputTokens: outTok,
                    blocks: thinkBuf.isEmpty ? null : [
                      {'type': 'thinking', 'thinking': thinkBuf.toString(), 'durationMs': thinkWatch.elapsedMilliseconds},
                    if (buf.isNotEmpty) {'type': 'text', 'text': buf.toString()},
                  ]);
            });
            }
            _scrollToBottom();
          } catch (_) {}
        }
      }

      final content = buf.toString();
      appState.logAiResponse(content);
      _genStart.stop();
      final elapsedMs = _genStart.elapsedMilliseconds;
      final speed = elapsedMs > 0 ? (content.length * 1000 / elapsedMs) : null;
      if (!mounted) return;
      setState(() {
        _messages[msgIdx] = (role: 'assistant', content: content, inputTokens: inTok, outputTokens: outTok,
            blocks: thinkBuf.isEmpty ? null : [
              {'type': 'thinking', 'thinking': thinkBuf.toString(), 'durationMs': thinkWatch.elapsedMilliseconds},
              if (content.isNotEmpty) {'type': 'text', 'text': content},
            ]);
        _loading = false;
        _lastGenSpeed = speed;
        if (inTok != null) _totalInputTokens += inTok;
        if (outTok != null) _totalOutputTokens += outTok;
      });
      _scrollToBottom();
      _tryParseGraph(content);
      _handleToolCalls(content);
      // 自动总结：首轮对话后生成会话标题
      _maybeGenerateTitle();
    } catch (e) {
      appState.logAiResponse('$e', error: true);
      if (!mounted) return;
      setState(() {
        _messages.add((role: 'assistant', content: 'Error: $e', inputTokens: null, outputTokens: null, blocks: null));
        _loading = false;
      });
      _scrollToBottom();
    } finally {
      sendClient?.close();  // 无论成功/异常/面板关闭，都释放 HTTP 连接
    }
  }

  /// 对话后自动生成会话标题（开启 aiAutoTitle 时，首轮对话触发一次）。
  Future<void> _maybeGenerateTitle() async {
    if (_titleGenerated) return;
    final appState = context.read<AppState>();
    final cfg = appState.config;
    if (!cfg.aiAutoTitle || _messages.isEmpty) return;
    final profile = _effectiveProfile;
    final key = profile?.apiKey.isNotEmpty == true ? profile!.apiKey : cfg.aiApiKey;
    if (key.isEmpty) return;
    _titleGenerated = true;
    try {
      final isAnthropic = (profile?.provider ?? cfg.aiProvider) == 'anthropic';
      final url = (profile?.apiUrl.isNotEmpty == true ? profile!.apiUrl : cfg.aiApiUrl);
      final model = profile?.model ?? cfg.aiModel;
      final uri = Uri.parse(_resolveEndpoint(url, isAnthropic));
      // 取最近几轮对话内容用于总结
      final recent = _messages.take(6).map((m) => '${m.role}: ${m.content.substring(0, m.content.length > 120 ? 120 : m.content.length)}').join('\n');
      final prompt = cfg.aiTitlePrompt;
      final body = isAnthropic
          ? {'model': model, 'max_tokens': 32, 'system': prompt, 'messages': [{'role': 'user', 'content': 'Summarize this conversation:\n$recent'}]}
          : {'model': model, 'max_tokens': 32, 'messages': [{'role': 'system', 'content': prompt}, {'role': 'user', 'content': 'Summarize this conversation:\n$recent'}]};
      final req = http.Request('POST', uri);
      if (isAnthropic) {
        req.headers['x-api-key'] = key;
        req.headers['anthropic-version'] = '2023-06-01';
      } else {
        req.headers['Authorization'] = 'Bearer $key';
      }
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
      final client = http.Client();
      try {
        final resp = await client.send(req).timeout(const Duration(seconds: 15));
        final respBody = await resp.stream.bytesToString();
        if (resp.statusCode != 200) return;
        final json = jsonDecode(respBody) as Map<String, dynamic>;
        String? title;
        if (isAnthropic) {
          final blocks = (json['content'] as List?) ?? [];
          if (blocks.isNotEmpty) title = (blocks[0]['text'] as String?) ?? '';
        } else {
          final choices = (json['choices'] as List?) ?? [];
          if (choices.isNotEmpty) title = ((choices[0]['message'] as Map<String, dynamic>?)?['content'] as String?) ?? '';
        }
        if (title != null && title.trim().isNotEmpty && mounted) {
          widget.onTitleGenerated?.call(title.trim().replaceAll(RegExp(r'[\n"]+'), ''));
        }
      } finally {
        client.close();
      }
    } catch (_) {
      // 标题生成失败不影响主对话
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
        // 会话模式：auto = 直接应用；ask = 生成后询问确认（图应用默认询问，
        // 白名单只影响工具类操作）。
        final autoApply = _effectiveApproveMode == 'auto' || cfg.aiAutoExecute;
        if (autoApply) {
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
    // AnimatedSwitcher 让展开/收起两个状态都能平滑过渡。
    // 关键点：两个 child 必须有不同 key，否则 Flutter 认为是同一个 widget
    // 不触发切换动画，导致"展开后收不回"。
    // ScaleTransition 的 begin 取 0.96（收起时新 child 是从小变大）。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(anim),
          alignment: Alignment.bottomRight,
          child: child,
        ),
      ),
      child: _expanded
          ? KeyedSubtree(key: const ValueKey('ai-expanded'), child: _buildExpanded(scheme))
          : KeyedSubtree(key: const ValueKey('ai-collapsed'), child: _buildCollapsed(scheme)),
    );
  }

  Widget _buildCollapsed(ColorScheme scheme) {
    return GlassPanel(
      radius: 14,
      blur: 12,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _expanded = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.smart_toy, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('AI', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
          ]),
        ),
      ),
    );
  }

  Widget _buildExpanded(ColorScheme scheme) {
    final s = widget.strings;
    // 玻璃面板：跟随全局玻璃配置（液态玻璃/模糊/无效果），主题着色跟随 glassFollowTheme
    return GlassPanel(
      radius: 16,
      blur: 14,
      child: Container(
        width: double.infinity, height: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(0),
          border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 6, 4),
            child: Row(children: [
              Icon(Icons.smart_toy, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              const Spacer(),
              // 历史记录按钮
              IconButton(
                icon: const Icon(Icons.history, size: 18),
                tooltip: s.isZh ? '历史记录' : 'History',
                onPressed: () {
                  // 用按钮自身位置作为菜单锚点，避免偏移
                  final box = context.findRenderObject() as RenderBox?;
                  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
                  if (box != null && overlay != null) {
                    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
                    _toggleHistoryAt(scheme, s, pos + const Offset(24, 8));
                  }
                },
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
              // 工具侧边栏开关
              Tooltip(
                message: s.isZh ? (_toolsOpen ? '收起工具面板' : '展开工具面板') : (_toolsOpen ? 'Collapse tools' : 'Expand tools'),
                child: IconButton(
                  icon: AnimatedRotation(
                    turns: _toolsOpen ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    child: const Icon(Icons.extension_outlined, size: 18),
                  ),
                  tooltip: s.isZh ? '工具' : 'Tools',
                  onPressed: () => setState(() => _toolsOpen = !_toolsOpen),
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.remove, size: 18),
                tooltip: s.isZh ? '收起' : 'Collapse',
                onPressed: () {
                  if (widget.onCollapseRequested != null) {
                    widget.onCollapseRequested!();
                  } else {
                    setState(() => _expanded = false);
                  }
                },
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
            ]),
          ),
          // token 用量 / 生成速度统计条
          if (_totalInputTokens > 0 || _totalOutputTokens > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(children: [
                Icon(Icons.data_usage, size: 11, color: scheme.outline),
                const SizedBox(width: 4),
                Text(
                  s.isZh
                      ? '输入 $_totalInputTokens / 输出 $_totalOutputTokens token'
                      : 'In $_totalInputTokens / Out $_totalOutputTokens tokens',
                  style: TextStyle(fontSize: 10, color: scheme.outline),
                ),
                if (_lastGenSpeed != null) ...[
                  const SizedBox(width: 10),
                  Icon(Icons.speed, size: 11, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    s.isZh
                        ? '${_lastGenSpeed!.toStringAsFixed(0)} 字符/秒'
                        : '${_lastGenSpeed!.toStringAsFixed(0)} chars/s',
                    style: TextStyle(fontSize: 10, color: scheme.outline),
                  ),
                ],
              ]),
            ),
          const Divider(height: 1),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // ── 可折叠工具侧边栏 ──
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                width: _toolsOpen ? 150 : 0,
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: scheme.outlineVariant.withAlpha(60))),
                ),
                clipBehavior: Clip.hardEdge,
                child: _toolsOpen ? _buildToolsSidebar(scheme, s) : const SizedBox.shrink(),
              ),
              // ── 聊天主区 ──
              Expanded(
                child: Column(children: [
                  Expanded(
                    child: _messages.isEmpty
                        ? _buildEmptyState(scheme, s)
                        : ListView.builder(
                            controller: _scrollCtrl,
                            padding: const EdgeInsets.all(12),
                            itemCount: _messages.length,
                            itemBuilder: (_, i) => RepaintBoundary(
                              // 稳定 key + 独立重绘层：流式更新只重绘当前这一条，
                              // 其余历史消息（含 Markdown）被隔离，不再整屏重绘抖动。
                              key: ValueKey('ai-msg-$i'),
                              child: _buildMessage(_messages[i], scheme),
                            ),
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
                      SizedBox(
                        width: 40, height: 40,
                        child: _loading
                            ? FilledButton(
                                onPressed: null,
                                style: FilledButton.styleFrom(
                                    padding: EdgeInsets.zero, shape: const CircleBorder()),
                                child: const SizedBox(width: 18, height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            : FilledButton(
                                onPressed: _send,
                                style: FilledButton.styleFrom(
                                    padding: EdgeInsets.zero, shape: const CircleBorder()),
                                child: const Icon(Icons.send, size: 18),
                              ),
                      ),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  /// 空对话时的引导：说明文字 + 几个可一键发送的示例提示（点击直接发起请求）。
  Widget _buildEmptyState(ColorScheme scheme, AppStrings s) {
    final hints = <String>[
      s.isZh ? '把这个视频转成 H.265 减小体积' : 'Transcode this video to H.265 to shrink it',
      s.isZh ? '提取视频里的音频为 MP3' : 'Extract the audio as MP3',
      s.isZh ? '每 2 秒截取一帧图片' : 'Extract a frame every 2 seconds',
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.smart_toy, size: 44, color: scheme.outline.withAlpha(80)),
          const SizedBox(height: 12),
          Text(s.aiChatHint, textAlign: TextAlign.center,
              style: TextStyle(color: scheme.outline, fontSize: 12)),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8, runSpacing: 8,
            children: [
              for (final h in hints)
                ActionChip(
                  avatar: Icon(Icons.bolt, size: 14, color: scheme.primary),
                  label: Text(h, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () { _ctrl.text = h; _send(); },
                ),
            ],
          ),
        ]),
      ),
    );
  }

  /// 历史记录：以弹出菜单形式展示（锚定历史按钮位置）。
  Future<void> _toggleHistoryAt(ColorScheme scheme, AppStrings s, Offset anchor) async {
    final list = await AiChatHistory.listSessions();
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final ovSize = overlay.size;
    final rect = RelativeRect.fromLTRB(
      anchor.dx.clamp(0, ovSize.width - 20),
      anchor.dy.clamp(0, ovSize.height - 20),
      ovSize.width - anchor.dx.clamp(0, ovSize.width - 20),
      ovSize.height - anchor.dy.clamp(0, ovSize.height - 20),
    );
    await showMenu<String>(
      context: context,
      position: rect,
      // 紧凑间距
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
      items: [
        if (list.isEmpty)
          const PopupMenuItem<String>(enabled: false,
              child: Padding(padding: EdgeInsets.symmetric(vertical: 2), child: Text('暂无历史记录', style: TextStyle(fontSize: 12))))
        else
          for (final e in list.take(12))
            PopupMenuItem<String>(
              value: '_load_${e['_file']}',
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
                const Icon(Icons.forum_outlined, size: 14),
                const SizedBox(width: 8),
                Flexible(child: Text(
                  (e['title'] as String?) ?? (s.isZh ? '未命名会话' : 'Untitled'),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                )),
              ]),
              ),
            ),
        if (list.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem<String>(value: '_save',
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(s.isZh ? '保存当前会话' : 'Save session', style: const TextStyle(fontSize: 12)))),
        if (list.isNotEmpty)
          PopupMenuItem<String>(value: '_clear',
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(s.isZh ? '清空历史' : 'Clear history', style: const TextStyle(fontSize: 12)))),
      ],
    ).then((v) async {
      if (v == null) return;
      if (v == '_save') {
        final saved = await _saveCurrentSession();
        if (mounted && saved != null) {
          showToast(context, s.isZh ? '已保存当前会话' : 'Session saved', type: ToastType.success);
        }
      } else if (v == '_clear') {
        await AiChatHistory.clearAll();
        if (mounted) showToast(context, s.isZh ? '历史已清空' : 'History cleared', type: ToastType.success);
      } else if (v.startsWith('_load_')) {
        final file = v.substring(6);
        final sessions = await AiChatHistory.listSessions();
        final entry = sessions.where((e) => e['_file'] == file).firstOrNull;
        if (entry != null) _loadHistorySession(entry, s);
      }
    });
  }

  /// 加载一条历史会话到当前面板。
  void _loadHistorySession(Map<String, dynamic> entry, AppStrings s) {
    final msgs = (entry['messages'] as List?) ?? [];
    setState(() {
      _messages.clear();
      _messages.addAll(msgs.map((m) {
        final mm = m as Map<String, dynamic>;
        return (
          role: (mm['role'] as String?) ?? 'assistant',
          content: (mm['content'] as String?) ?? '',
          inputTokens: (mm['inputTokens'] as num?)?.toInt(),
          outputTokens: (mm['outputTokens'] as num?)?.toInt(),
          blocks: null,
        );
      }));
      _sessionProvider = (entry['provider'] as String?) ?? _sessionProvider;
      _sessionModel = (entry['model'] as String?) ?? _sessionModel;
      // 恢复 token 统计
      _totalInputTokens = 0;
      _totalOutputTokens = 0;
      for (final m in _messages) {
        _totalInputTokens += m.inputTokens ?? 0;
        _totalOutputTokens += m.outputTokens ?? 0;
      }
    });
    _scrollToBottom();
  }

  /// 保存当前会话到历史。
  Future<String?> _saveCurrentSession() async {
    final userMsgs = _messages.where((m) => m.role == 'user').toList();
    if (userMsgs.isEmpty) return null;
    final title = userMsgs.first.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final t = title.length > 24 ? '${title.substring(0, 24)}…' : title;
    return AiChatHistory.saveSession(
      title: t,
      provider: _effectiveProvider,
      model: _effectiveModel,
      messages: _messages.map((m) => {
        'role': m.role,
        'content': m.content,
        'inputTokens': m.inputTokens,
        'outputTokens': m.outputTokens,
      }).toList(),
    );
  }

  /// 工具侧边栏：列出全部工具，点击插入模板到输入框。
  /// 插入模板本身不需要任何权限（权限只约束 AI 自动执行时是否放行），
  /// 因此工具始终可点击；若对应权限未开启，仅显示一个小锁标记提示。
  Widget _buildToolsSidebar(ColorScheme scheme, AppStrings s) {
    final cfg = context.read<AppState>().config;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Row(children: [
          Text(s.isZh ? '工具' : 'Tools',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.primary)),
          const Spacer(),
          Text('${_toolTemplates.length}',
              style: TextStyle(fontSize: 9, color: scheme.outline)),
        ]),
      ),
      Divider(height: 1, color: scheme.outlineVariant.withAlpha(40)),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: _toolTemplates.length,
          itemBuilder: (_, i) {
            final t = _toolTemplates[i];
            // 该工具是否属于只读/写操作（仅用于权限提示，不阻断插入）
            final readOnly = t.name == 'list_directory' || t.name == 'read_file_info' || t.name == 'probe_video' || t.name == 'pick_file' ||
                t.name == 'list_nodes' || t.name == 'list_connections' || t.name == 'get_node_types' || t.name == 'list_tasks';
            final needsWrite = t.name == 'clear_all' || t.name == 'undo' || t.name == 'redo' || t.name == 'save' ||
                t.name == 'modify_node' || t.name == 'add_node' || t.name == 'delete_node' ||
                t.name == 'connect_nodes' || t.name == 'disconnect_nodes' || t.name == 'cancel_tasks' ||
                t.name == 'error_check' || t.name == 'ask_user';
            final permitted = readOnly ? cfg.aiReadAccess : (needsWrite ? cfg.aiWriteAccess : true);
            final isDisabled = _disabledTools.contains(t.name);
            return Tooltip(
              message: (isDisabled
                  ? (s.isZh ? '已禁用 - 右键可启用' : 'Disabled - right-click to enable')
                  : '${t.desc}\n${t.template}')
                  + (permitted ? '' : '\n⚠ ${s.isZh ? 'AI 自动执行需要开启相应权限' : 'AI auto-execution needs permission'} (设置→AI)'),
              waitDuration: const Duration(milliseconds: 400),
              child: InkWell(
                // 右键：禁用 / 启用 该工具
                onSecondaryTap: () => _toggleToolEnabled(t.name, s),
                onTap: isDisabled
                    ? null
                    : () {
                        // 点击插入模板到输入框并聚焦
                        final cur = _ctrl.selection;
                        final text = _ctrl.text;
                        final start = cur.isValid ? cur.start : text.length;
                        final next = text.substring(0, start) + t.template + text.substring(start);
                        _ctrl.value = TextEditingValue(
                          text: next,
                          selection: TextSelection.collapsed(offset: start + t.template.length),
                        );
                      },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(children: [
                    // 每个工具只显示一个状态图标：禁用→block，只读→visibility，可写→build。
                    // （原先这里 if/else 一次又无条件再画一个，导致图标重复叠在一起。）
                    Icon(
                      isDisabled
                          ? Icons.block
                          : (readOnly ? Icons.visibility_outlined : Icons.build_outlined),
                      size: 13,
                      color: isDisabled ? scheme.error.withAlpha(180) : scheme.primary,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDisabled ? scheme.outline.withAlpha(90) : scheme.onSurface,
                          fontWeight: FontWeight.w500,
                          decoration: isDisabled ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                    if (isDisabled)
                      Icon(Icons.block, size: 10, color: scheme.error.withAlpha(160))
                    else if (!permitted)
                      Tooltip(
                        message: s.isZh ? 'AI 自动执行需要权限 (设置→AI)' : 'Needs permission (Settings→AI)',
                        child: Icon(Icons.lock_outline, size: 10, color: scheme.outline.withAlpha(70)),
                      ),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          s.isZh ? '点击工具插入到输入框' : 'Tap a tool to insert',
          style: TextStyle(fontSize: 9, color: scheme.outline),
          textAlign: TextAlign.center,
        ),
      ),
    ]);
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
        : _buildAssistantContent(msg.content, scheme);
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
                CircleAvatar(radius: 14, backgroundColor: scheme.primaryContainer, child: Icon(Icons.smart_toy, size: 14, color: scheme.primary)),
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

  /// 按主题关键色缓存的 Markdown 样式（主题不变即复用同一实例）。
  MarkdownStyleSheet _markdownStyle(ColorScheme scheme) {
    final key = (
      brightness: scheme.brightness,
      primary: scheme.primary,
      onSurface: scheme.onSurface,
      onSurfaceVariant: scheme.onSurfaceVariant,
      primaryContainer: scheme.primaryContainer,
      surfaceContainerHighest: scheme.surfaceContainerHighest,
      outline: scheme.outline,
      outlineVariant: scheme.outlineVariant,
    );
    if (_mdStyleKey != key) {
      _mdStyleKey = key;
      _mdStyle = MarkdownStyleSheet(
        p: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.5),
        h1: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.primary, height: 1.3),
        h2: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: scheme.primary, height: 1.3),
        h3: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface, height: 1.3),
        h4: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface, height: 1.3),
        listBullet: TextStyle(fontSize: 12, color: scheme.primary),
        blockquote: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic, height: 1.5),
        blockquoteDecoration: BoxDecoration(
          color: scheme.primaryContainer.withAlpha(40),
          border: Border(left: BorderSide(color: scheme.primary.withAlpha(180), width: 3)),
          borderRadius: BorderRadius.circular(4),
        ),
        blockquotePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        code: TextStyle(fontSize: 11, color: scheme.primary, backgroundColor: scheme.surfaceContainerHighest, fontFamily: AppTheme.monoFont),
        codeblockPadding: const EdgeInsets.all(10),
        codeblockDecoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withAlpha(80),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
        ),
        a: TextStyle(fontSize: 12, color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary.withAlpha(120)),
        strong: TextStyle(fontSize: 12, color: scheme.onSurface, fontWeight: FontWeight.w700),
        em: TextStyle(fontSize: 12, color: scheme.onSurface, fontStyle: FontStyle.italic),
        tableHead: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onSurface),
        tableBody: TextStyle(fontSize: 11, color: scheme.onSurface),
        tableBorder: TableBorder.all(color: scheme.outlineVariant.withAlpha(80)),
        tableColumnWidth: const FlexColumnWidth(),
        horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant.withAlpha(80)))),
      );
    }
    return _mdStyle!;
  }

  /// 渲染助手回复：把 [TOOL_CALL:...] 标记转成可视的工具调用块，其余为 Markdown。
  Widget _buildAssistantContent(String content, ColorScheme scheme) {
    final toolRe = RegExp(r'\[TOOL_CALL:([^\]]+)\]');
    final matches = toolRe.allMatches(content).toList();
    final mdStyle = _markdownStyle(scheme);
    Widget markdownBody(String data) => MarkdownBody(
          data: data,
          selectable: true,
          styleSheet: mdStyle,
        );
    if (matches.isEmpty) return markdownBody(content);
    // 有工具调用：拆成 [文本, 工具块, 文本, ...] 交替
    final children = <Widget>[];
    var last = 0;
    for (final m in matches) {
      if (m.start > last) {
        final text = content.substring(last, m.start).trim();
        if (text.isNotEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SelectableText(text, style: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.5)),
          ));
        }
      }
      final parts = m.group(1)!.split('|');
      final tool = parts[0];
      final argsText = parts.length > 1 ? parts.sublist(1).join(' | ') : '';
      children.add(_buildBlock({'type': 'tool_use', 'name': tool, 'input': {'args': argsText}}, scheme));
      last = m.end;
    }
    final tail = content.substring(last).trim();
    if (tail.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: SelectableText(tail, style: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.5)),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _buildBlock(Map<String, dynamic> block, ColorScheme scheme) {
    final type = block['type'] as String? ?? 'text';
    if (type == 'text') {
      return SelectableText(block['text'] as String? ?? '', style: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.5));
    }
    final label = switch (type) {
      'thinking' => '思考',
      'tool_use' => '调用工具: ${block['name'] ?? 'unknown'}',
      'tool_result' => '工具结果',
      _ => type,
    };
    final icon = switch (type) {
      'thinking' => Icons.psychology_outlined,
      'tool_use' => Icons.handyman_outlined,
      'tool_result' => Icons.receipt_long_outlined,
      _ => Icons.info_outline,
    };
    final body = switch (type) {
      'thinking' => block['thinking'] as String? ?? '',
      'tool_use' => const JsonEncoder.withIndent('  ').convert(block['input'] ?? {}),
      'tool_result' => block['content']?.toString() ?? '',
      _ => block.toString(),
    };
    // 思考耗时（毫秒），由流式解析记录
    final thinkMs = (block['durationMs'] as num?)?.toInt();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withAlpha(50),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          // 思考默认折叠（紧凑）；工具结果默认展开
          initiallyExpanded: type == 'tool_result',
          dense: true,
          title: Row(children: [
            Icon(icon, size: 13, color: type == 'thinking' ? scheme.primary : scheme.outline),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: type == 'thinking' ? scheme.primary : scheme.outline, fontStyle: FontStyle.italic)),
            ),
            if (thinkMs != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withAlpha(120),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  thinkMs >= 1000 ? '${(thinkMs / 1000).toStringAsFixed(1)}s' : '${thinkMs}ms',
                  style: TextStyle(fontSize: 9, color: scheme.outline),
                ),
              ),
            ],
          ]),
          children: [
            // 等宽字体 + 可滚动，长 JSON/日志不会被截断
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: SelectableText(body,
                    style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withAlpha(190),
                        height: 1.45,
                        fontFamily: AppTheme.monoFont)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
