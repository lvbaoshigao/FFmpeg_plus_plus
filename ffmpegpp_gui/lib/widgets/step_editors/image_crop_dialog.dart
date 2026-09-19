import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../platform/app_platform.dart';

/// 图片裁剪专用窗口。
///
/// 由 [ImageCropStepEditor] 打开。此前裁剪交互内嵌在节点参数面板里：预览被钳在
/// ≤300 逻辑像素高、手柄命中半径只有 12px、还要和面板外层的滚动手势抢事件 ——
/// 移动端几乎无法把裁剪框拖到想要的位置。整体交互挪进这个专用窗口：
/// 图像按「contain」铺满可用区域、8 个手柄命中阈值 32px、支持比例锁定 /
/// 全选 / 重置，确认后把裁剪矩形（源图像素坐标）返回给面板。
Future<Rect?> showImageCropDialog(
  BuildContext context, {
  required String imagePath,
  required Size imageSize,
  required Rect initialRect,
  required bool isZh,
}) {
  final child = _ImageCropDialog(
    imagePath: imagePath,
    imageSize: imageSize,
    initialRect: initialRect,
    isZh: isZh,
  );
  if (isMobilePlatform) {
    // 移动端：全高 bottom sheet（顶部留给状态栏，useSafeArea 处理）
    return showModalBottomSheet<Rect>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height - MediaQuery.paddingOf(context).top,
        child: child,
      ),
    );
  }
  // 桌面端：居中大对话框
  return showDialog<Rect>(
    context: context,
    barrierDismissible: false,
    builder: (_) {
      final size = MediaQuery.sizeOf(context);
      return Center(
        child: SizedBox(
          width: math.min(760.0, size.width * 0.85),
          height: size.height * 0.85,
          child: child,
        ),
      );
    },
  );
}

class _ImageCropDialog extends StatefulWidget {
  final String imagePath;
  final Size imageSize;
  final Rect initialRect;
  final bool isZh;

  const _ImageCropDialog({
    required this.imagePath,
    required this.imageSize,
    required this.initialRect,
    required this.isZh,
  });

  @override
  State<_ImageCropDialog> createState() => _ImageCropDialogState();
}

class _ImageCropDialogState extends State<_ImageCropDialog> {
  /// 裁剪矩形，**源图像素坐标**（double；提交时才取整）。
  late Rect _rect;

  /// 当前锁定的宽高比；null = 自由。
  double? _ratio;
  int? _ratioIndex;

  // 拖拽状态（显示坐标）
  Offset? _dragStart;
  Rect? _dragStartRect;
  Rect? _rectAtPanStart;
  String? _moving; // 'tl'/'tr'/'bl'/'br'/'t'/'b'/'l'/'r'/'move'，null = 新建选区

  double get _imgW => widget.imageSize.width;
  double get _imgH => widget.imageSize.height;

  @override
  void initState() {
    super.initState();
    _rect = widget.initialRect;
  }

  // ---------- 坐标换算 ----------

  Rect _toDisplay(Rect imageRect, double scale, Offset off) => Rect.fromLTRB(
        imageRect.left * scale + off.dx,
        imageRect.top * scale + off.dy,
        imageRect.right * scale + off.dx,
        imageRect.bottom * scale + off.dy,
      );

  Rect _toImage(Rect displayRect, double scale, Offset off) => Rect.fromLTRB(
        (displayRect.left - off.dx) / scale,
        (displayRect.top - off.dy) / scale,
        (displayRect.right - off.dx) / scale,
        (displayRect.bottom - off.dy) / scale,
      );

  // ---------- 比例约束 ----------

  /// 把 [raw]（图像坐标、已归一化）调整为当前 [_ratio]，锚定在**没有移动**的边。
  /// [moving] 里含 'l' 表示左边缘在动（锚右边缘），以此类推；两边都不含时按中心锚。
  Rect _constrainRatio(Rect raw, String moving) {
    final ratio = _ratio;
    if (ratio == null) return raw;
    double w = raw.width;
    double h = raw.height;
    // 图比比例要求的还小：收缩到图内（保持比例）
    if (w / h > ratio) {
      w = h * ratio;
    } else {
      h = w / ratio;
    }
    if (w > _imgW) {
      w = _imgW;
      h = w / ratio;
    }
    if (h > _imgH) {
      h = _imgH;
      w = h * ratio;
    }
    double left;
    if (moving.contains('l')) {
      left = raw.right - w;
    } else if (moving.contains('r')) {
      left = raw.left;
    } else {
      left = raw.center.dx - w / 2;
    }
    double top;
    if (moving.contains('t')) {
      top = raw.bottom - h;
    } else if (moving.contains('b')) {
      top = raw.top;
    } else {
      top = raw.center.dy - h / 2;
    }
    left = left.clamp(0.0, math.max(0.0, _imgW - w));
    top = top.clamp(0.0, math.max(0.0, _imgH - h));
    return Rect.fromLTWH(left, top, w, h);
  }

  /// 点比例芯片时立即把当前矩形居中变形到该比例。
  Rect _fitRectToRatio(Rect r, double ratio) {
    double w = r.width;
    double h = r.height;
    if (w / h > ratio) {
      w = h * ratio;
    } else {
      h = w / ratio;
    }
    if (w > _imgW) {
      w = _imgW;
      h = w / ratio;
    }
    if (h > _imgH) {
      h = _imgH;
      w = h * ratio;
    }
    final cx = r.center.dx.clamp(w / 2, math.max(w / 2, _imgW - w / 2));
    final cy = r.center.dy.clamp(h / 2, math.max(h / 2, _imgH - h / 2));
    return Rect.fromLTWH(cx - w / 2, cy - h / 2, w, h);
  }

  // ---------- 手势 ----------

  /// 手柄命中测试（显示坐标）。角 > 边 > 内部；都未命中返回 null（新建选区）。
  String? _hitTest(Offset local, Rect dr) {
    const cornerT = 32.0;
    const edgeT = 26.0;
    if ((local - dr.topLeft).distance < cornerT) return 'tl';
    if ((local - dr.topRight).distance < cornerT) return 'tr';
    if ((local - dr.bottomLeft).distance < cornerT) return 'bl';
    if ((local - dr.bottomRight).distance < cornerT) return 'br';
    final inX = local.dx >= dr.left && local.dx <= dr.right;
    final inY = local.dy >= dr.top && local.dy <= dr.bottom;
    if (inX && (local.dy - dr.top).abs() < edgeT) return 't';
    if (inX && (local.dy - dr.bottom).abs() < edgeT) return 'b';
    if (inY && (local.dx - dr.left).abs() < edgeT) return 'l';
    if (inY && (local.dx - dr.right).abs() < edgeT) return 'r';
    if (dr.contains(local)) return 'move';
    return null;
  }

  void _onPanStart(DragStartDetails d, double scale, Offset off, Size disp) {
    final local = d.localPosition;
    final dr = _toDisplay(_rect, scale, off);
    final hit = _hitTest(local, dr);
    _moving = hit;
    // 起点钳进图像显示区：新建选区从图外起拖时不会生成越界矩形
    _dragStart = Offset(
      local.dx.clamp(off.dx, off.dx + disp.width),
      local.dy.clamp(off.dy, off.dy + disp.height),
    );
    _dragStartRect = dr;
    _rectAtPanStart = _rect;
    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails d, double scale, Offset off, Size disp) {
    if (_dragStart == null || _dragStartRect == null) return;
    final imgMin = off;
    final imgMax = Offset(off.dx + disp.width, off.dy + disp.height);
    // 显示坐标内钳制的指针位置（手柄/新建用）
    final clamped = Offset(
      d.localPosition.dx.clamp(imgMin.dx, imgMax.dx),
      d.localPosition.dy.clamp(imgMin.dy, imgMax.dy),
    );
    final r0 = _dragStartRect!;
    final mv = _moving;
    Rect dispRect;

    if (mv == 'move') {
      // 自拖拽起点起的**绝对位移**（触摸多事件同帧时 d.delta 累积会丢位移）
      final dx = d.localPosition.dx - _dragStart!.dx;
      final dy = d.localPosition.dy - _dragStart!.dy;
      final left = (r0.left + dx).clamp(imgMin.dx, math.max(imgMin.dx, imgMax.dx - r0.width)).toDouble();
      final top = (r0.top + dy).clamp(imgMin.dy, math.max(imgMin.dy, imgMax.dy - r0.height)).toDouble();
      dispRect = Rect.fromLTWH(left, top, r0.width, r0.height);
    } else if (mv != null) {
      // 手柄改尺寸：被拖边取当前指针位置，其余边沿用起始快照
      var left = r0.left;
      var top = r0.top;
      var right = r0.right;
      var bottom = r0.bottom;
      if (mv.contains('l')) left = clamped.dx;
      if (mv.contains('r')) right = clamped.dx;
      if (mv.contains('t')) top = clamped.dy;
      if (mv.contains('b')) bottom = clamped.dy;
      dispRect = Rect.fromLTRB(
        math.min(left, right), math.min(top, bottom),
        math.max(left, right), math.max(top, bottom),
      );
    } else {
      // 新建选区：从起点到当前点
      dispRect = Rect.fromPoints(_dragStart!, clamped);
    }
    // 归一化后转图像坐标，再做比例约束
    final normalized = Rect.fromLTRB(
      math.min(dispRect.left, dispRect.right),
      math.min(dispRect.top, dispRect.bottom),
      math.max(dispRect.left, dispRect.right),
      math.max(dispRect.top, dispRect.bottom),
    );
    var img = _toImage(normalized, scale, off);
    if (_ratio != null) {
      final moving = mv ?? ((clamped.dx >= _dragStart!.dx ? 'r' : 'l') + (clamped.dy >= _dragStart!.dy ? 'b' : 't'));
      img = _constrainRatio(img, moving);
    }
    // 钳回图内
    img = Rect.fromLTRB(
      img.left.clamp(0.0, _imgW),
      img.top.clamp(0.0, _imgH),
      img.right.clamp(0.0, _imgW),
      img.bottom.clamp(0.0, _imgH),
    );
    setState(() => _rect = img);
  }

  void _onPanEnd(DragEndDetails d) {
    // 空白处轻点（几乎无位移）会被判成「新建选区」，保留原矩形
    if (_moving == null && _rect.width < 4 && _rect.height < 4) {
      _rect = _rectAtPanStart ?? _rect;
    }
    _dragStart = null;
    _dragStartRect = null;
    _rectAtPanStart = null;
    _moving = null;
    setState(() {});
  }

  // ---------- 动作 ----------

  void _setRatio(int index, double? ratio) {
    setState(() {
      _ratioIndex = index;
      _ratio = ratio;
      if (ratio != null) _rect = _fitRectToRatio(_rect, ratio);
    });
  }

  void _selectAll() {
    setState(() {
      _ratioIndex = null;
      _ratio = null;
      _rect = Rect.fromLTWH(0, 0, _imgW, _imgH);
    });
  }

  void _reset() {
    setState(() {
      _ratioIndex = null;
      _ratio = null;
      _rect = widget.initialRect;
    });
  }

  /// 提交：取整 + 最小尺寸钳制（保证 w/h ≥ 1 且不越界）
  Rect _commitRect() {
    int x = _rect.left.round().clamp(0, math.max(0, _imgW.toInt() - 1));
    int y = _rect.top.round().clamp(0, math.max(0, _imgH.toInt() - 1));
    int w = _rect.width.round().clamp(1, math.max(1, _imgW.toInt() - x));
    int h = _rect.height.round().clamp(1, math.max(1, _imgH.toInt() - y));
    return Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final mobile = isMobilePlatform;

    return Material(
      color: cs.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(mobile ? 16 : 14)),
      child: Column(children: [
        // 标题栏
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: zh ? '取消' : 'Cancel',
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Text(zh ? '裁剪图片' : 'Crop Image',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ),
            const SizedBox(width: 48),
          ]),
        ),
        // 裁剪画布
        Expanded(
          child: Container(
            color: Colors.black,
            child: LayoutBuilder(builder: (ctx, constraints) {
              final scale = math.min(constraints.maxWidth / _imgW, constraints.maxHeight / _imgH);
              final dispW = _imgW * scale;
              final dispH = _imgH * scale;
              final off = Offset(
                (constraints.maxWidth - dispW) / 2,
                (constraints.maxHeight - dispH) / 2,
              );
              final dispRect = _toDisplay(_rect, scale, off);
              final dpr = MediaQuery.devicePixelRatioOf(ctx);

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => _onPanStart(d, scale, off, Size(dispW, dispH)),
                onPanUpdate: (d) => _onPanUpdate(d, scale, off, Size(dispW, dispH)),
                onPanEnd: _onPanEnd,
                onPanCancel: () {
                  if (_rectAtPanStart != null) _rect = _rectAtPanStart!;
                  _dragStart = null;
                  _dragStartRect = null;
                  _rectAtPanStart = null;
                  _moving = null;
                  setState(() {});
                },
                child: Stack(children: [
                  Positioned(
                    left: off.dx,
                    top: off.dy,
                    width: dispW,
                    height: dispH,
                    // 按**显示**尺寸封顶解码（专用窗口里最大一屏，仍不该按原图
                    // 原始分辨率解码 24MP 照片）
                    child: Image.file(File(widget.imagePath),
                        fit: BoxFit.fill,
                        cacheWidth: (dispW * dpr).round().clamp(1, 4096)),
                  ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _CropCanvasPainter(
                        cropRect: dispRect,
                        accent: cs.primary,
                        label: '${_rect.width.round()} × ${_rect.height.round()}',
                      ),
                    ),
                  ),
                ]),
              );
            }),
          ),
        ),
        // 比例芯片
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _ratioChip(0, null, zh ? '自由' : 'Free'),
                    _ratioChip(1, 1.0, '1:1'),
                    _ratioChip(2, 4 / 3, '4:3'),
                    _ratioChip(3, 3 / 4, '3:4'),
                    _ratioChip(4, 16 / 9, '16:9'),
                    _ratioChip(5, 9 / 16, '9:16'),
                    _ratioChip(6, _imgW / _imgH, zh ? '原始' : 'Original'),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                OutlinedButton.icon(
                  onPressed: _selectAll,
                  icon: const Icon(Icons.select_all, size: 18),
                  label: Text(zh ? '全选' : 'All', style: const TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: Text(zh ? '重置' : 'Reset', style: const TextStyle(fontSize: 13)),
                ),
                const Spacer(),
                const Spacer(),
              ]),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(_commitRect()),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(zh ? '确定裁剪' : 'Apply Crop', style: const TextStyle(fontSize: 14)),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _ratioChip(int index, double? ratio, String label) {
    final selected = _ratioIndex == index;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _setRatio(index, ratio),
      ),
    );
  }
}

/// 裁剪画布叠加层：暗化选区外、边框、8 个手柄、三分线、尺寸标签。
class _CropCanvasPainter extends CustomPainter {
  final Rect cropRect;
  final Color accent;
  final String label;

  _CropCanvasPainter({
    required this.cropRect,
    required this.accent,
    required this.label,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = cropRect;

    // 选区外暗化
    final dim = Paint()..color = Colors.black.withAlpha(130);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, r.top), dim);
    canvas.drawRect(Rect.fromLTRB(0, r.bottom, size.width, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(0, r.top, r.left, r.bottom), dim);
    canvas.drawRect(Rect.fromLTRB(r.right, r.top, size.width, r.bottom), dim);

    // 三分线
    final third = Paint()..color = Colors.white.withAlpha(70)..strokeWidth = 0.8;
    for (var i = 1; i <= 2; i++) {
      canvas.drawLine(Offset(r.left + r.width / 3 * i, r.top),
          Offset(r.left + r.width / 3 * i, r.bottom), third);
      canvas.drawLine(Offset(r.left, r.top + r.height / 3 * i),
          Offset(r.right, r.top + r.height / 3 * i), third);
    }

    // 边框
    canvas.drawRect(r, Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);

    // 手柄：4 角圆点 + 4 边短条（视觉提示可拖边）
    final fill = Paint()..color = accent;
    const cr = 8.0;
    for (final pt in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(pt, cr, fill);
      canvas.drawCircle(pt, cr, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    }
    const edgeLen = 22.0;
    const edgeW = 4.0;
    final edgePaint = Paint()..color = accent;
    void bar(Offset c, bool horizontal) {
      final rect = horizontal
          ? Rect.fromCenter(center: c, width: edgeLen, height: edgeW)
          : Rect.fromCenter(center: c, width: edgeW, height: edgeLen);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)), edgePaint);
    }

    bar(Offset(r.center.dx, r.top), true);
    bar(Offset(r.center.dx, r.bottom), true);
    bar(Offset(r.left, r.center.dy), false);
    bar(Offset(r.right, r.center.dy), false);

    // 尺寸标签（矩形左上角外，越界则放矩形内）
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          background: Paint()..color = Colors.black54,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var lx = r.left + 4;
    var ly = r.top - tp.height - 6;
    if (ly < 0) ly = r.top + 6;
    if (lx + tp.width > size.width) lx = size.width - tp.width - 4;
    tp.paint(canvas, Offset(lx, ly));
  }

  @override
  bool shouldRepaint(_CropCanvasPainter old) =>
      old.cropRect != cropRect || old.accent != accent || old.label != label;
}
