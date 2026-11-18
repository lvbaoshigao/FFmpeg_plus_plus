import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../platform/app_platform.dart';
import '../../theme/app_control_size.dart';

/// 图片裁剪专用窗口。
///
/// 由 [ImageCropStepEditor] 打开。此前裁剪交互内嵌在节点参数面板里：预览被钳在
/// ≤300 逻辑像素高、手柄命中半径只有 12px、还要和面板外层的滚动手势抢事件 ——
/// 移动端几乎无法把裁剪框拖到想要的位置。整体交互挪进这个专用窗口：
/// 图像按「contain」铺满可用区域、手柄命中阈值区分「触摸 / 鼠标」、
/// 支持比例锁定 / 全选 / 重置，确认后把裁剪矩形（源图像素坐标）返回给面板。
///
/// 布局按**宽高比**分流（横屏 / 竖屏），而不是按平台分流：
/// - 竖屏（高 > 宽）：标题栏 + 全宽画布 + 底部紧凑工具条（芯片 / 操作 / 确定三行并两行）；
/// - 横屏（宽 ≥ 高）：左画布 + 右侧固定宽度工具栏。
///
/// 旧实现只有「竖屏那一种」版式，且移动端走全高 bottom sheet —— 横屏时屏幕高度
/// 只剩 360~420dp，底部「比例芯片 + 全选/重置 + 确定」三行吃掉约 140dp，画布被压成
/// 一条横缝，图片缩到几乎看不清裁剪框边缘（用户反馈的「横屏裁剪框不好用」）。
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
    // 移动端统一全屏：横竖屏共用同一套外壳，内部再按宽高比分流。
    // 不再用 bottom sheet —— 它的「底部抽屉」语义（顶部圆角、高度从底部算起、
    // 拖拽关闭）在横屏下既浪费高度又容易误触关闭。
    return showGeneralDialog<Rect>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 160),
      // SizedBox.expand：Overlay 给 route 的约束不保证是 tight，裸 child 会
      // 收缩到内容尺寸（Row 撑宽但 Column 撑不高），全屏外壳必须显式铺满
      pageBuilder: (_, _, _) => SizedBox.expand(child: child),
      transitionBuilder: (_, animation, _, page) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: page,
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
          width: math.min(860.0, size.width * 0.86),
          height: size.height * 0.86,
          child: child,
        ),
      );
    },
  );
}

/// 手柄的命中与视觉规格。
class _HandleSpec {
  const _HandleSpec({
    required this.cornerHit,
    required this.edgeHit,
    required this.armLen,
    required this.armW,
    required this.barLen,
    required this.barW,
  });

  /// 角命中半径（显示坐标）。
  final double cornerHit;

  /// 边命中带宽（显示坐标）。
  final double edgeHit;

  /// 角 L 形臂长。
  final double armLen;

  /// 角 L 形线宽。
  final double armW;

  /// 边短条长 / 宽。
  final double barLen;
  final double barW;

  /// 桌面（鼠标）：命中区可以小一些，视觉更利落。
  static const desktop = _HandleSpec(
    cornerHit: 30,
    edgeHit: 24,
    armLen: 20,
    armW: 3,
    barLen: 22,
    barW: 4,
  );

  /// 触摸：命中半径整圈放大到 44 —— Material 的最小可点区域。
  /// 原值角 32 / 边 26 在手机上经常「按不中手柄，反而判成新建选区把框拖没了」。
  static const touch = _HandleSpec(
    cornerHit: 44,
    edgeHit: 34,
    armLen: 26,
    armW: 4,
    barLen: 30,
    barW: 5,
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

  /// 空白处新建选区的最小跨度（显示像素）。
  ///
  /// 触摸设备上「轻点空白」极易被判成从零开始的新选区 —— 一次误触就把辛苦拖好的
  /// 框清零。低于该阈值直接忽略，原矩形原地不动。
  static const double _kMinNewSelectionSpan = 12;

  double get _imgW => widget.imageSize.width;
  double get _imgH => widget.imageSize.height;

  bool get _touch => isMobilePlatform;
  _HandleSpec get _spec => _touch ? _HandleSpec.touch : _HandleSpec.desktop;

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
    final cornerT = _spec.cornerHit;
    final edgeT = _spec.edgeHit;
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
      // 新建选区：从起点到当前点。跨度不足阈值视为误触，原矩形原地不动。
      final probe = Rect.fromPoints(_dragStart!, clamped);
      if (probe.width < _kMinNewSelectionSpan || probe.height < _kMinNewSelectionSpan) {
        return;
      }
      dispRect = probe;
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
    _clearDragState();
  }

  void _clearDragState() {
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
    final int x = _rect.left.round().clamp(0, math.max(0, _imgW.toInt() - 1));
    final int y = _rect.top.round().clamp(0, math.max(0, _imgH.toInt() - 1));
    final int w = _rect.width.round().clamp(1, math.max(1, _imgW.toInt() - x));
    final int h = _rect.height.round().clamp(1, math.max(1, _imgH.toInt() - y));
    return Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
  }

  void _close() => Navigator.of(context).pop();

  void _apply() => Navigator.of(context).pop(_commitRect());

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final zh = widget.isZh;
    final media = MediaQuery.of(context);
    // 版式按宽高比分流：横屏用侧栏，竖屏用底部工具条。
    // 判据用「宽 ≥ 高 × 1.15」而不是「宽 > 高」——接近正方形的窗口（平板分屏、
    // 手机横屏但带键盘）走侧栏会把画布压得太窄，留一点迟滞更稳。
    final landscape = media.size.width >= media.size.height * 1.15;

    final canvas = Container(color: Colors.black, child: _buildCanvas(cs, zh));

    return Material(
      color: cs.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(isMobilePlatform ? 0 : 14),
      ),
      child: SafeArea(
        child: landscape
            ? Row(children: [
                Expanded(child: canvas),
                _buildSidePanel(cs, zh, media.size),
              ])
            : Column(children: [
                _buildTitleBar(cs, zh),
                Expanded(child: canvas),
                _buildBottomBar(cs, zh),
              ]),
      ),
    );
  }

  // ---------- 画布 ----------

  Widget _buildCanvas(ColorScheme cs, bool zh) {
    return LayoutBuilder(builder: (ctx, constraints) {
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
          _clearDragState();
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
                spec: _spec,
                label: '${_rect.width.round()} × ${_rect.height.round()}',
                hint: zh ? '拖动角点缩放 · 拖动框内移动 · 空白处拖出新选区' : 'Drag corners to resize · drag inside to move · drag outside for a new selection',
                showHint: _moving == null && dispRect.width < dispW * 0.9,
              ),
            ),
          ),
        ]),
      );
    });
  }

  // ---------- 标题栏（竖屏） ----------

  Widget _buildTitleBar(ColorScheme cs, bool zh) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          visualDensity: VisualDensity.compact,
          tooltip: zh ? '取消' : 'Cancel',
          onPressed: _close,
        ),
        Expanded(
          child: Text(zh ? '裁剪图片' : 'Crop Image',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
        ),
        const SizedBox(width: 40),
      ]),
    );
  }

  // ---------- 侧栏（横屏） ----------

  Widget _buildSidePanel(ColorScheme cs, bool zh, Size screen) {
    // 侧栏宽度：横向屏幕的 36%，上限 300、下限 232。
    // 下限保证三行工具在窄横屏（小折叠屏展开）里仍能排得下；上限保证画布
    // 在 iPad 横屏这类大屏上不被侧栏吃掉太多（300 足够放「16:9」这类芯片）。
    final w = (screen.width * 0.36).clamp(232.0, 300.0);
    const sz = AppControlSize.regular;

    return Container(
      width: w,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(left: BorderSide(color: cs.outlineVariant.withAlpha(140))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(children: [
            Icon(Icons.crop_free, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(zh ? '裁剪图片' : 'Crop Image',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: zh ? '取消' : 'Cancel',
              onPressed: _close,
            ),
          ]),
        ),
        Divider(height: 1, color: cs.outlineVariant.withAlpha(120)),

        // 选区尺寸：横屏下画布上的尺寸标签离视线很远，侧栏顶部固定一份更直观
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: _buildSizeReadout(cs)),
        const SizedBox(height: 12),

        // 比例芯片（竖排 Wrap）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(zh ? '宽高比' : 'Aspect Ratio',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: cs.outline)),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 8, runSpacing: 8, children: _ratioChips(zh)),
          ),
        ),

        // 底部固定操作区
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: sz.buttonStyle(),
                  onPressed: _selectAll,
                  icon: Icon(Icons.select_all, size: sz.iconSize),
                  label: Text(zh ? '全选' : 'All',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: sz.buttonStyle(),
                  onPressed: _reset,
                  icon: Icon(Icons.restart_alt, size: sz.iconSize),
                  label: Text(zh ? '重置' : 'Reset',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            FilledButton.icon(
              style: sz.buttonStyle(filled: true),
              onPressed: _apply,
              icon: Icon(Icons.check, size: sz.iconSize),
              label: Text(zh ? '确定裁剪' : 'Apply Crop'),
            ),
          ]),
        ),
      ]),
    );
  }

  // ---------- 底部工具条（竖屏） ----------

  Widget _buildBottomBar(ColorScheme cs, bool zh) {
    const sz = AppControlSize.regular;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // 芯片行：横向滚动，不占第二行
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: _ratioChips(zh),
          ),
        ),
        const SizedBox(height: 8),
        // 操作 + 确定并成一行：原来的三行（芯片 / 全选重置 / 确定按钮）在
        // 竖屏手机上就把画布吃掉一大截，横屏更是直接压成一条缝。
        Row(children: [
          OutlinedButton(
            style: sz.buttonStyle(),
            onPressed: _selectAll,
            child: Icon(Icons.select_all, size: sz.iconSize, semanticLabel: zh ? '全选' : 'All'),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            style: sz.buttonStyle(),
            onPressed: _reset,
            child: Icon(Icons.restart_alt, size: sz.iconSize, semanticLabel: zh ? '重置' : 'Reset'),
          ),
          const SizedBox(width: 10),
          Expanded(child: _buildSizeReadout(cs, dense: true)),
          const SizedBox(width: 10),
          FilledButton.icon(
            style: sz.buttonStyle(filled: true),
            onPressed: _apply,
            icon: Icon(Icons.check, size: sz.iconSize),
            label: Text(zh ? '确定' : 'Apply'),
          ),
        ]),
      ]),
    );
  }

  /// 「宽 × 高」读数：主色底 + 主色字，视觉上与两侧工具按钮区分开。
  Widget _buildSizeReadout(ColorScheme cs, {bool dense = false}) {
    final w = _rect.width.round();
    final h = _rect.height.round();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 5 : 8),
      decoration: BoxDecoration(
        color: cs.primary.withAlpha(18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.aspect_ratio, size: 13, color: cs.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '$w × $h',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.primary,
            ),
          ),
        ),
      ]),
    );
  }

  List<Widget> _ratioChips(bool zh) => [
        _ratioChip(0, null, zh ? '自由' : 'Free'),
        _ratioChip(1, 1.0, '1:1'),
        _ratioChip(2, 4 / 3, '4:3'),
        _ratioChip(3, 3 / 4, '3:4'),
        _ratioChip(4, 16 / 9, '16:9'),
        _ratioChip(5, 9 / 16, '9:16'),
        _ratioChip(6, _imgW / _imgH, zh ? '原始' : 'Original'),
      ];

  Widget _ratioChip(int index, double? ratio, String label) {
    final selected = _ratioIndex == index;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        labelStyle: const TextStyle(fontSize: 12),
        selected: selected,
        // shrinkWrap + 收紧 density：默认的 48 命中盒会把芯片行撑到 40+，
        // 竖屏底部那条工具条就又变高了
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: const VisualDensity(horizontal: -1, vertical: -2),
        onSelected: (_) => _setRatio(index, ratio),
      ),
    );
  }
}

/// 裁剪画布叠加层：暗化选区外、边框、8 个手柄、三分线、尺寸标签。
class _CropCanvasPainter extends CustomPainter {
  final Rect cropRect;
  final Color accent;
  final _HandleSpec spec;
  final String label;
  final String hint;
  final bool showHint;

  _CropCanvasPainter({
    required this.cropRect,
    required this.accent,
    required this.spec,
    required this.label,
    required this.hint,
    required this.showHint,
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

    // 手柄：4 角 L 形角标（外白内彩，深色照片上也能看清）+ 4 边短条。
    // 旧实现是 8 个同样大小的圆点/短条，在手机上既小又分不清是角还是边；
    // L 形角标是照片裁剪器的通用语言，一眼就知道「这是可以拉的东西」。
    final accentStroke = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = spec.armW;
    final haloStroke = Paint()
      ..color = Colors.white.withAlpha(210)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = spec.armW + 2.6;

    void corner(Offset c, double sx, double sy) {
      final hx = spec.armLen * sx;
      final hy = spec.armLen * sy;
      final path = Path()
        ..moveTo(c.dx + hx, c.dy)
        ..lineTo(c.dx, c.dy)
        ..lineTo(c.dx, c.dy + hy);
      canvas.drawPath(path, haloStroke);
      canvas.drawPath(path, accentStroke);
    }

    corner(r.topLeft, 1, 1);
    corner(r.topRight, -1, 1);
    corner(r.bottomLeft, 1, -1);
    corner(r.bottomRight, -1, -1);

    final edgePaint = Paint()..color = accent;
    void bar(Offset c, bool horizontal) {
      final rect = horizontal
          ? Rect.fromCenter(center: c, width: spec.barLen, height: spec.barW)
          : Rect.fromCenter(center: c, width: spec.barW, height: spec.barLen);
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

    // 首次进入的操作提示：贴着选区下沿（框太小/贴底时改放框内顶部）
    if (!showHint) return;
    final hp = TextPainter(
      text: TextSpan(
        text: hint,
        style: TextStyle(
          color: Colors.white.withAlpha(200),
          fontSize: 10,
          background: Paint()..color = Colors.black.withAlpha(140),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(40, size.width - 16));
    final hy = r.bottom + 6 + hp.height > size.height ? r.top + 6 : r.bottom + 6;
    hp.paint(canvas, Offset((size.width - hp.width) / 2, hy));
  }

  @override
  bool shouldRepaint(_CropCanvasPainter old) =>
      old.cropRect != cropRect ||
      old.accent != accent ||
      old.label != label ||
      old.showHint != showHint ||
      old.spec != spec;
}
