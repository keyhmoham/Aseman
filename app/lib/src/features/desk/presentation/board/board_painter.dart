import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/desk_board.dart';
import 'board_geometry.dart';
import 'board_palette.dart';

/// The dotted ground of the whiteboard, drawn in screen space so the dots
/// stay crisp at every zoom.
class BoardGridPainter extends CustomPainter {
  const BoardGridPainter({
    required this.pan,
    required this.scale,
    required this.color,
  });

  final Offset pan;
  final double scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    var step = 28.0 * scale;
    // Far out the dots would be a haze: use every fourth.
    while (step < 14) {
      step *= 2;
    }
    final paint = Paint()..color = color;
    final r = math.max(.8, math.min(1.6, scale * 1.2));
    final startX = pan.dx % step;
    final startY = pan.dy % step;
    for (var x = startX; x < size.width; x += step) {
      for (var y = startY; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(BoardGridPainter old) =>
      old.pan != pan || old.scale != scale || old.color != color;
}

/// Draws [path] dashed or dotted ([dash] solid draws it whole).
void drawStyledPath(Canvas canvas, Path path, Paint paint, String dash) {
  if (dash != 'dashed' && dash != 'dotted') {
    canvas.drawPath(path, paint);
    return;
  }
  final on = dash == 'dashed' ? paint.strokeWidth * 3 + 4 : 0.1;
  final off = dash == 'dashed' ? paint.strokeWidth * 2 + 4 : paint.strokeWidth * 2 + 3;
  final dotted = Paint.from(paint)..strokeCap = StrokeCap.round;
  for (final m in path.computeMetrics()) {
    var d = 0.0;
    while (d < m.length) {
      canvas.drawPath(
        m.extractPath(d, math.min(m.length, d + on)),
        dash == 'dotted' ? dotted : paint,
      );
      d += on + off;
    }
  }
}

/// An arrow's head (or tail) of [style] at [tip] pointing along [dir].
void drawArrowHead(
  Canvas canvas,
  Offset tip,
  Offset dir,
  String style,
  Color color,
  double width,
) {
  if (style == 'none' || style.isEmpty) return;
  final paint = Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final len = 9.0 + width * 2.2;
  final normal = Offset(-dir.dy, dir.dx);
  switch (style) {
    case 'dot':
      canvas.drawCircle(tip - dir * (len / 3), len / 3, paint..style = PaintingStyle.fill);
    case 'bar':
      canvas.drawLine(
        tip + normal * (len * .6),
        tip - normal * (len * .6),
        paint..style = PaintingStyle.stroke,
      );
    default:
      final back = tip - dir * len;
      final head = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(back.dx + normal.dx * len * .5, back.dy + normal.dy * len * .5)
        ..lineTo(back.dx - normal.dx * len * .5, back.dy - normal.dy * len * .5)
        ..close();
      canvas.drawPath(head, paint..style = PaintingStyle.fill);
  }
}

/// The arrows, in world coordinates under the notes and windows. An arrow
/// whose ends have gone is not drawn.
class BoardLinesPainter extends CustomPainter {
  BoardLinesPainter({
    required this.arrows,
    required this.resolve,
    required this.scheme,
    required this.selected,
    required this.pan,
    required this.scale,
  });

  final List<DeskItem> arrows;
  final BoardResolver resolve;
  final ColorScheme scheme;
  final Set<String> selected;
  final Offset pan;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(scale);
    for (final a in arrows) {
      final shape = arrowShape(a, resolve);
      if (shape == null) continue;
      final ink = BoardInk.of(scheme, a.color, fallback: 'gray');
      final width = a.width > 0 ? a.width : 2.0;
      if (selected.contains(a.id)) {
        canvas.drawPath(
          shape.path,
          Paint()
            ..color = scheme.primary.withValues(alpha: .28)
            ..style = PaintingStyle.stroke
            ..strokeWidth = width + 8
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
      final line = Paint()
        ..color = ink.strong
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      drawStyledPath(canvas, shape.path, line, a.dash);
      drawArrowHead(canvas, shape.end, shape.endDir, a.head, ink.strong, width);
      drawArrowHead(canvas, shape.start, shape.startDir, a.tail, ink.strong, width);
      if (a.text.trim().isNotEmpty) _label(canvas, a.text, shape.mid, ink);
    }
    canvas.restore();
  }

  void _label(Canvas canvas, String text, Offset at, BoardInk ink) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 13, color: scheme.onSurface, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: 180);
    final box = RRect.fromRectAndRadius(
      Rect.fromCenter(center: at, width: tp.width + 14, height: tp.height + 8),
      const Radius.circular(8),
    );
    canvas.drawRRect(box, Paint()..color = scheme.surface);
    canvas.drawRRect(
      box,
      Paint()
        ..color = ink.strong.withValues(alpha: .6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(BoardLinesPainter old) => true;
}

/// A live preview of something being drawn.
class BoardPreview {
  const BoardPreview({
    this.arrowFrom,
    this.arrowTo,
    this.shapeRect,
    this.shapeKind = 'rect',
    this.penPoints = const [],
    this.marquee,
    this.snap,
    this.color = 'gray',
  });

  final Offset? arrowFrom;
  final Offset? arrowTo;
  final Rect? shapeRect;
  final String shapeKind;
  final List<Offset> penPoints;
  final Rect? marquee;

  /// The box an arrow end is about to stick to.
  final Rect? snap;
  final String color;
}

/// Pen strokes (over the notes, as annotations), the preview of what is being
/// drawn, and the selection marquee. World coordinates.
class BoardInkPainter extends CustomPainter {
  BoardInkPainter({
    required this.strokes,
    required this.preview,
    required this.scheme,
    required this.selected,
    required this.pan,
    required this.scale,
  });

  final List<DeskItem> strokes;
  final BoardPreview? preview;
  final ColorScheme scheme;
  final Set<String> selected;
  final Offset pan;
  final double scale;

  static Path strokePath(List<Offset> pts) {
    final path = Path();
    if (pts.isEmpty) return path;
    path.moveTo(pts.first.dx, pts.first.dy);
    if (pts.length == 2) {
      path.lineTo(pts.last.dx, pts.last.dy);
      return path;
    }
    for (var i = 1; i < pts.length - 1; i++) {
      final mid = Offset(
        (pts[i].dx + pts[i + 1].dx) / 2,
        (pts[i].dy + pts[i + 1].dy) / 2,
      );
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(pan.dx, pan.dy);
    canvas.scale(scale);
    for (final s in strokes) {
      if (s.points.length < 2) continue;
      final ink = BoardInk.of(scheme, s.color, fallback: 'black');
      final path = strokePath(s.points);
      if (selected.contains(s.id)) {
        canvas.drawPath(
          path,
          Paint()
            ..color = scheme.primary.withValues(alpha: .28)
            ..style = PaintingStyle.stroke
            ..strokeWidth = (s.width > 0 ? s.width : 3) + 8
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = ink.strong
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.width > 0 ? s.width : 3
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final p = preview;
    if (p != null) {
      final ink = BoardInk.of(scheme, p.color);
      if (p.penPoints.length >= 2) {
        canvas.drawPath(
          strokePath(p.penPoints),
          Paint()
            ..color = ink.strong
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
      final a = p.arrowFrom, b = p.arrowTo;
      if (a != null && b != null) {
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = ink.strong
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
        final dir = (b - a).distance == 0 ? const Offset(1, 0) : (b - a) / (b - a).distance;
        drawArrowHead(canvas, b, dir, 'arrow', ink.strong, 2);
      }
      if (p.snap != null) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(p.snap!.inflate(4), const Radius.circular(8)),
          Paint()
            ..color = scheme.primary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / scale,
        );
      }
      final r = p.shapeRect;
      if (r != null) {
        final stroke = Paint()
          ..color = ink.strong
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        canvas.drawPath(shapeOutline(p.shapeKind, r), stroke);
      }
      final m = p.marquee;
      if (m != null) {
        canvas.drawRect(m, Paint()..color = scheme.primary.withValues(alpha: .08));
        canvas.drawRect(
          m,
          Paint()
            ..color = scheme.primary.withValues(alpha: .7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / scale,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BoardInkPainter old) => true;
}

/// The outline of a shape of kind [kind] filling [r].
Path shapeOutline(String kind, Rect r) {
  final path = Path();
  switch (kind) {
    case 'ellipse':
      path.addOval(r);
    case 'round':
      path.addRRect(RRect.fromRectAndRadius(r, Radius.circular(math.min(r.width, r.height) / 2.4)));
    case 'diamond':
      path
        ..moveTo(r.center.dx, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.center.dx, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
    case 'triangle':
      path
        ..moveTo(r.center.dx, r.top)
        ..lineTo(r.right, r.bottom)
        ..lineTo(r.left, r.bottom)
        ..close();
    case 'hexagon':
      final k = math.min(r.width * .25, r.height * .5);
      path
        ..moveTo(r.left + k, r.top)
        ..lineTo(r.right - k, r.top)
        ..lineTo(r.right, r.center.dy)
        ..lineTo(r.right - k, r.bottom)
        ..lineTo(r.left + k, r.bottom)
        ..lineTo(r.left, r.center.dy)
        ..close();
    default:
      path.addRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)));
  }
  return path;
}
