import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/models.dart' show LogicGateType;

/// 逻辑门符号画笔：ANSI/IEEE（特色形状）或 IEC（矩形框）。
///
/// 支持与门/或门/非门/与非门/或非门/异或门/同或门/恒1/恒0/时间触发器，并带取反圈。
/// 符号几何遵循 ANSI/IEEE 与 IEC 标准：
///   - ANSI AND/NAND ：D 形（左侧直线 + 右侧半圆）
///   - ANSI OR/NOR  ：盾形（左侧内凹弧 + 上下凸弧汇于右侧尖端）
///   - ANSI XOR/XNOR：盾形 + 输入侧附加弧线（异或门双弧线）
///   - ANSI NOT     ：三角形（缓冲器符号）+ 输出圈
///   - IEC          ：矩形框 + 内部符号，取反门输出侧加圈
///
/// 尺寸约定：传入的 size 为门符号区宽高（画布上为 64×64）。取反门右侧为取反圈
/// 预留空间，保证取反圈完整落在画布内。
class GateSymbolPainter extends CustomPainter {
  final LogicGateType gate;
  final bool iec;
  final Color color;
  final bool isZh;
  GateSymbolPainter({required this.gate, required this.iec, required this.color, required this.isZh});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final hw = w / 2, hh = h / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final constOne = gate == LogicGateType.const1;
    final constZero = gate == LogicGateType.const0;

    // 恒 1 / 恒 0：直接画大号数字
    if (constOne || constZero) {
      final tp = TextPainter(
        text: TextSpan(
          text: constOne ? '1' : '0',
          style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(hw - tp.width / 2, hh - tp.height / 2));
      return;
    }

    // 时间触发器：画时钟图标
    if (gate == LogicGateType.timeTrigger) {
      final r = math.min(w, h) / 2 - 5;
      final c = Offset(hw, hh);
      canvas.drawCircle(c, r, paint);
      for (var i = 0; i < 12; i++) {
        final a = i * math.pi / 6;
        final inner = r * (i % 3 == 0 ? 0.7 : 0.8);
        final outer = r * 0.92;
        canvas.drawLine(
          Offset(c.dx + inner * math.sin(a), c.dy - inner * math.cos(a)),
          Offset(c.dx + outer * math.sin(a), c.dy - outer * math.cos(a)),
          paint,
        );
      }
      // 时针（指向 12 点）与分针（指向 3 点）
      canvas.drawLine(c, Offset(c.dx, c.dy - r * 0.42), paint);
      canvas.drawLine(c, Offset(c.dx + r * 0.56, c.dy), paint);
      return;
    }

    final negated = gate == LogicGateType.nand ||
        gate == LogicGateType.nor ||
        gate == LogicGateType.not ||
        gate == LogicGateType.xnor;

    // ── 几何参数 ──
    const pad = 8.0;
    const bubbleR = 5.0;
    final top = pad;
    final bottom = h - pad;
    final cy = hh;
    final half = (bottom - top) / 2; // 半高
    final left = pad;
    // 取反门右侧为取反圈预留空间
    final rightLimit = w - pad - (negated ? bubbleR * 2 + 2 : 0);

    if (!iec) {
      // ═══════════ ANSI/IEEE：特色形状 ═══════════
      if (gate == LogicGateType.and || gate == LogicGateType.nand) {
        // 与门：D 形 —— 左侧平直输入边 + 右侧半圆（半圆圆心在左缘，右缘凸出）
        final path = Path()
          ..moveTo(left, top)
          ..addArc(
            Rect.fromCircle(center: Offset(left, cy), radius: half),
            -math.pi / 2, // 12 点钟方向
            math.pi,      // 顺时针 180°，得到右半圆
          )
          ..close(); // 连接底→顶，形成左侧平直边
        canvas.drawPath(path, paint);
        _labelText(canvas, _label, Offset(left + half * 0.55, cy));
      } else if (gate == LogicGateType.xor || gate == LogicGateType.xnor) {
        // 异或/同或：盾形主体 + 输入侧第二条弧线（双输入弧标志）
        final bodyLeft = left + 4;
        _drawShield(canvas, paint, bodyLeft, top, bottom, rightLimit, cy);
        final extraPath = Path()
          ..moveTo(left + 2, top + 2)
          ..quadraticBezierTo(left - 2, cy, left + 2, bottom - 2);
        canvas.drawPath(extraPath, paint);
        _labelText(canvas, _label, Offset((bodyLeft + rightLimit) / 2, cy));
      } else if (gate == LogicGateType.or || gate == LogicGateType.nor) {
        // 或门：盾形 —— 左侧内凹弧 + 上下凸弧汇于右侧尖端
        _drawShield(canvas, paint, left, top, bottom, rightLimit, cy);
        _labelText(canvas, _label, Offset((left + rightLimit) / 2, cy));
      } else if (gate == LogicGateType.not) {
        // 非门：三角形（缓冲器符号），尖端在右
        final path = Path()
          ..moveTo(left, top)
          ..lineTo(left, bottom)
          ..lineTo(rightLimit, cy)
          ..close();
        canvas.drawPath(path, paint);
        _labelText(canvas, _label, Offset(left + (rightLimit - left) * 0.35, cy));
      }
    } else {
      // ═══════════ IEC：矩形框 + 符号 ═══════════
      canvas.drawRect(Rect.fromLTRB(left, top, rightLimit, bottom), paint);
      _labelText(canvas, _label, Offset((left + rightLimit) / 2, cy));
    }

    // 取反圈（NAND/NOR/NOT/XNOR）：画在输出侧，紧贴形状右缘
    if (negated) {
      double bodyRight;
      if (!iec && (gate == LogicGateType.and || gate == LogicGateType.nand)) {
        bodyRight = left + half; // D 形右缘
      } else {
        bodyRight = rightLimit; // 三角形尖端 / OR·XOR 尖端 / IEC 矩形右缘
      }
      final cx = bodyRight + bubbleR + 1;
      if (cx + bubbleR <= w - 2) {
        canvas.drawCircle(Offset(cx, cy), bubbleR, paint);
      }
    }
  }

  /// 画盾形（OR/NOR/XOR/XNOR 主体）：左侧内凹弧 + 上下凸弧汇于右侧尖端。
  void _drawShield(Canvas canvas, Paint paint, double left, double top,
      double bottom, double right, double cy) {
    final half = (bottom - top) / 2;
    final midX = (left + right) / 2;
    final path = Path()
      ..moveTo(left, top)
      ..quadraticBezierTo(left + half * 0.5, cy, left, bottom)          // 左凹弧（向右凹）
      ..quadraticBezierTo(midX, bottom + half * 0.55, right, cy)        // 下凸弧 → 尖端
      ..quadraticBezierTo(midX, top - half * 0.55, left, top)           // 上凸弧 → 回起点
      ..close();
    canvas.drawPath(path, paint);
  }

  String get _label {
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

  void _labelText(Canvas canvas, String t, Offset center) {
    final tp = TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(GateSymbolPainter old) =>
      old.gate != gate || old.iec != iec || old.color != color;
}
