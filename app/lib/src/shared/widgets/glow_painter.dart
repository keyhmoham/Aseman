import 'package:flutter/material.dart';

/// Ambient background glow used behind the app shell and pages.
class GlowPainter extends CustomPainter {
  const GlowPainter(this.a, this.b);
  final Color a, b;
  @override
  void paint(Canvas c, Size s) {
    c.drawCircle(
        Offset(s.width * .5, -40),
        s.width * .36,
        Paint()
          ..shader = RadialGradient(
                  colors: [a.withValues(alpha: .16), a.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(
                  center: Offset(s.width * .5, -40), radius: s.width * .36)));
    c.drawCircle(
        Offset(s.width * .9, s.height),
        s.width * .25,
        Paint()
          ..shader = RadialGradient(
                  colors: [b.withValues(alpha: .08), b.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(
                  center: Offset(s.width * .9, s.height),
                  radius: s.width * .25)));
  }

  @override
  bool shouldRepaint(covariant GlowPainter old) => false;
}
