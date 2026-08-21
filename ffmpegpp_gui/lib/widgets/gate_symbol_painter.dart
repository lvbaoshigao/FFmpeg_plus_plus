import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/models.dart' show LogicGateType;

/// 逻辑门符号画笔：ANSI/IEEE（特色形状）或 IEC（矩形框）。
///
/// 支持与门/或门/非门/与非门/或非门/异或门/同或门/恒1/恒0/时间触发器，并带取反圈，
/// 符号几何遵循 ANSI/IEEE 与 IEC 标准：
///   - ANSI AND/NAND ：D 形（左侧直线 + 右侧半圆）
///   - ANSI OR/NOR  ：盾形（左侧内凹弧 + 上/下沿汇于右侧尖端 + 输出圈）
///   - ANSI XOR/XNOR：D 形 + 输入侧附加曲线（异或门双弧线）
///   - ANSI NOT     ：三角形（缓冲器符号）+ 输出圈
///   - IEC          ：矩形框 + 内部符号，取反门输出侧加圈
///
/// 尺寸约定：传入的 size 为门符号区宽高（画布上为 64×64）。形状右侧
/// 在取反门时内缩 [outInset]，保证取反圈完整落在画布内。
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
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillP = Paint()..color = color..style = PaintingStyle.fill;
    final constOne = gate == LogicGateType.const1;
    final constZero = gate == LogicGateType.const0;
    final negated = gate == LogicGateType.nand || gate == LogicGateType.nor || gate == LogicGateType.not || gate == LogicGateType.xnor;

    // 恒1/恒0：直接画大号数字
    if (constOne || constZero) {
      final tp = TextPainter(
        text: TextSpan(text: constOne ? '1' : '0', style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(hw - tp.width / 2, hh - tp.height / 2));
      return;
    }

    // 时间触发器：画时钟图标
    if (gate == LogicGateType.timeTrigger) {
      final r = math.min(w, h) / 2 - 4;
      final c = Offset(hw, hh);
      canvas.drawCircle(c, r, paint);
      for (var i = 0; i < 12; i++) {
        final a = i * math.pi / 6;
        final inner = r * (i % 3 == 0 ? 0.72 : 0.82);
        final outer = r * 0.92;
        canvas.drawLine(
          Offset(c.dx + inner * math.sin(a), c.dy - inner * math.cos(a)),
          Offset(c.dx + outer * math.sin(a), c.dy - outer * math.cos(a)),
          paint,
        );
      }
      canvas.drawLine(c, Offset(c.dx + r * 0.45 * math.sin(10 * math.pi / 6), c.dy - r * 0.45 * math.cos(10 * math.pi / 6)), paint);
      canvas.drawLine(c, Offset(c.dx + r * 0.62 * math.sin(2 * math.pi / 6), c.dy - r * 0.62 * math.cos(2 * math.pi / 6)), paint);
      return;
    }

    const pad = 6.0;
    final boxTop = pad;
    final boxBot = h - pad;
    final span = boxBot - boxTop;           // 形状高度
    const outInset = 6.0;                   // 取反门右侧内缩，为圈留空间
    final frontX = negated ? w - pad - outInset : w - pad;
    final backX = pad + 2;
    final lab = _label;
    const bubbleR = 4.0;                    // 取反圈半径

    if (!iec) {
      // ═══════════ ANSI/IEEE：特色形状 ═══════════
      if (gate == LogicGateType.and || gate == LogicGateType.nand) {
        // 与门：D 形 — 左侧直线 + 右侧半圆（半圆必然凸向右）
        final arcR = span / 2;
        final arcCx = frontX - arcR;      // 半圆圆心 x
        final path = Path()
          ..moveTo(backX, boxTop)
          ..lineTo(arcCx, boxTop)
          ..arcTo(
            Rect.fromCircle(center: Offset(arcCx, hh), radius: arcR),
            -math.pi / 2, // 12 点钟方向
            math.pi,      // 顺时针 180°
            false,
          )
          ..lineTo(backX, boxBot)
          ..close();
        canvas.drawPath(path, paint);
        _labelText(canvas, lab, Offset(backX + (arcCx - backX) * 0.5, hh));
      } else if (gate == LogicGateType.or || gate == LogicGateType.nor) {
        // 或门：盾形 — 左侧内凹弧 + 上/下沿凸向尖端
        final tipX = frontX - 4;
        // 上/下沿控制点：略高于/低于形状边界，使曲线自然凸起
        final ctrlX = backX + (tipX - backX) * 0.55;
        final ctrlY = boxTop - 2;
        // 左侧内凹弧（向左凸）：控制点 x 明显左移
        final leftCtrlX = backX - 6;
        final path = Path()
          ..moveTo(backX + 4, boxTop)
          ..quadraticBezierTo(ctrlX, ctrlY, tipX, hh)           // 上沿 → 尖端（凸向上）
          ..quadraticBezierTo(ctrlX, boxBot + 2, backX + 4, boxBot) // 尖端 → 下沿（凸向下）
          ..quadraticBezierTo(leftCtrlX, hh, backX + 4, boxTop) // 左侧内凹（凸向左）
          ..close();
        canvas.drawPath(path, paint);
        _labelText(canvas, lab, Offset((backX + tipX) * 0.5, hh));
      } else if (gate == LogicGateType.xor || gate == LogicGateType.xnor) {
        // 异或/同或门：D 形 + 输入侧附加曲线
        final arcR = span / 2;
        final arcCx = frontX - arcR;
        // 主 D 形
        final path = Path()
          ..moveTo(backX, boxTop)
          ..lineTo(arcCx, boxTop)
          ..arcTo(
            Rect.fromCircle(center: Offset(arcCx, hh), radius: arcR),
            -math.pi / 2,
            math.pi,
            false,
          )
          ..lineTo(backX, boxBot)
          ..close();
        canvas.drawPath(path, paint);
        // 输入侧附加曲线（异或门标志性双弧线）
        final curveX = backX - 8;
        final extraPath = Path()
          ..moveTo(curveX, boxTop + 2)
          ..quadraticBezierTo(backX - 4, hh, curveX, boxBot - 2);
        canvas.drawPath(extraPath, paint);
        _labelText(canvas, lab, Offset(backX + (arcCx - backX) * 0.5, hh));
      } else if (gate == LogicGateType.not) {
        // 非门：三角形（缓冲器符号），尖端在右
        final tipX = frontX - 2;
        final baseX = backX + 4;
        final path = Path()
          ..moveTo(baseX, boxTop)
          ..lineTo(baseX, boxBot)
          ..lineTo(tipX, hh)
          ..close();
        canvas.drawPath(path, paint);
        _labelText(canvas, '1', Offset(baseX + 12, hh));
      }
    } else {
      // ═══════════ IEC：矩形框 + 符号 ═══════════
      canvas.drawRect(Rect.fromLTRB(pad, pad, frontX, boxBot), paint);
      _labelText(canvas, lab, Offset((pad + frontX) / 2, hh));
    }

    // 取反圈（NAND/NOR/NOT/XNOR）：画在输出侧，紧贴形状右缘
    if (negated && !constOne && !constZero) {
      double cx;
      if (iec) {
        cx = frontX + bubbleR;       // 矩形右缘外
      } else if (gate == LogicGateType.not) {
        cx = frontX - 2 + bubbleR;   // 三角形尖端右 + 圈半径
      } else if (gate == LogicGateType.and || gate == LogicGateType.nand || gate == LogicGateType.xor || gate == LogicGateType.xnor) {
        cx = frontX + bubbleR;       // D 形右缘外
      } else {
        cx = frontX - 4 + bubbleR;   // OR 尖端右 + 圈半径
      }
      if (cx + bubbleR <= w) {
        canvas.drawCircle(Offset(cx, hh), bubbleR, fillP);
      }
    }
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
      text: TextSpan(text: t, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(GateSymbolPainter old) =>
      old.gate != gate || old.iec != iec || old.color != color;
}