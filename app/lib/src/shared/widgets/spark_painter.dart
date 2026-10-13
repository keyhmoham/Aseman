import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lightweight chart-line painter used for market/candle sparklines.
class SparkPainter extends CustomPainter {
  const SparkPainter(this.color);
  final Color color;
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(0, s.height * .7);
    for (var i = 1; i < 9; i++) {
      path.lineTo(s.width * i / 8,
          s.height * (.55 + math.sin(i * 1.5) * .2 - i * .025));
    }
    c.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant SparkPainter old) => old.color != color;
}
