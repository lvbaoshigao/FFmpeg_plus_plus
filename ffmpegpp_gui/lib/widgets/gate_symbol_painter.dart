import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/models.dart' show LogicGateType;

/// 逻辑门符号画笔：ANSI/IEEE（特色形状）或 IEC（矩形框）。
///
/// 支持与门/或门/非门/与非门/或非门/异或门/同或门/恒1/恒0/时间触发器，并带取反圈。
/// 符号几何遵循 ANSI/IEEE 与 IEC 标准：
///   - ANSI AND/NAND ：D 形（左侧平直输入边 + 右侧半圆凸出输出边）
///   - ANSI OR/NOR  ：盾形（左侧内凹弧 + 上下凸弧汇于右侧尖端）
///   - ANSI XOR/XNOR：盾形 + 输入侧额外弧线（双输入弧标志）
///   - ANSI NOT     ：三角形（缓冲器符号）+ 输出取反圈
///   - IEC          ：矩形框 + 内部符号，取反门输出侧加圈
///
/// 所有几何均按画布尺寸等比例缩放，并严格限制在画布内部（不再越界被裁切），
/// 取反圈在输出侧预留空间，保证完整显示。
class GateSymbolPainter extends CustomPainter {
  final LogicGateType gate;
  final bool iec;
  final Color color;
  GateSymbolPainter({
    required this.gate,
    required this.iec,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || size.shortestSide < 8) return;
    final w = size.width, h = size.height;
    final hw = w / 2, hh = h / 2;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, math.min(w, h) * 0.032)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 恒 1 / 恒 0：大号数字
    if (gate == LogicGateType.const1 || gate == LogicGateType.const0) {
      _label(canvas, gate == LogicGateType.const1 ? '1' : '0',
          Offset(hw, hh), math.min(w, h) * 0.42);
      return;
    }

    // 时间触发器：时钟图标
    if (gate == LogicGateType.timeTrigger) {
      _drawClock(canvas, stroke, hw, hh, math.min(w, h));
      return;
    }

    final negated = gate == LogicGateType.nand ||
        gate == LogicGateType.nor ||
        gate == LogicGateType.not ||
        gate == LogicGateType.xnor;

    // ── 比例化几何参数（全部落在画布内） ──
    final padX = w * 0.16;
    final top = h * 0.18;
    final bottom = h * 0.82;
    final cy = hh;
    final left = padX;
    // 取反圈半径，比例化
    final bubbleR = math.min(w, h) * 0.078;
    // 取反门右侧为取反圈预留空间
    final rightLimit = w - padX - (negated ? bubbleR * 2 + 2 : 0);

    if (!iec) {
      if (gate == LogicGateType.and || gate == LogicGateType.nand) {
        _drawAnd(canvas, stroke, left, top, bottom, cy);
      } else if (gate == LogicGateType.xor || gate == LogicGateType.xnor) {
        // 异或/同或：主体盾形右移，输入侧再画第二条内凹弧
        final bodyLeft = left + w * 0.10;
        _drawShield(canvas, stroke, bodyLeft, top, bottom, rightLimit, cy);
        // 第二条输入弧（紧贴并略左于主体左缘）
        final arc = Path()
          ..moveTo(left + w * 0.02, top + h * 0.02)
          ..quadraticBezierTo(left - w * 0.09, cy, left + w * 0.02, bottom - h * 0.02);
        canvas.drawPath(arc, stroke);
      } else if (gate == LogicGateType.or || gate == LogicGateType.nor) {
        _drawShield(canvas, stroke, left, top, bottom, rightLimit, cy);
      } else if (gate == LogicGateType.not) {
        final path = Path()
          ..moveTo(left, top)
          ..lineTo(left, bottom)
          ..lineTo(rightLimit, cy)
          ..close();
        canvas.drawPath(path, stroke);
      }
    } else {
      // IEC：矩形框 + 内部符号
      canvas.drawRect(Rect.fromLTRB(left, top, rightLimit, bottom), stroke);
    }

    // 内部符号文本（&、≥1、1、=1、=）—— 仅 IEC 矩形框标准需要标注。
    // ANSI/IEEE 用特色形状本身表达语义（D 形=与、盾形=或、三角=非、盾形+弧=异或），
    // 中间不再写 & / 1 之类数据，符合 ANSI unique-shape 规范。
    if (iec) {
      final labelX = _labelCenterX(gate, left, rightLimit, bottom - top, w);
      _label(canvas, _symbol, Offset(labelX, cy), math.min(w, h) * 0.20);
    }

    // 取反圈（NAND/NOR/NOT/XNOR）：输出侧，紧贴形状右缘
    if (negated) {
      final cx = rightLimit + bubbleR + 1;
      if (cx + bubbleR <= w - 1) {
        canvas.drawCircle(Offset(cx, cy), bubbleR, stroke);
      }
    }
  }

  double _labelCenterX(LogicGateType g, double left, double right, double half, double w) {
    if (!iec) {
      switch (g) {
        case LogicGateType.and:
        case LogicGateType.nand:
          return left + half * 0.5; // D 形左侧平直区
        case LogicGateType.not:
          return left + (right - left) * 0.36; // 三角形偏左
        case LogicGateType.xor:
        case LogicGateType.xnor:
          return left + w * 0.10 + (right - (left + w * 0.10)) * 0.45;
        default:
          return left + (right - left) * 0.45;
      }
    }
    return left + (right - left) / 2;
  }

  /// AND/NAND：D 形 —— 左侧平直输入边 + 右侧半圆输出边。
  void _drawAnd(Canvas canvas, Paint p, double left, double top, double bottom, double cy) {
    final half = (bottom - top) / 2;
    final path = Path()
      ..moveTo(left, top)
      ..addArc(
        Rect.fromCircle(center: Offset(left, cy), radius: half),
        -math.pi / 2, // 12 点钟方向
        math.pi, // 顺时针 180°，得到右半圆
      )
      ..close();
    canvas.drawPath(path, p);
  }

  /// 盾形（OR/NOR/XOR/XNOR 主体）：左侧内凹弧 + 上下凸弧汇于右侧尖端。
  /// 上下凸弧外鼓量控制在 padY 内，保证不越界被裁切。
  void _drawShield(Canvas canvas, Paint p, double left, double top,
      double bottom, double right, double cy) {
    final half = (bottom - top) / 2;
    final midX = (left + right) / 2;
    final path = Path()
      ..moveTo(left, top)
      ..quadraticBezierTo(left + half * 0.6, cy, left, bottom) // 左凹弧
      ..quadraticBezierTo(midX, bottom + half * 0.30, right, cy) // 下凸弧
      ..quadraticBezierTo(midX, top - half * 0.30, left, top) // 上凸弧
      ..close();
    canvas.drawPath(path, p);
  }

  /// 时钟图标（时间触发器）。
  void _drawClock(Canvas canvas, Paint p, double cx, double cy, double minSide) {
    final r = minSide / 2 - 4;
    canvas.drawCircle(Offset(cx, cy), r, p);
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      final inner = r * (i % 3 == 0 ? 0.70 : 0.80);
      final outer = r * 0.92;
      canvas.drawLine(
        Offset(cx + inner * math.sin(a), cy - inner * math.cos(a)),
        Offset(cx + outer * math.sin(a), cy - outer * math.cos(a)),
        p,
      );
    }
    // 时针（指向 12 点）与分针（指向 3 点）
    canvas.drawLine(Offset(cx, cy), Offset(cx, cy - r * 0.42), p);
    canvas.drawLine(Offset(cx, cy), Offset(cx + r * 0.56, cy), p);
  }

  String get _symbol {
    switch (gate) {
      case LogicGateType.and: return '&';
      case LogicGateType.or: return '≥1';
      case LogicGateType.not: return '1';
      case LogicGateType.nand: return '&';
      case LogicGateType.nor: return '≥1';
      case LogicGateType.xor: return '=1';
      case LogicGateType.xnor: return '=';
      default: return '';
    }
  }

  /// 居中绘制文本。
  void _label(Canvas canvas, String t, Offset center, double fontSize) {
    if (t.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(GateSymbolPainter old) =>
      old.gate != gate || old.iec != iec || old.color != color;
}