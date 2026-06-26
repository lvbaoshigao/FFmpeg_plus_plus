import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/graph_executor.dart';
import '../theme/app_strings.dart';
import '../widgets/step_editors/start_step_editor.dart';
import '../widgets/step_editors/av_process_step_editor.dart';
import '../widgets/step_editors/subtitle_step_editor.dart';
import '../widgets/step_editors/output_step_editor.dart';
import '../widgets/step_editors/clip_step_editor.dart';
import '../widgets/step_editors/frame_step_editor.dart';

const _uuid = Uuid();

const _nodeW = 160.0;
const _nodeH = 56.0;
const _canvasSize = 6000.0;
const _portZoneW = 14.0;
const _totalNodeW = _portZoneW + _nodeW + _portZoneW;

class PipelineEditorPage extends StatefulWidget {
  final VideoFile video;
  final void Function(PipelineGraph graph) onSave;
  const PipelineEditorPage({super.key, required this.video, required this.onSave});
  @override
  State<PipelineEditorPage> createState() => _PipelineEditorPageState();
}

class _PipelineEditorPageState extends State<PipelineEditorPage> {
  final List<PipelineNode> _nodes = [];
  final List<PipelineConnection> _connections = [];
  String? _selectedNodeId;

  // 连线拖拽状态
  String? _dragFromNodeId;
  bool _dragIsOutput = true;
  Offset? _dragLineEnd;

  // 缩略图缓存
  String? _thumbPath;

  final TransformationController _transformCtrl = TransformationController();

  @override
  void initState() {
    super.initState();
    final g = widget.video.pipelineGraph;
    if (g.nodes.isNotEmpty) {
      final copied = g.copy();
      _nodes.addAll(copied.nodes);
      _connections.addAll(copied.connections);
    }
    _genThumb();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _transformCtrl.value = Matrix4.identity()..translate(-_canvasSize / 2 + 300, -_canvasSize / 2 + 200);
    });
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  Future<void> _genThumb() async {
    final fp = widget.video.filepath;
    final f = File('${Directory.systemTemp.path}/ffmpegpp_thumb_${fp.hashCode}.jpg');
    if (await f.exists()) { if (mounted) setState(() => _thumbPath = f.path); return; }
    try {
      final r = await Process.run('ffmpeg', ['-y', '-ss', '5', '-i', fp, '-vframes', '1', '-q:v', '3', '-s', '176x108', f.path]);
      if (r.exitCode == 0 && await f.exists()) { if (mounted) setState(() => _thumbPath = f.path); }
    } catch (_) {}
  }

  PipelineNode? get _selectedNode {
    if (_selectedNodeId == null) return null;
    final idx = _nodes.indexWhere((n) => n.id == _selectedNodeId);
    return idx >= 0 ? _nodes[idx] : null;
  }

  IconData _stepIcon(PipelineStepType t) {
    switch (t) {
      case PipelineStepType.start: return Icons.movie_outlined;
      case PipelineStepType.avProcess: return Icons.tune_outlined;
      case PipelineStepType.subtitle: return Icons.subtitles_outlined;
      case PipelineStepType.clip: return Icons.content_cut;
      case PipelineStepType.frame: return Icons.photo_camera_outlined;
      case PipelineStepType.output: return Icons.save_alt_outlined;
    }
  }

  Color _nodeColor(PipelineStepType t, ColorScheme scheme) {
    switch (t) {
      case PipelineStepType.start: return scheme.primaryContainer;
      case PipelineStepType.output: return scheme.tertiaryContainer;
      default: return scheme.surfaceContainerHighest;
    }
  }

  // ── 节点操作 ──

  void _addNodeAt(PipelineStepType type, Offset canvasPos) {
    setState(() {
      _nodes.add(PipelineNode(
        id: _uuid.v4(), type: type,
        x: canvasPos.dx, y: canvasPos.dy,
      ));
    });
  }

  void _deleteNode(String nodeId) {
    setState(() {
      _nodes.removeWhere((n) => n.id == nodeId);
      _connections.removeWhere((c) => c.fromNodeId == nodeId || c.toNodeId == nodeId);
      if (_selectedNodeId == nodeId) _selectedNodeId = null;
    });
  }

  void _addConnection(String fromId, String toId) {
    if (fromId == toId) return;
    final fromNode = _nodes.firstWhere((n) => n.id == fromId, orElse: () => _nodes.first);
    final toNode = _nodes.firstWhere((n) => n.id == toId, orElse: () => _nodes.first);
    if (!fromNode.hasOutput || !toNode.hasInput) return;
    if (_connections.any((c) => c.fromNodeId == fromId && c.toNodeId == toId)) return;
    setState(() {
      _connections.add(PipelineConnection(id: _uuid.v4(), fromNodeId: fromId, toNodeId: toId));
    });
  }

  void _deleteConnection(String connId) {
    setState(() {
      _connections.removeWhere((c) => c.id == connId);
    });
  }

  PipelineConnection? _hitTestConnection(Offset pos) {
    const threshold = 8.0;
    for (final conn in _connections) {
      final fi = _nodes.indexWhere((n) => n.id == conn.fromNodeId);
      final ti = _nodes.indexWhere((n) => n.id == conn.toNodeId);
      if (fi < 0 || ti < 0) continue;
      final from = _nodes[fi];
      final to = _nodes[ti];
      final p1 = Offset(from.x + _portZoneW + _nodeW + _portZoneW / 2, from.y + _nodeH / 2);
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
    final graph = PipelineGraph(nodes: _nodes, connections: _connections);
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

  Offset _outPort(PipelineNode n) => Offset(n.x + _portZoneW + _nodeW + _portZoneW / 2, n.y + _nodeH / 2);
  Offset _inPort(PipelineNode n) => Offset(n.x + _portZoneW / 2, n.y + _nodeH / 2);

  // ── 右键菜单 ──

  void _showCanvasMenu(Offset screenPos) {
    final s = AppStrings.of(context.read<AppState>().config.language);
    final scheme = Theme.of(context).colorScheme;
    final canvasPos = _screenToCanvas(screenPos);

    final allTypes = [
      PipelineStepType.start,
      PipelineStepType.avProcess,
      PipelineStepType.subtitle,
      PipelineStepType.clip,
      PipelineStepType.frame,
      PipelineStepType.output,
    ];

    showMenu<PipelineStepType>(
      context: context,
      position: RelativeRect.fromLTRB(screenPos.dx, screenPos.dy, screenPos.dx + 1, screenPos.dy + 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: allTypes.map((t) {
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
          ]),
        );
      }).toList(),
    ).then((type) {
      if (type != null) _addNodeAt(type, canvasPos);
    });
  }

  void _showNodeMenu(Offset screenPos, String nodeId) {
    final s = AppStrings.of(context.read<AppState>().config.language);
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
      ],
    ).then((action) {
      if (action == 'delete') _deleteNode(nodeId);
    });
  }

  // ── 构建步骤编辑器 ──

  Widget _buildStepEditor(PipelineNode node, bool isZh) {
    void onChanged() => setState(() {});
    final v = widget.video;
    switch (node.type) {
      case PipelineStepType.start:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          if (_thumbPath != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(_thumbPath!), width: double.infinity, height: 140, fit: BoxFit.cover),
              ),
            ),
          StartStepEditor(filename: v.filename, resolution: v.resolution, durationStr: v.durationStr,
              sizeMb: v.sizeMb, codec: v.codec, pixFmt: v.pixFmt, audioCodec: v.audioCodec, audioChannels: v.audioChannels, isZh: isZh),
        ]);
      case PipelineStepType.avProcess:
        return AvProcessStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh);
      case PipelineStepType.subtitle:
        return SubtitleStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh, embeddedSubtitles: v.subtitles);
      case PipelineStepType.output:
        return OutputStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, isZh: isZh,
            sourceFilename: v.filename, defaultOutputDir: context.read<AppState>().config.defaultOutputDir);
      case PipelineStepType.clip:
        return ClipStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, videoPath: v.filepath, videoDuration: v.duration, isZh: isZh);
      case PipelineStepType.frame:
        return FrameStepEditor(key: ValueKey(node.id), params: node.params, onChanged: onChanged, videoPath: v.filepath, videoDuration: v.duration, isZh: isZh);
    }
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
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () async {
            final nav = Navigator.of(context);
            if (await _onWillPop()) nav.pop();
          }),
          title: Text(
            s.isZh ? '编辑: ${widget.video.filename}' : 'Edit: ${widget.video.filename}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          actions: [
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
        ),
        body: Column(children: [
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
      )),
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
    if (!cfg.glassEffect) return child;
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

  Widget _buildCanvas(ColorScheme scheme, AppStrings s) {
    final glass = context.read<AppState>().config.glassEffect;

    final canvas = Listener(
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
          final canvasPos = _screenToCanvas(e.localPosition);
          final hitNode = _findNodeAtCanvasPos(canvasPos);
          if (hitNode != null) return;
          final hitConn = _hitTestConnection(canvasPos);
          if (hitConn != null) {
            _showConnectionMenu(e.position, hitConn);
          } else {
            _showCanvasMenu(e.position);
          }
        }
      },
      child: InteractiveViewer(
        transformationController: _transformCtrl,
        constrained: false,
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
                selectedNodeId: _selectedNodeId,
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
          ]),
        ),
      ),
    );

    final inner = Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Row(children: [
          Icon(Icons.account_tree_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(s.isZh ? '节点编辑器' : 'Node Editor',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          const Spacer(),
          Text(s.isZh ? '右键添加节点' : 'Right-click to add',
              style: TextStyle(fontSize: 10, color: scheme.outline)),
        ]),
      ),
      const Divider(height: 1, indent: 12, endIndent: 12),
      Expanded(child: ClipRRect(
        borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(12), bottomRight: Radius.circular(12)),
        child: Stack(children: [
          canvas,
          if (context.read<AppState>().config.debugMode)
            Positioned(
              left: 8, bottom: 8, right: 8,
              child: IgnorePointer(child: Text(
                GraphExecutor.describeGraph(PipelineGraph(nodes: _nodes, connections: _connections)),
                style: TextStyle(fontSize: 10, color: scheme.onSurface.withAlpha(128), height: 1.4),
              )),
            ),
        ]),
      )),
    ]);

    if (glass) return _glassWrap(inner, scheme);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
      ),
      child: inner,
    );
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
    final selected = node.id == _selectedNodeId;

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
              width: 10, height: 10,
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
          onTap: () => setState(() => _selectedNodeId = node.id),
          onPanUpdate: (d) {
            setState(() {
              node.x += d.delta.dx;
              node.y += d.delta.dy;
            });
          },
          onSecondaryTapUp: (d) => _showNodeMenu(d.globalPosition, node.id),
          child: Container(
            width: _nodeW,
            height: _nodeH,
            decoration: BoxDecoration(
              color: _nodeColor(node.type, scheme),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant.withAlpha(100),
                width: selected ? 2 : 1,
              ),
              boxShadow: [BoxShadow(color: scheme.shadow.withAlpha(30), blurRadius: 6, offset: const Offset(0, 2))],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(children: [
              Icon(_stepIcon(node.type), size: 16, color: selected ? scheme.primary : scheme.onSurface),
              const SizedBox(width: 4),
              Expanded(child: Text(
                s.isZh ? node.label : node.labelEn,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: scheme.onSurface),
                overflow: TextOverflow.ellipsis,
              )),
            ]),
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
      if (pos.dx >= n.x && pos.dx <= n.x + _totalNodeW && pos.dy >= n.y && pos.dy <= n.y + _nodeH) {
        return n;
      }
    }
    return null;
  }

  // ── 右侧面板 ──

  Widget _buildRightPanel(ColorScheme scheme, AppStrings s) {
    final glass = context.read<AppState>().config.glassEffect;
    final node = _selectedNode;

    Widget inner;
    if (node != null) {
      inner = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant.withAlpha(40)))),
          child: Row(children: [
            Icon(_stepIcon(node.type), size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(s.isZh ? node.label : node.labelEn,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface))),
          ]),
        ),
        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: _buildStepEditor(node, s.isZh),
        )),
      ]);
    } else {
      inner = Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.touch_app_outlined, size: 40, color: scheme.outline.withAlpha(80)),
        const SizedBox(height: 12),
        Text(s.isZh ? '选择节点开始编辑' : 'Select a node to edit',
            style: TextStyle(color: scheme.outline, fontSize: 14)),
        const SizedBox(height: 6),
        Text(s.isZh ? '右键画布添加节点' : 'Right-click canvas to add',
            style: TextStyle(color: scheme.outline.withAlpha(120), fontSize: 12)),
      ]));
    }

    if (glass) return _glassWrap(inner, scheme);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
      ),
      child: inner,
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
        Text('${v.resolution}  |  ${v.durationStr}  |  ${v.sizeMb.toStringAsFixed(1)} MB',
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
  final String? selectedNodeId;

  _ConnectionPainter({required this.nodes, required this.connections, required this.color, this.selectedNodeId});

  @override
  void paint(Canvas canvas, Size size) {
    for (final conn in connections) {
      final fromIdx = nodes.indexWhere((n) => n.id == conn.fromNodeId);
      final toIdx = nodes.indexWhere((n) => n.id == conn.toNodeId);
      if (fromIdx < 0 || toIdx < 0) continue;

      final from = nodes[fromIdx];
      final to = nodes[toIdx];

      final p1 = Offset(from.x + _portZoneW + _nodeW + _portZoneW / 2, from.y + _nodeH / 2);
      final p2 = Offset(to.x + _portZoneW / 2, to.y + _nodeH / 2);
      final dx = (p2.dx - p1.dx).abs() * 0.5;

      final highlighted = conn.fromNodeId == selectedNodeId || conn.toNodeId == selectedNodeId;
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
