import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'image_crop_dialog.dart';

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
  // 图片是否存在（_loadImageSize 异步探测，避免 build 中同步 File.existsSync）
  bool _imageExists = false;

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

  @override
  void didUpdateWidget(covariant ImageCropStepEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 上游换图后旧尺寸/预览会与新图错位，需重新加载
    if (oldWidget.sourceImagePath != widget.sourceImagePath) {
      _imageSize = null;
      _imageExists = false;
      _loadImageSize();
    }
  }

  /// 读取源图宽高 —— **不做像素解码**。
  ///
  /// 旧实现 `file.readAsBytes()` + `decodeImageFromList(bytes)`：
  /// 1) 把整张图按**原始分辨率**解码成 RGBA（24MP 照片 ≈ 96MB），却只取
  ///    width/height 两个数字；
  /// 2) 返回的 `ui.Image` 从不 `.dispose()`（它也不在 ImageCache 管辖内，
  ///    48MB 上限对它无效），只能等 GC 终结器兜底。
  /// 结果是「打开一次图片裁剪节点 = 白吃一次百兆级峰值」——正是用户反馈的
  /// 「打开/切换特效时内存飙升」。
  ///
  /// 现在改用 [ui.ImageDescriptor.encoded] 只解析编码流头部拿尺寸，开销 KB 级，
  /// 无离屏位图、无待释放对象。
  Future<void> _loadImageSize() async {
    final path = widget.sourceImagePath;
    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) {
      if (mounted) setState(() => _imageExists = false);
      return;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      final bytes = await file.readAsBytes();
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width;
      final h = descriptor.height;
      if (!mounted) return;
      setState(() {
        _imageExists = true;
        _imageSize = Size(w.toDouble(), h.toDouble());
        if ((p['crop_w'] as num?)?.toInt() == 0) {
          p['crop_w'] = w;
          p['crop_h'] = h;
          _wCtrl.text = '$w';
          _hCtrl.text = '$h';
          widget.onChanged();
        }
      });
    } catch (_) {
      // 头解析失败（非图片 / 文件损坏）：与旧实现一致，按「图片不存在」处理
      if (mounted) setState(() => _imageExists = false);
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
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

  /// 打开专用裁剪窗口，确认后把返回矩形写回参数。
  ///
  /// 旧的「内嵌预览直接拖拽」方案在移动端几乎不可用：预览被钳在 ≤300 逻辑像素
  /// 高、手柄命中半径 12px，手势还要和外层滚动抢事件。裁剪交互整体挪进
  /// [showImageCropDialog]，面板内只保留只读预览 + 数字输入兜底。
  Future<void> _openCropTool() async {
    final size = _imageSize;
    final path = widget.sourceImagePath;
    if (size == null || path == null || path.isEmpty || !_imageExists) return;

    final imgW = size.width;
    final imgH = size.height;
    final cropX = (p['crop_x'] as num?)?.toDouble() ?? 0;
    final cropY = (p['crop_y'] as num?)?.toDouble() ?? 0;
    final cropW = ((p['crop_w'] as num?)?.toDouble() ?? imgW)
        .clamp(1.0, imgW);
    final cropH = ((p['crop_h'] as num?)?.toDouble() ?? imgH)
        .clamp(1.0, imgH);
    final initial = Rect.fromLTWH(
      cropX.clamp(0.0, math.max(0.0, imgW - 1)),
      cropY.clamp(0.0, math.max(0.0, imgH - 1)),
      cropW,
      cropH,
    );

    final result = await showImageCropDialog(
      context,
      imagePath: path,
      imageSize: size,
      initialRect: initial,
      isZh: widget.isZh,
    );
    if (result == null || !mounted) return;

    final imgWi = imgW.toInt();
    final imgHi = imgH.toInt();
    final x = result.left.round().clamp(0, math.max(0, imgWi - 1));
    final y = result.top.round().clamp(0, math.max(0, imgHi - 1));
    final w = result.width.round().clamp(1, math.max(1, imgWi - x));
    final h = result.height.round().clamp(1, math.max(1, imgHi - y));
    setState(() {
      p['crop_x'] = x;
      p['crop_y'] = y;
      p['crop_w'] = w;
      p['crop_h'] = h;
      _syncControllers();
    });
    widget.onChanged();
  }

  bool get _canOpenCropTool =>
      _imageSize != null && _imageExists && widget.sourceImagePath != null && widget.sourceImagePath!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(zh ? '图片裁剪' : 'Image Crop',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 8),

        _buildPreviewArea(cs, zh),
        const SizedBox(height: 8),

        // 专用裁剪窗口入口（与视频裁剪的「打开选择工具」同一交互模式）
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _canOpenCropTool ? _openCropTool : null,
            icon: const Icon(Icons.crop_free, size: 18),
            label: Text(zh ? '打开裁剪工具' : 'Open Crop Tool', style: const TextStyle(fontSize: 13)),
          ),
        ),
        // 禁用原因提示：按钮置灰时用户「点了没反应」大多是因为不知道门控条件
        // —— 明确告知缺什么（未连线图片源 / 文件不存在或无法解析）。
        if (!_canOpenCropTool)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 13, color: cs.outline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  (widget.sourceImagePath == null || widget.sourceImagePath!.isEmpty)
                      ? (zh
                          ? '「打开裁剪工具」不可用：未连接图片源（需上游为「图片」类型的开始节点）'
                          : 'Disabled: no image source connected (upstream must be an image start node)')
                      : (zh
                          ? '「打开裁剪工具」不可用：图片文件不存在或无法解析'
                          : 'Disabled: image file missing or unreadable'),
                  style: TextStyle(fontSize: 11, color: cs.outline, height: 1.35),
                ),
              ),
            ]),
          ),
        const SizedBox(height: 8),

        Text(zh ? '裁剪区域' : 'Crop Region',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
        const SizedBox(height: 8),

        Row(children: [
          Expanded(child: TextField(
            controller: _xCtrl,
            decoration: const InputDecoration(labelText: 'X'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) {
              final val = int.tryParse(v) ?? 0;
              _updateParam('crop_x', _imageSize == null ? val : val.clamp(0, math.max(0, _imageSize!.width.toInt() - 1)));
            },
          )),
          const SizedBox(width: 8),
          Expanded(child: TextField(
            controller: _yCtrl,
            decoration: const InputDecoration(labelText: 'Y'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) {
              final val = int.tryParse(v) ?? 0;
              _updateParam('crop_y', _imageSize == null ? val : val.clamp(0, math.max(0, _imageSize!.height.toInt() - 1)));
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
              _updateParam('crop_w', _imageSize == null ? val : val.clamp(0, _imageSize!.width.toInt()));
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
              _updateParam('crop_h', _imageSize == null ? val : val.clamp(0, _imageSize!.height.toInt()));
            },
          )),
        ]),
        const SizedBox(height: 8),

        if (_imageSize != null)
          Text(
            zh ? '原始尺寸: ${_imageSize!.width.toInt()} × ${_imageSize!.height.toInt()}'
               : 'Original: ${_imageSize!.width.toInt()} × ${_imageSize!.height.toInt()}',
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),

        const SizedBox(height: 8),
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
              zh ? '输入来自帧提取或其他图片源。\n点击预览或「打开裁剪工具」进入全屏裁剪，大图上拖拽框选更精准；也可在下方手动输入坐标和尺寸。'
                 : 'Input comes from frame extraction or other image sources.\nTap the preview or the button above to crop on a full-size canvas, or enter coordinates below.',
              style: TextStyle(fontSize: 11, color: cs.outline, height: 1.4),
            )),
          ]),
        ),
      ]),
    );
  }

  Widget _buildPreviewArea(ColorScheme cs, bool zh) {
    final path = widget.sourceImagePath;
    // 用异步探测的 _imageExists 代替 build 中同步 File.existsSync
    final hasImage = path != null && path.isNotEmpty && _imageExists;

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

    // 只读预览：展示当前裁剪框位置，点击直接打开专用裁剪窗口。
    // 不再内嵌拖拽手势 —— 这是移动端「裁剪框拖不动」的根源（预览太小 +
    // 与面板外层滚动手势抢事件）。
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _canOpenCropTool ? _openCropTool : null,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant.withAlpha(80)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LayoutBuilder(builder: (context, constraints) {
            return _buildPreviewImage(path, constraints.maxWidth, cs);
          }),
        ),
      ),
    );
  }

  /// 只读预览图：按当前 crop 参数画出裁剪框位置。
  Widget _buildPreviewImage(String path, double maxWidth, ColorScheme cs) {
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

    return SizedBox(
      width: effectiveW,
      height: clampedH,
      child: Stack(children: [
        Image.file(File(path), width: effectiveW, height: clampedH, fit: BoxFit.fill,
            // 按**显示**尺寸封顶解码（旧实现按源图原始分辨率解码 24MP ≈ 96MB）
            cacheWidth: (effectiveW * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 4096)),
        CustomPaint(
          size: Size(effectiveW, clampedH),
          painter: _CropOverlayPainter(displayCropRect, cs.primary),
        ),
        // 右下角提示：这是入口，不是编辑区
        Positioned(
          right: 6,
          bottom: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(110),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.crop_free, size: 12, color: Colors.white.withAlpha(230)),
              const SizedBox(width: 4),
              Text(widget.isZh ? '点击裁剪' : 'Tap to crop',
                  style: TextStyle(fontSize: 10, color: Colors.white.withAlpha(230))),
            ]),
          ),
        ),
      ]),
    );
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

    // corner handles（只读预览，仅提示位置）
    const hs = 5.0;
    final handlePaint = Paint()..color = accentColor;
    for (final pt in [cropRect.topLeft, cropRect.topRight, cropRect.bottomLeft, cropRect.bottomRight]) {
      canvas.drawCircle(pt, hs, handlePaint);
      canvas.drawCircle(pt, hs, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_CropOverlayPainter old) => old.cropRect != cropRect;
}
