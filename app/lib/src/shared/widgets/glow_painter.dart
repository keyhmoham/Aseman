import 'package:flutter/material.dart';

/// Quiet ambient wash behind the home shell — two soft orbs, no cyan
/// sprinkle. Signature sky (switcher) uses [SkyAtmospherePainter] instead.
class GlowPainter extends CustomPainter {
  const GlowPainter(this.a, this.b);
  final Color a, b;

  @override
  void paint(Canvas c, Size s) {
    void orb(Offset center, double radius, Color color, double alpha) {
      c.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    orb(Offset(s.width * .5, -40), s.width * .36, a, .12);
    orb(Offset(s.width * .9, s.height), s.width * .28, b, .07);
  }

  @override
  bool shouldRepaint(covariant GlowPainter old) => old.a != a || old.b != b;
}
