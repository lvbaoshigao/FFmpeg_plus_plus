import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/frame_preview.dart';

class VideoCropStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final String videoPath;
  final int videoWidth;
  final int videoHeight;
  final double fps;
  final bool isZh;

  const VideoCropStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    required this.videoPath,
    required this.videoWidth,
    required this.videoHeight,
    required this.fps,
    this.isZh = true,
  });

  @override
  State<VideoCropStepEditor> createState() => _VideoCropStepEditorState();
}

class _VideoCropStepEditorState extends State<VideoCropStepEditor> {
  Map<String, dynamic> get p => widget.params;
  late TextEditingController _frameCtrl;
  String? _framePath;
  String? _fullFramePath;
  bool _extracting = false;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('crop_mode', () => 'keep');
    p.putIfAbsent('frame_number', () => 0);
    p.putIfAbsent('regions', () => <Map<String, dynamic>>[]);
    p.putIfAbsent('crop_x', () => 0);
    p.putIfAbsent('crop_y', () => 0);
    p.putIfAbsent('crop_w', () => widget.videoWidth);
    p.putIfAbsent('crop_h', () => widget.videoHeight);
    _frameCtrl = TextEditingController(text: '${(p['frame_number'] as num?)?.toInt() ?? 0}');
  }

  @override
  void dispose() {
    _frameCtrl.dispose();
    super.dispose();
  }

  void _update(String key, dynamic value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  double get _frameTime {
    final frame = (p['frame_number'] as num?)?.toInt() ?? 0;
    final fps = widget.fps > 0 ? widget.fps : 30.0;
    return frame / fps;
  }

  Future<void> _extractFrame() async {
    setState(() => _extracting = true);
    final time = _frameTime;

    final thumbPath = await FramePreview.generatePreview(widget.videoPath, time, width: 480);
    final fullPath = await FramePreview.generateFullFrame(widget.videoPath, time);

    if (mounted) {
      setState(() {
        _framePath = thumbPath;
        _fullFramePath = fullPath;
        _extracting = false;
      });
    }
  }

  List<Rect> _regionsFromParams() {
    final raw = p['regions'];
    if (raw is! List) return [];
    return raw.map((r) {
      if (r is! Map) return Rect.zero;
      return Rect.fromLTWH(
        (r['x'] as num?)?.toDouble() ?? 0,
        (r['y'] as num?)?.toDouble() ?? 0,
        (r['w'] as num?)?.toDouble() ?? 0,
        (r['h'] as num?)?.toDouble() ?? 0,
      );
    }).where((r) => r.width > 0 && r.height > 0).toList();
  }

  void _saveRegions(List<Rect> regions) {
    final list = regions.map((r) => {
      'x': r.left.round(),
      'y': r.top.round(),
      'w': r.width.round(),
      'h': r.height.round(),
    }).toList();
    p['regions'] = list;
    _computeFinalCrop(regions);
    widget.onChanged();
  }

  void _computeFinalCrop(List<Rect> regions) {
    final vw = widget.videoWidth.toDouble();
    final vh = widget.videoHeight.toDouble();
    final mode = p['crop_mode'] as String? ?? 'keep';

    if (regions.isEmpty) {
      p['crop_x'] = 0;
      p['crop_y'] = 0;
      p['crop_w'] = vw.toInt();
      p['crop_h'] = vh.toInt();
      return;
    }

    if (mode == 'keep') {
      final union = regions.reduce((a, b) => a.expandToInclude(b));
      p['crop_x'] = union.left.round().clamp(0, vw.toInt());
      p['crop_y'] = union.top.round().clamp(0, vh.toInt());
      p['crop_w'] = union.width.round().clamp(1, vw.toInt());
      p['crop_h'] = union.height.round().clamp(1, vh.toInt());
    } else {
      double left = 0, top = 0, right = vw, bottom = vh;
      for (final r in regions) {
        if (r.left <= 1) left = math.max(left, r.right);
        if (r.right >= vw - 1) right = math.min(right, r.left);
        if (r.top <= 1) top = math.max(top, r.bottom);
        if (r.bottom >= vh - 1) bottom = math.min(bottom, r.top);
      }
      if (right <= left) right = vw;
      if (bottom <= top) bottom = vh;
      p['crop_x'] = left.round().clamp(0, vw.toInt());
      p['crop_y'] = top.round().clamp(0, vh.toInt());
      p['crop_w'] = (right - left).round().clamp(1, vw.toInt());
      p['crop_h'] = (bottom - top).round().clamp(1, vh.toInt());
    }
  }

  Future<void> _openSelectionTool() async {
    if (_fullFramePath == null) return;
    final regions = await showDialog<List<Rect>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _VideoCropOverlayDialog(
        framePath: _fullFramePath!,
        videoWidth: widget.videoWidth,
        videoHeight: widget.videoHeight,
        cropMode: p['crop_mode'] as String? ?? 'keep',
        initialRegions: _regionsFromParams(),
        isZh: widget.isZh,
      ),
    );
    if (regions != null) {
      setState(() => _saveRegions(regions));
    }
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mode = p['crop_mode'] as String? ?? 'keep';
    final regions = _regionsFromParams();
    final cx = (p['crop_x'] as num?)?.toInt() ?? 0;
    final cy = (p['crop_y'] as num?)?.toInt() ?? 0;
    final cw = (p['crop_w'] as num?)?.toInt() ?? widget.videoWidth;
    final ch = (p['crop_h'] as num?)?.toInt() ?? widget.videoHeight;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '视频裁剪' : 'Video Crop',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 16),

        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'keep', label: Text(zh ? '保留区域' : 'Keep', style: const TextStyle(fontSize: 12))),
            ButtonSegment(value: 'remove', label: Text(zh ? '移除区域' : 'Remove', style: const TextStyle(fontSize: 12))),
          ],
          selected: {mode},
          onSelectionChanged: (v) {
            _update('crop_mode', v.first);
            if (regions.isNotEmpty) {
              setState(() => _computeFinalCrop(regions));
              widget.onChanged();
            }
          },
          style: ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 16),

        Text(zh ? '提取帧' : 'Extract Frame',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(
            controller: _frameCtrl,
            decoration: InputDecoration(labelText: zh ? '帧号' : 'Frame #'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) => p['frame_number'] = int.tryParse(v) ?? 0,
          )),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _extracting ? null : _extractFrame,
            child: _extracting
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                : Text(zh ? '提取' : 'Extract', style: const TextStyle(fontSize: 12)),
          ),
        ]),
        const SizedBox(height: 8),

        if (_framePath != null && File(_framePath!).existsSync())
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(_framePath!), width: double.infinity, height: 160, fit: BoxFit.contain),
          )
        else
          Container(
            width: double.infinity, height: 100,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(60),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(child: Text(zh ? '请先提取帧' : 'Extract a frame first',
                style: TextStyle(fontSize: 11, color: cs.outline))),
          ),
        const SizedBox(height: 16),

        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: _fullFramePath != null ? _openSelectionTool : null,
          icon: const Icon(Icons.crop_free, size: 18),
          label: Text(zh ? '打开选择工具' : 'Open Selection Tool', style: const TextStyle(fontSize: 13)),
        )),
        const SizedBox(height: 12),

        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withAlpha(60),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '${zh ? "选区" : "Regions"}: ${regions.length}  |  '
              '${zh ? "模式" : "Mode"}: ${mode == 'keep' ? (zh ? '保留' : 'Keep') : (zh ? '移除' : 'Remove')}',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface),
            ),
            const SizedBox(height: 4),
            Text(
              'Crop: ${cw}x$ch+$cx+$cy',
              style: TextStyle(fontSize: 11, color: cs.outline, fontFamily: 'monospace'),
            ),
          ]),
        ),
        const SizedBox(height: 12),

        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withAlpha(60),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 14, color: cs.outline),
            const SizedBox(width: 8),
            Expanded(child: Text(
              zh ? '保留模式：选中的区域将被保留，其余部分被裁掉。\n移除模式：选中的黑边/边缘区域将被去除。'
                 : 'Keep mode: selected regions are kept, rest is cropped.\nRemove mode: selected edge/bar regions are removed.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ])),
    );
  }
}

class _VideoCropOverlayDialog extends StatefulWidget {
  final String framePath;
  final int videoWidth;
  final int videoHeight;
  final String cropMode;
  final List<Rect> initialRegions;
  final bool isZh;

  const _VideoCropOverlayDialog({
    required this.framePath,
    required this.videoWidth,
    required this.videoHeight,
    required this.cropMode,
    required this.initialRegions,
    required this.isZh,
  });

  @override
  State<_VideoCropOverlayDialog> createState() => _VideoCropOverlayDialogState();
}

class _VideoCropOverlayDialogState extends State<_VideoCropOverlayDialog> {
  late List<Rect> _regions;
  final List<List<Rect>> _undoStack = [];
  Offset? _dragStart;
  Rect? _currentDrag;
  int? _activeRegionIdx;
  String? _activeEdge;

  @override
  void initState() {
    super.initState();
    _regions = List.of(widget.initialRegions);
  }

  void _pushUndo() {
    _undoStack.add(List.of(_regions));
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() => _regions = _undoStack.removeLast());
  }

  (int, String)? _hitTestEdge(Offset local, double scale, Offset imgOffset) {
    const threshold = 12.0;
    for (int i = _regions.length - 1; i >= 0; i--) {
      final r = _toDisplay(_regions[i], scale, imgOffset);
      final corners = {
        'tl': r.topLeft, 'tr': r.topRight,
        'bl': r.bottomLeft, 'br': r.bottomRight,
      };
      for (final e in corners.entries) {
        if ((local - e.value).distance < threshold) return (i, e.key);
      }
      final edges = <String, bool>{
        'top': (local.dy - r.top).abs() < threshold && local.dx >= r.left && local.dx <= r.right,
        'bottom': (local.dy - r.bottom).abs() < threshold && local.dx >= r.left && local.dx <= r.right,
        'left': (local.dx - r.left).abs() < threshold && local.dy >= r.top && local.dy <= r.bottom,
        'right': (local.dx - r.right).abs() < threshold && local.dy >= r.top && local.dy <= r.bottom,
      };
      for (final e in edges.entries) {
        if (e.value) return (i, e.key);
      }
      if (r.contains(local)) return (i, 'move');
    }
    return null;
  }

  Rect _toDisplay(Rect r, double scale, Offset offset) {
    return Rect.fromLTWH(
      r.left * scale + offset.dx,
      r.top * scale + offset.dy,
      r.width * scale,
      r.height * scale,
    );
  }

  Rect _toVideo(Rect r, double scale, Offset offset) {
    return Rect.fromLTWH(
      ((r.left - offset.dx) / scale).clamp(0, widget.videoWidth.toDouble()),
      ((r.top - offset.dy) / scale).clamp(0, widget.videoHeight.toDouble()),
      (r.width / scale).clamp(1, widget.videoWidth.toDouble()),
      (r.height / scale).clamp(1, widget.videoHeight.toDouble()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final screenSize = MediaQuery.of(context).size;

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: screenSize.width * 0.05,
        vertical: screenSize.height * 0.05,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: cs.surface,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Icon(Icons.crop_free, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Text(zh ? '选择工具' : 'Selection Tool',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: widget.cropMode == 'keep' ? Colors.green.withAlpha(40) : Colors.red.withAlpha(40),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.cropMode == 'keep' ? (zh ? '保留' : 'KEEP') : (zh ? '移除' : 'REMOVE'),
                    style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      color: widget.cropMode == 'keep' ? Colors.green : Colors.red,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ]),
            ),
            const Divider(height: 1),

            Expanded(child: LayoutBuilder(builder: (ctx, constraints) {
              final vw = widget.videoWidth.toDouble();
              final vh = widget.videoHeight.toDouble();
              final scale = math.min(constraints.maxWidth / vw, constraints.maxHeight / vh);
              final displayW = vw * scale;
              final displayH = vh * scale;
              final offsetX = (constraints.maxWidth - displayW) / 2;
              final offsetY = (constraints.maxHeight - displayH) / 2;
              final imgOffset = Offset(offsetX, offsetY);

              return GestureDetector(
                onPanStart: (d) {
                  final local = d.localPosition;
                  final hit = _hitTestEdge(local, scale, imgOffset);
                  if (hit != null) {
                    _activeRegionIdx = hit.$1;
                    _activeEdge = hit.$2;
                    if (_activeEdge != 'move') _pushUndo();
                  } else {
                    _activeRegionIdx = null;
                    _activeEdge = null;
                    _pushUndo();
                  }
                  _dragStart = local;
                  if (_activeRegionIdx == null) {
                    setState(() => _currentDrag = Rect.fromLTWH(local.dx, local.dy, 0, 0));
                  }
                },
                onPanUpdate: (d) {
                  if (_dragStart == null) return;
                  final local = d.localPosition;
                  final clampedX = local.dx.clamp(offsetX, offsetX + displayW);
                  final clampedY = local.dy.clamp(offsetY, offsetY + displayH);
                  final clamped = Offset(clampedX, clampedY);

                  setState(() {
                    if (_activeRegionIdx != null) {
                      final idx = _activeRegionIdx!;
                      final edge = _activeEdge!;
                      var r = _toDisplay(_regions[idx], scale, imgOffset);

                      if (edge == 'move') {
                        final dx = d.delta.dx;
                        final dy = d.delta.dy;
                        var newLeft = r.left + dx;
                        var newTop = r.top + dy;
                        newLeft = newLeft.clamp(offsetX, offsetX + displayW - r.width);
                        newTop = newTop.clamp(offsetY, offsetY + displayH - r.height);
                        r = Rect.fromLTWH(newLeft, newTop, r.width, r.height);
                      } else {
                        var left = r.left, top = r.top, right = r.right, bottom = r.bottom;
                        if (edge.contains('l') || edge == 'left') left = clampedX;
                        if (edge.contains('r') || edge == 'right') right = clampedX;
                        if (edge.contains('t') || edge == 'top') top = clampedY;
                        if (edge.contains('b') || edge == 'bottom') bottom = clampedY;
                        r = Rect.fromLTRB(
                          math.min(left, right), math.min(top, bottom),
                          math.max(left, right), math.max(top, bottom),
                        );
                      }
                      _regions[idx] = _toVideo(r, scale, imgOffset);
                    } else if (_currentDrag != null) {
                      _currentDrag = Rect.fromPoints(
                        Offset(_dragStart!.dx.clamp(offsetX, offsetX + displayW),
                               _dragStart!.dy.clamp(offsetY, offsetY + displayH)),
                        clamped,
                      );
                    }
                  });
                },
                onPanEnd: (_) {
                  if (_currentDrag != null && _currentDrag!.width > 5 && _currentDrag!.height > 5) {
                    final r = _toVideo(_currentDrag!, scale, imgOffset);
                    if (r.width > 2 && r.height > 2) {
                      _regions.add(r);
                    }
                  }
                  _currentDrag = null;
                  _dragStart = null;
                  _activeRegionIdx = null;
                  _activeEdge = null;
                  setState(() {});
                },
                child: Stack(children: [
                  Positioned.fill(child: Container(color: Colors.black)),
                  Positioned(
                    left: offsetX, top: offsetY,
                    width: displayW, height: displayH,
                    child: Image.file(File(widget.framePath), fit: BoxFit.fill),
                  ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RegionOverlayPainter(
                        regions: _regions.map((r) => _toDisplay(r, scale, imgOffset)).toList(),
                        currentDrag: _currentDrag,
                        isRemoveMode: widget.cropMode == 'remove',
                        imgRect: Rect.fromLTWH(offsetX, offsetY, displayW, displayH),
                      ),
                    ),
                  ),
                ]),
              );
            })),

            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                TextButton.icon(
                  onPressed: _undoStack.isNotEmpty ? _undo : null,
                  icon: const Icon(Icons.undo, size: 18),
                  label: Text(zh ? '撤销' : 'Undo'),
                ),
                const SizedBox(width: 12),
                Text('${_regions.length} ${zh ? "个选区" : "regions"}',
                    style: TextStyle(fontSize: 12, color: cs.outline)),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_regions),
                  child: Text(zh ? '保存' : 'Save'),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _RegionOverlayPainter extends CustomPainter {
  final List<Rect> regions;
  final Rect? currentDrag;
  final bool isRemoveMode;
  final Rect imgRect;

  _RegionOverlayPainter({
    required this.regions,
    this.currentDrag,
    required this.isRemoveMode,
    required this.imgRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final allRects = [...regions, if (currentDrag != null) currentDrag!];
    final accentColor = isRemoveMode ? Colors.red : Colors.green;

    if (!isRemoveMode && allRects.isNotEmpty) {
      final dimPaint = Paint()..color = Colors.black.withAlpha(140);
      canvas.drawRect(imgRect, dimPaint);
      final clearPaint = Paint()..blendMode = BlendMode.clear;
      canvas.saveLayer(imgRect, Paint());
      canvas.drawRect(imgRect, dimPaint);
      for (final r in allRects) {
        canvas.drawRect(r, clearPaint);
      }
      canvas.restore();
    }

    final fillPaint = Paint()..color = accentColor.withAlpha(isRemoveMode ? 50 : 30);
    final borderPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final handlePaint = Paint()..color = accentColor;

    for (final r in allRects) {
      canvas.drawRect(r, fillPaint);
      canvas.drawRect(r, borderPaint);

      const hs = 5.0;
      final handles = [
        r.topLeft, r.topRight, r.bottomLeft, r.bottomRight,
        Offset(r.center.dx, r.top), Offset(r.center.dx, r.bottom),
        Offset(r.left, r.center.dy), Offset(r.right, r.center.dy),
      ];
      for (final h in handles) {
        canvas.drawCircle(h, hs, handlePaint);
      }

      final tp = TextPainter(
        text: TextSpan(
          text: '${r.width.round()}x${r.height.round()}',
          style: TextStyle(color: Colors.white, fontSize: 10, background: Paint()..color = Colors.black54),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(r.left + 4, r.top + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _RegionOverlayPainter old) => true;
}
