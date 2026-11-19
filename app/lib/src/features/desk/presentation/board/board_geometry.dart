import 'dart:math' as math;
import 'dart:ui';

import '../../domain/desk_board.dart';

/// What an arrow can be stuck to: a box with a look (a note, a shape, text, or
/// a window, which is a plain rectangle).
class BoardTarget {
  const BoardTarget(this.rect, {this.shape = 'rect'});
  final Rect rect;
  final String shape;
}

/// Finds what an arrow end is stuck to, if it still is.
typedef BoardResolver = BoardTarget? Function(String ref);

/// Where an arrow runs and how it is drawn.
class ArrowShape {
  const ArrowShape({
    required this.path,
    required this.start,
    required this.end,
    required this.startDir,
    required this.endDir,
    required this.mid,
  });

  final Path path;
  final Offset start;
  final Offset end;

  /// Unit vectors pointing out of the line at each end (the way a head points).
  final Offset startDir;
  final Offset endDir;

  /// The label's place.
  final Offset mid;

  /// Points along the line, for hit-testing.
  List<Offset> samples({double step = 8}) {
    final out = <Offset>[];
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += step) {
        out.add(m.getTangentForOffset(d)!.position);
      }
      out.add(m.getTangentForOffset(m.length)!.position);
    }
    return out;
  }

  /// Distance from [p] to the line.
  double distanceTo(Offset p) {
    var best = double.infinity;
    final s = samples(step: 6);
    for (var i = 0; i < s.length; i++) {
      final d = i == 0
          ? (s[i] - p).distance
          : _segmentDistance(p, s[i - 1], s[i]);
      if (d < best) best = d;
    }
    return best;
  }
}

double _segmentDistance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

Offset _unit(Offset v) {
  final d = v.distance;
  return d == 0 ? const Offset(1, 0) : v / d;
}

/// The point where the line from [target]'s middle toward [toward] leaves its
/// outline, a little [gap] outside it.
Offset boundaryPoint(BoardTarget target, Offset toward, {double gap = 4}) {
  final r = target.rect;
  final c = r.center;
  final v = toward - c;
  if (v == Offset.zero) return c;
  final dir = _unit(v);
  final a = r.width / 2, b = r.height / 2;
  double t;
  switch (target.shape) {
    case 'ellipse':
      t = 1 / math.sqrt((dir.dx * dir.dx) / (a * a) + (dir.dy * dir.dy) / (b * b));
    case 'diamond':
      t = 1 / (dir.dx.abs() / a + dir.dy.abs() / b);
    default:
      final tx = dir.dx == 0 ? double.infinity : a / dir.dx.abs();
      final ty = dir.dy == 0 ? double.infinity : b / dir.dy.abs();
      t = math.min(tx, ty);
  }
  return c + dir * (t + gap);
}

/// Routes [arrow] between its ends. Null when an end is stuck to something
/// that is gone.
ArrowShape? arrowShape(DeskItem arrow, BoardResolver resolve) {
  final from = arrow.from, to = arrow.to;
  if (from == null || to == null) return null;
  BoardTarget? a, b;
  if (from.stuck) {
    a = resolve(from.ref);
    if (a == null) return null;
  }
  if (to.stuck) {
    b = resolve(to.ref);
    if (b == null) return null;
  }
  final aRef = a?.rect.center ?? from.point;
  final bRef = b?.rect.center ?? to.point;
  final start = a == null ? from.point : boundaryPoint(a, bRef);
  final end = b == null ? to.point : boundaryPoint(b, aRef);
  final horizontal = (end.dx - start.dx).abs() >= (end.dy - start.dy).abs();
  final path = Path()..moveTo(start.dx, start.dy);
  late Offset startDir, endDir, mid;
  switch (arrow.path) {
    case 'curved':
      final k = math.max(40.0, (end - start).distance * .35);
      final lead = horizontal
          ? Offset((end.dx >= start.dx ? 1 : -1) * k, 0)
          : Offset(0, (end.dy >= start.dy ? 1 : -1) * k);
      final c1 = start + lead, c2 = end - lead;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
      startDir = _unit(start - c1);
      endDir = _unit(end - c2);
      mid = Offset(
        (start.dx + 3 * c1.dx + 3 * c2.dx + end.dx) / 8,
        (start.dy + 3 * c1.dy + 3 * c2.dy + end.dy) / 8,
      );
    case 'elbow':
      final p1 = horizontal
          ? Offset((start.dx + end.dx) / 2, start.dy)
          : Offset(start.dx, (start.dy + end.dy) / 2);
      final p2 = horizontal
          ? Offset((start.dx + end.dx) / 2, end.dy)
          : Offset(end.dx, (start.dy + end.dy) / 2);
      path
        ..lineTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..lineTo(end.dx, end.dy);
      startDir = _unit(start - (p1 == start ? p2 : p1));
      endDir = _unit(end - (p2 == end ? p1 : p2));
      mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    default:
      path.lineTo(end.dx, end.dy);
      startDir = _unit(start - end);
      endDir = _unit(end - start);
      mid = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
  }
  return ArrowShape(
    path: path,
    start: start,
    end: end,
    startDir: startDir,
    endDir: endDir,
    mid: mid,
  );
}

/// The smallest rect holding every one of [rects] (null when there are none).
Rect? boundsOf(Iterable<Rect> rects) {
  Rect? out;
  for (final r in rects) {
    out = out == null ? r : out.expandToInclude(r);
  }
  return out;
}

/// Simplifies a pen stroke: drops points closer than [min] to the last kept.
List<Offset> thinStroke(List<Offset> points, {double min = 3}) {
  if (points.length < 3) return points;
  final out = [points.first];
  for (var i = 1; i < points.length - 1; i++) {
    if ((points[i] - out.last).distance >= min) out.add(points[i]);
  }
  out.add(points.last);
  return out;
}

/// Distance from [p] to the polyline [points].
double distanceToPolyline(Offset p, List<Offset> points) {
  if (points.isEmpty) return double.infinity;
  if (points.length == 1) return (p - points.first).distance;
  var best = double.infinity;
  for (var i = 1; i < points.length; i++) {
    best = math.min(best, _segmentDistance(p, points[i - 1], points[i]));
  }
  return best;
}
