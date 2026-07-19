import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ImageCropStepEditor extends StatefulWidget {
  final Map<String, dynamic> params;
  final VoidCallback onChanged;
  final bool isZh;
  final String? sourceImagePath;

  const ImageCropStepEditor({
    super.key,
    required this.params,
    required this.onChanged,
    this.isZh = true,
    this.sourceImagePath,
  });

  @override
  State<ImageCropStepEditor> createState() => _ImageCropStepEditorState();
}

class _ImageCropStepEditorState extends State<ImageCropStepEditor> {
  Map<String, dynamic> get p => widget.params;
  late TextEditingController _xCtrl, _yCtrl, _wCtrl, _hCtrl;

  Size? _imageSize;

  Offset? _dragStart;
  Rect? _cropRect;
  String? _activeHandle;

  @override
  void initState() {
    super.initState();
    p.putIfAbsent('crop_x', () => 0);
    p.putIfAbsent('crop_y', () => 0);
    p.putIfAbsent('crop_w', () => 0);
    p.putIfAbsent('crop_h', () => 0);
    _xCtrl = TextEditingController(text: '${(p['crop_x'] as num?)?.toInt() ?? 0}');
    _yCtrl = TextEditingController(text: '${(p['crop_y'] as num?)?.toInt() ?? 0}');
    _wCtrl = TextEditingController(text: '${(p['crop_w'] as num?)?.toInt() ?? 0}');
    _hCtrl = TextEditingController(text: '${(p['crop_h'] as num?)?.toInt() ?? 0}');
    _loadImageSize();
  }

  @override
  void dispose() {
    _xCtrl.dispose();
    _yCtrl.dispose();
    _wCtrl.dispose();
    _hCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadImageSize() async {
    final path = widget.sourceImagePath;
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final bytes = await file.readAsBytes();
      final decoded = await decodeImageFromList(bytes);
      if (mounted) {
        setState(() {
          _imageSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
          if ((p['crop_w'] as num?)?.toInt() == 0 && _imageSize != null) {
            p['crop_w'] = _imageSize!.width.toInt();
            p['crop_h'] = _imageSize!.height.toInt();
            _wCtrl.text = '${_imageSize!.width.toInt()}';
            _hCtrl.text = '${_imageSize!.height.toInt()}';
            widget.onChanged();
          }
        });
      }
    } catch (_) {}
  }

  void _updateParam(String key, int value) {
    setState(() => p[key] = value);
    widget.onChanged();
  }

  void _syncControllers() {
    _xCtrl.text = '${(p['crop_x'] as num?)?.toInt() ?? 0}';
    _yCtrl.text = '${(p['crop_y'] as num?)?.toInt() ?? 0}';
    _wCtrl.text = '${(p['crop_w'] as num?)?.toInt() ?? 0}';
    _hCtrl.text = '${(p['crop_h'] as num?)?.toInt() ?? 0}';
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '图片裁剪' : 'Image Crop',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 12),

        _buildPreviewArea(cs, zh),
        const SizedBox(height: 16),

        Text(zh ? '裁剪区域' : 'Crop Region',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 8),

        Row(children: [
          Expanded(child: TextField(
            controller: _xCtrl,
            decoration: InputDecoration(labelText: 'X'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) {
              final val = int.tryParse(v) ?? 0;
              _updateParam('crop_x', val);
            },
          )),
          const SizedBox(width: 8),
          Expanded(child: TextField(
            controller: _yCtrl,
            decoration: InputDecoration(labelText: 'Y'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) {
              final val = int.tryParse(v) ?? 0;
              _updateParam('crop_y', val);
            },
          )),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(
            controller: _wCtrl,
            decoration: InputDecoration(labelText: zh ? '宽度' : 'Width'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) {
              final val = int.tryParse(v) ?? 0;
              _updateParam('crop_w', val);
            },
          )),
          const SizedBox(width: 8),
          Expanded(child: TextField(
            controller: _hCtrl,
            decoration: InputDecoration(labelText: zh ? '高度' : 'Height'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) {
              final val = int.tryParse(v) ?? 0;
              _updateParam('crop_h', val);
            },
          )),
        ]),
        const SizedBox(height: 12),

        if (_imageSize != null)
          Text(
            zh ? '原始尺寸: ${_imageSize!.width.toInt()} × ${_imageSize!.height.toInt()}'
               : 'Original: ${_imageSize!.width.toInt()} × ${_imageSize!.height.toInt()}',
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),

        const SizedBox(height: 16),
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
              zh ? '输入来自帧提取或其他图片源。\n在预览区域拖拽选择裁剪范围，或在下方手动输入坐标和尺寸。'
                 : 'Input comes from frame extraction or other image sources.\nDrag on the preview to select crop area, or enter coordinates below.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }

  Widget _buildPreviewArea(ColorScheme cs, bool zh) {
    final path = widget.sourceImagePath;
    final hasImage = path != null && path.isNotEmpty && File(path).existsSync();

    if (!hasImage) {
      return Container(
        width: double.infinity,
        height: 160,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withAlpha(80),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant.withAlpha(80)),
        ),
        child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_not_supported_outlined, size: 36, color: cs.outline.withAlpha(120)),
          const SizedBox(height: 8),
          Text(zh ? '暂无预览' : 'No Preview',
              style: TextStyle(fontSize: 12, color: cs.outline)),
          const SizedBox(height: 4),
          Text(zh ? '请先连接图片源节点' : 'Connect an image source node first',
              style: TextStyle(fontSize: 10, color: cs.outline.withAlpha(160))),
        ])),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(builder: (context, constraints) {
          return _buildCroppableImage(path, constraints.maxWidth, cs);
        }),
      ),
    );
  }

  Widget _buildCroppableImage(String path, double maxWidth, ColorScheme cs) {
    if (_imageSize == null) {
      return SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
      );
    }

    final imgW = _imageSize!.width;
    final imgH = _imageSize!.height;
    final scale = maxWidth / imgW;
    final displayH = imgH * scale;
    final clampedH = math.min(displayH, 300.0);
    final effectiveScale = clampedH < displayH ? (clampedH / imgH) : scale;
    final effectiveW = imgW * effectiveScale;

    final cropX = (p['crop_x'] as num?)?.toDouble() ?? 0;
    final cropY = (p['crop_y'] as num?)?.toDouble() ?? 0;
    final cropW = (p['crop_w'] as num?)?.toDouble() ?? imgW;
    final cropH = (p['crop_h'] as num?)?.toDouble() ?? imgH;

    final displayCropRect = Rect.fromLTWH(
      cropX * effectiveScale,
      cropY * effectiveScale,
      cropW * effectiveScale,
      cropH * effectiveScale,
    );

    return GestureDetector(
      onPanStart: (d) {
        final local = d.localPosition;
        const handleSize = 12.0;
        final r = displayCropRect;

        if ((local - r.topLeft).distance < handleSize) { _activeHandle = 'tl'; }
        else if ((local - r.topRight).distance < handleSize) { _activeHandle = 'tr'; }
        else if ((local - r.bottomLeft).distance < handleSize) { _activeHandle = 'bl'; }
        else if ((local - r.bottomRight).distance < handleSize) { _activeHandle = 'br'; }
        else if (r.contains(local)) { _activeHandle = 'move'; }
        else { _activeHandle = 'new'; }

        _dragStart = local;
        if (_activeHandle == 'new') {
          setState(() {
            _cropRect = Rect.fromLTWH(local.dx, local.dy, 0, 0);
          });
        }
      },
      onPanUpdate: (d) {
        if (_dragStart == null) return;
        final local = d.localPosition;
        final clampedLocal = Offset(
          local.dx.clamp(0, effectiveW),
          local.dy.clamp(0, clampedH),
        );

        setState(() {
          if (_activeHandle == 'new') {
            _cropRect = Rect.fromPoints(_dragStart!, clampedLocal);
            _applyCropRect(effectiveScale, imgW, imgH);
          } else if (_activeHandle == 'move') {
            final dx = d.delta.dx;
            final dy = d.delta.dy;
            var newX = cropX + dx / effectiveScale;
            var newY = cropY + dy / effectiveScale;
            newX = newX.clamp(0, imgW - cropW);
            newY = newY.clamp(0, imgH - cropH);
            p['crop_x'] = newX.round();
            p['crop_y'] = newY.round();
            _syncControllers();
            widget.onChanged();
          } else {
            var left = displayCropRect.left;
            var top = displayCropRect.top;
            var right = displayCropRect.right;
            var bottom = displayCropRect.bottom;

            if (_activeHandle!.contains('l')) left = clampedLocal.dx;
            if (_activeHandle!.contains('r')) right = clampedLocal.dx;
            if (_activeHandle!.contains('t')) top = clampedLocal.dy;
            if (_activeHandle!.contains('b')) bottom = clampedLocal.dy;

            _cropRect = Rect.fromLTRB(
              math.min(left, right), math.min(top, bottom),
              math.max(left, right), math.max(top, bottom),
            );
            _applyCropRect(effectiveScale, imgW, imgH);
          }
        });
      },
      onPanEnd: (_) {
        _dragStart = null;
        _activeHandle = null;
      },
      child: SizedBox(
        width: effectiveW,
        height: clampedH,
        child: Stack(children: [
          Image.file(File(path), width: effectiveW, height: clampedH, fit: BoxFit.fill),
          // dim area outside crop
          CustomPaint(
            size: Size(effectiveW, clampedH),
            painter: _CropOverlayPainter(displayCropRect, cs.primary),
          ),
        ]),
      ),
    );
  }

  void _applyCropRect(double scale, double imgW, double imgH) {
    if (_cropRect == null) return;
    var x = (_cropRect!.left / scale).round();
    var y = (_cropRect!.top / scale).round();
    var w = (_cropRect!.width / scale).round();
    var h = (_cropRect!.height / scale).round();

    x = x.clamp(0, imgW.toInt());
    y = y.clamp(0, imgH.toInt());
    w = w.clamp(1, (imgW - x).toInt());
    h = h.clamp(1, (imgH - y).toInt());

    p['crop_x'] = x;
    p['crop_y'] = y;
    p['crop_w'] = w;
    p['crop_h'] = h;
    _syncControllers();
    widget.onChanged();
  }
}

class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;
  final Color accentColor;

  _CropOverlayPainter(this.cropRect, this.accentColor);

  @override
  void paint(Canvas canvas, Size size) {
    final dimPaint = Paint()..color = Colors.black.withAlpha(120);

    // top
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, cropRect.top), dimPaint);
    // bottom
    canvas.drawRect(Rect.fromLTRB(0, cropRect.bottom, size.width, size.height), dimPaint);
    // left
    canvas.drawRect(Rect.fromLTRB(0, cropRect.top, cropRect.left, cropRect.bottom), dimPaint);
    // right
    canvas.drawRect(Rect.fromLTRB(cropRect.right, cropRect.top, size.width, cropRect.bottom), dimPaint);

    // crop border
    final borderPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(cropRect, borderPaint);

    // handles
    const hs = 6.0;
    final handlePaint = Paint()..color = accentColor;
    for (final pt in [cropRect.topLeft, cropRect.topRight, cropRect.bottomLeft, cropRect.bottomRight]) {
      canvas.drawCircle(pt, hs, handlePaint);
      canvas.drawCircle(pt, hs, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
    }

    // rule of thirds
    final thirdPaint = Paint()..color = Colors.white.withAlpha(60)..strokeWidth = 0.5;
    final w3 = cropRect.width / 3;
    final h3 = cropRect.height / 3;
    for (var i = 1; i <= 2; i++) {
      canvas.drawLine(
        Offset(cropRect.left + w3 * i, cropRect.top),
        Offset(cropRect.left + w3 * i, cropRect.bottom), thirdPaint);
      canvas.drawLine(
        Offset(cropRect.left, cropRect.top + h3 * i),
        Offset(cropRect.right, cropRect.top + h3 * i), thirdPaint);
    }
  }

  @override
  bool shouldRepaint(_CropOverlayPainter old) => old.cropRect != cropRect;
}
