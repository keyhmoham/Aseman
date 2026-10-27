/// Distributions, parts, progress against targets and calendars: box plot,
/// bullet chart, segmented bar, radial bars (activity rings), sunburst,
/// calendar heatmap and word cloud.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../palette.dart';
import '../values.dart';
import 'cartesian_chart.dart' show ChartSelect;
import 'chart_frame.dart';
import 'viz_canvas.dart';

String? _s(Object? v) => v == null ? null : '$v';

double _quantile(List<double> sorted, double q) {
  if (sorted.isEmpty) return 0;
  final pos = (sorted.length - 1) * q;
  final i = pos.floor(), f = pos - i;
  return i + 1 < sorted.length ? sorted[i] + (sorted[i + 1] - sorted[i]) * f : sorted[i];
}

class _Box {
  _Box(this.label, this.min, this.q1, this.median, this.q3, this.max, this.outliers, this.row, this.color);
  final String label;
  final double min, q1, median, q3, max;
  final List<double> outliers;
  final Map<String, dynamic> row;
  final Color color;
}

/// Box plots: per row either raw samples (`values: [...]`, outliers past
/// 1.5 IQR shown as dots) or the five numbers (`min q1 median q3 max`).
class BoxPlotChart extends StatelessWidget {
  const BoxPlotChart({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data']);
    final lf = '${props['label'] ?? props['x'] ?? 'label'}';
    final format = _s(props['format'] ?? props['yFormat']);
    final height = asDouble(props['height'], 240).clamp(140, 800).toDouble();
    final boxes = <_Box>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final label = formatValue(field(r, lf) ?? '${i + 1}', null);
      final color = p.parse(r['color']) ?? (rows.length <= VizPalette.maxSeries && asBool(props['colorful']) ? p.series(i) : p.accent);
      final samples = [for (final v in asList(r['values'] ?? r['samples'])) asNum(v)?.toDouble()].whereType<double>().toList()..sort();
      if (samples.isNotEmpty) {
        final q1 = _quantile(samples, .25), q3 = _quantile(samples, .75), iqr = q3 - q1;
        final inside = samples.where((v) => v >= q1 - 1.5 * iqr && v <= q3 + 1.5 * iqr).toList();
        boxes.add(_Box(label, inside.first, q1, _quantile(samples, .5), q3, inside.last,
            samples.where((v) => v < q1 - 1.5 * iqr || v > q3 + 1.5 * iqr).toList(), r, color));
      } else {
        final n = [for (final k in ['min', 'q1', 'median', 'q3', 'max']) asNum(r[k])?.toDouble()];
        if (n.any((v) => v == null)) continue;
        boxes.add(_Box(label, n[0]!, n[1]!, n[2]!, n[3]!, n[4]!, [for (final v in asList(r['outliers'])) asNum(v)?.toDouble()].whereType<double>().toList(), r, color));
      }
    }
    if (boxes.isEmpty) return ChartFrame(title: _s(props['title']), child: NoData(height: height));
    final all = boxes.expand((b) => [b.min, b.max, ...b.outliers]);
    final ticks = niceTicks(all.reduce(math.min), all.reduce(math.max));
    Rect plotOf(Size s) => Rect.fromLTRB(44, 8, s.width - 4, s.height - 24);
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: VizCanvas(
        height: height,
        onSelect: onSelect,
        painter: (size, hover) => _BoxPainter(boxes, ticks, plotOf(size), p, hover, format),
        hitTest: (pos, size) {
          final plot = plotOf(size);
          final i = ((pos.dx - plot.left) / (plot.width / boxes.length)).floor();
          if (i < 0 || i >= boxes.length) return null;
          final b = boxes[i];
          String f(double v) => formatValue(v, format);
          return VizHit(i,
              header: b.label,
              items: [
                LegendItem('Max', b.color, value: f(b.max)),
                LegendItem('Q3', b.color, value: f(b.q3)),
                LegendItem('Median', b.color, value: f(b.median)),
                LegendItem('Q1', b.color, value: f(b.q1)),
                LegendItem('Min', b.color, value: f(b.min)),
                if (b.outliers.isNotEmpty) LegendItem('Outliers', p.other, value: '${b.outliers.length}'),
              ],
              detail: {'row': b.row, 'label': b.label, 'median': b.median, 'q1': b.q1, 'q3': b.q3, 'min': b.min, 'max': b.max});
        },
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.boxes, this.ticks, this.plot, this.p, this.hover, this.format);
  final List<_Box> boxes;
  final List<double> ticks;
  final Rect plot;
  final VizPalette p;
  final int? hover;
  final String? format;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = ticks.first, hi = ticks.last == ticks.first ? ticks.first + 1 : ticks.last;
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
    for (final t in ticks) {
      canvas.drawLine(Offset(plot.left, y(t)), Offset(plot.right, y(t)), Paint()..color = p.grid);
      paintText(canvas, formatValue(t, format ?? 'compact'), Offset(plot.left - 6, y(t)), VizText.label(p), align: 1, valign: 0);
    }
    final band = plot.width / boxes.length;
    final w = math.min(48.0, band * 0.5);
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      final cx = plot.left + band * (i + .5);
      if (hover == i) canvas.drawRect(Rect.fromLTRB(plot.left + band * i, plot.top, plot.left + band * (i + 1), plot.bottom), Paint()..color = p.hover);
      final line = Paint()..color = b.color..strokeWidth = 2..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(cx, y(b.max)), Offset(cx, y(b.q3)), line);
      canvas.drawLine(Offset(cx, y(b.q1)), Offset(cx, y(b.min)), line);
      canvas.drawLine(Offset(cx - w / 4, y(b.max)), Offset(cx + w / 4, y(b.max)), line);
      canvas.drawLine(Offset(cx - w / 4, y(b.min)), Offset(cx + w / 4, y(b.min)), line);
      final box = RRect.fromRectAndRadius(Rect.fromLTRB(cx - w / 2, y(b.q3), cx + w / 2, y(b.q1)), const Radius.circular(8));
      canvas.drawRRect(box, Paint()..color = p.tonal(b.color, 1.8));
      canvas.drawRRect(box, Paint()..color = b.color..style = PaintingStyle.stroke..strokeWidth = 2);
      canvas.drawLine(Offset(cx - w / 2, y(b.median)), Offset(cx + w / 2, y(b.median)), Paint()..color = p.onTonal(b.color)..strokeWidth = 3);
      for (final o in b.outliers) {
        canvas.drawCircle(Offset(cx, y(o)), 3.5, Paint()..color = b.color..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
      paintText(canvas, b.label, Offset(cx, plot.bottom + 6), VizText.label(p), align: 0, maxWidth: band - 2);
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.hover != hover || old.boxes != boxes || old.plot != plot;
}

/// Bullet charts: a value against a target over qualitative ranges, one
/// row per item (`items: [{label, value, target, ranges, max}]`, or the
/// same props for a single bullet).
class BulletChart extends StatelessWidget {
  const BulletChart({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final items = props['items'] is List ? asRows(props['items']) : [props];
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final it in items) ...[
            _bullet(p, it, _s(it['format'] ?? props['format'])),
            const SizedBox(height: 14),
          ],
        ]..removeLast(),
      ),
    );
  }

  Widget _bullet(VizPalette p, Map<String, dynamic> it, String? format) {
    final value = asDouble(it['value'], 0);
    final target = asNum(it['target'])?.toDouble();
    final ranges = [for (final r in asList(it['ranges'])) asNum(r)?.toDouble()].whereType<double>().toList()..sort();
    final max = asNum(it['max'])?.toDouble() ?? [value, target ?? 0, ...ranges].reduce(math.max) * 1.08;
    final color = p.parse(it['color'] ?? it['status']) ?? p.accent;
    final met = target == null || value >= target;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(child: Text(asText(it['label']), overflow: TextOverflow.ellipsis, style: VizText.title(p).copyWith(fontSize: 14))),
        Text(formatValue(value, format), style: VizText.value(p).copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
        if (target != null) Text('  / ${formatValue(target, format)}', style: VizText.subtitle(p)),
        if (target != null) ...[
          const SizedBox(width: 6),
          Icon(met ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 16, color: met ? VizPalette.good : p.textMuted),
        ],
      ]),
      const SizedBox(height: 6),
      SizedBox(
        height: 22,
        child: LayoutBuilder(builder: (context, box) {
          final w = widthIn(box, 240);
          double x(double v) => (v / (max <= 0 ? 1 : max)).clamp(0.0, 1.0) * w;
          return SizedBox(
            width: w,
            child: Stack(clipBehavior: Clip.none, children: [
              // Ranges, darkest first so lighter bands sit on top of their start.
              Positioned.fill(child: Container(decoration: BoxDecoration(color: p.neutral, borderRadius: BorderRadius.circular(11)))),
              for (var k = ranges.length - 1; k >= 0; k--)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: x(ranges[k]),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Color.lerp(p.neutral, p.textMuted, 0.18 + 0.16 * (ranges.length - 1 - k)),
                      borderRadius: BorderRadius.circular(11),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                top: 6,
                bottom: 6,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: x(value)),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => Container(width: v, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5))),
                ),
              ),
              if (target != null)
                Positioned(
                  left: x(target) - 2,
                  top: -3,
                  bottom: -3,
                  child: Container(width: 4, decoration: BoxDecoration(color: p.textPrimary, borderRadius: BorderRadius.circular(2))),
                ),
            ]),
          );
        }),
      ),
    ]);
  }
}

/// One bar split into parts (a distribution): rounded, 2px gaps, the
/// categorical colors, and a legend with each part's value and share.
class SegmentedBar extends StatelessWidget {
  const SegmentedBar({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data'] ?? props['values']);
    final lf = '${props['label'] ?? 'label'}', vf = '${props['value'] ?? 'value'}';
    final format = _s(props['format']);
    final parts = <(int, String, double, Color)>[];
    for (var i = 0; i < rows.length; i++) {
      final v = asNum(field(rows[i], vf))?.toDouble() ?? 0;
      if (v <= 0) continue;
      parts.add((i, formatValue(field(rows[i], lf) ?? '${i + 1}', null), v, p.parse(rows[i]['color'] ?? rows[i]['status']) ?? p.series(parts.length)));
    }
    final total = parts.fold<double>(0, (s, x) => s + x.$3);
    final thickness = asDouble(props['thickness'], 14);
    if (total <= 0) return ChartFrame(title: _s(props['title']), child: const NoData(height: 40));
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        LayoutBuilder(builder: (context, box) {
          final w = widthIn(box, 280);
          final gaps = 3.0 * (parts.length - 1);
          return SizedBox(
            width: w,
            height: thickness,
            child: Row(children: [
              for (final (n, part) in parts.indexed) ...[
                if (n > 0) const SizedBox(width: 3),
                GestureDetector(
                  onTap: onSelect == null ? null : () => onSelect!({'index': part.$1, 'row': rows[part.$1], 'label': part.$2, 'value': part.$3}),
                  child: Tooltip(
                    message: '${part.$2}: ${formatValue(part.$3, format)} (${formatValue(part.$3 / total, 'percent:0')})',
                    child: Container(
                      width: math.max(3, (w - gaps) * part.$3 / total),
                      decoration: BoxDecoration(
                        color: part.$4,
                        borderRadius: BorderRadius.horizontal(
                          left: Radius.circular(n == 0 ? thickness / 2 : 3),
                          right: Radius.circular(n == parts.length - 1 ? thickness / 2 : 3),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ]),
          );
        }),
        if (asBool(props['legend'], true)) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 16, runSpacing: 6, children: [
            for (final part in parts)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Swatch(color: part.$4),
                const SizedBox(width: 6),
                Text(part.$2, style: VizText.label(p).copyWith(fontSize: 12)),
                const SizedBox(width: 6),
                Text(asBool(props['showPercent'], true) ? formatValue(part.$3 / total, 'percent:0') : formatValue(part.$3, format), style: VizText.value(p)),
              ]),
          ]),
        ],
      ]),
    );
  }
}

/// Concentric progress rings (activity rings): one ring per row (`value`
/// of `max`, default 100), with an optional center figure and a legend.
class RadialBars extends StatelessWidget {
  const RadialBars({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data'] ?? props['values']);
    final size = asDouble(props['size'], 160).clamp(80, 480).toDouble();
    final format = _s(props['format']);
    final rings = [
      for (var i = 0; i < rows.length && i < 6; i++)
        (
          asText(rows[i]['label'] ?? rows[i]['name']),
          asDouble(rows[i]['value'], 0),
          asDouble(rows[i]['max'] ?? props['max'], 100),
          p.parse(rows[i]['color']) ?? (i == 0 ? p.accent : p.series(i)),
        )
    ];
    if (rings.isEmpty) return const NoData();
    final chart = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingsPainter(rings, t, p),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (props['centerLabel'] != null)
                Text(asText(props['centerLabel']), style: VizText.value(p).copyWith(fontSize: size / 7, fontWeight: FontWeight.w700)),
              if (props['centerCaption'] != null) Text(asText(props['centerCaption']), style: VizText.label(p)),
            ]),
          ),
        ),
      ),
    );
    final legend = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (final r in rings)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Swatch(color: r.$4),
            const SizedBox(width: 8),
            Text(r.$1, style: VizText.label(p).copyWith(fontSize: 13)),
            const SizedBox(width: 8),
            Text(format != null ? formatValue(r.$2, format) : '${formatValue(r.$2, null)} / ${formatValue(r.$3, null)}', style: VizText.value(p)),
          ]),
        ),
    ]);
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: asBool(props['legend'], true)
          ? Wrap(spacing: 20, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [chart, legend])
          : chart,
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.rings, this.t, this.p);
  final List<(String, double, double, Color)> rings;
  final double t;
  final VizPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final thick = math.min(outer / (rings.length * 1.45 + 0.6), outer * 0.22);
    for (var i = 0; i < rings.length; i++) {
      final r = outer - thick / 2 - i * thick * 1.25;
      final ring = rings[i];
      final rect = Rect.fromCircle(center: c, radius: r);
      final track = Paint()..color = p.tonal(ring.$4, 1.4)..style = PaintingStyle.stroke..strokeWidth = thick;
      canvas.drawCircle(c, r, track);
      final frac = (ring.$3 <= 0 ? 0.0 : ring.$2 / ring.$3) * t;
      if (frac <= 0) continue;
      final arc = Paint()..color = ring.$4..style = PaintingStyle.stroke..strokeWidth = thick..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * math.min(frac, 0.999), false, arc);
      if (frac > 1) {
        // Past the goal: the overlap laps around again, slightly darker.
        canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * math.min(frac - 1, 0.999), false, arc..color = p.onTonal(ring.$4));
      }
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.t != t || old.rings != rings;
}

class _Arc {
  _Arc(this.label, this.value, this.depth, this.a0, this.a1, this.color, this.path, this.node);
  final String label;
  final double value;
  final int depth;
  final double a0, a1;
  final Color color;
  final List<String> path;
  final Map<String, dynamic> node;
}

/// A sunburst: a hierarchy (`{label, value, children}`) as rings, the
/// root's children inside, each arc as wide as its value (leaves' values
/// sum up).
class SunburstChart extends StatelessWidget {
  const SunburstChart({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  static double _total(Object? n) {
    final m = asMap(n);
    final kids = asList(m['children']);
    if (kids.isEmpty) return math.max(0, asDouble(m['value'], 0));
    return kids.fold<double>(0, (s, k) => s + _total(k));
  }

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final data = props['data'];
    final roots = data is List ? data : asList(asMap(data)['children'] ?? data);
    final size = asDouble(props['size'] ?? props['height'], 260).clamp(120, 600).toDouble();
    final format = _s(props['format']);
    final arcs = <_Arc>[];
    var depthMax = 0;
    void place(List<Object?> nodes, double a0, double a1, int depth, Color? parent, List<String> path) {
      final sum = nodes.fold<double>(0, (s, n) => s + _total(n));
      if (sum <= 0) return;
      var a = a0;
      for (var i = 0; i < nodes.length; i++) {
        final m = asMap(nodes[i]);
        final v = _total(m);
        if (v <= 0) continue;
        final span = (a1 - a0) * v / sum;
        final color = p.parse(m['color']) ??
            (parent == null ? p.series(i % VizPalette.maxSeries) : Color.lerp(parent, p.surface, 0.18 + 0.12 * (i % 3))!);
        final label = asText(m['label'] ?? m['name']);
        arcs.add(_Arc(label, v, depth, a, a + span, color, [...path, label], m));
        depthMax = math.max(depthMax, depth);
        place(asList(m['children']), a, a + span, depth + 1, color, [...path, label]);
        a += span;
      }
    }

    place(roots, 0, 2 * math.pi, 0, null, const []);
    if (arcs.isEmpty) return ChartFrame(title: _s(props['title']), child: NoData(height: size));
    final total = roots.fold<double>(0, (s, n) => s + _total(n));
    final hole = 0.28;
    double ringW(Size s) => (s.shortestSide / 2 * (1 - hole)) / (depthMax + 1);
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: Center(
        child: VizCanvas(
          height: size,
          fallbackWidth: size,
          onSelect: onSelect,
          painter: (s, hover) => _SunPainter(arcs, hole, ringW(s), p, hover, formatValue(total, format ?? 'compact'), asText(props['centerCaption'] ?? 'Total')),
          hitTest: (pos, s) {
            final c = s.center(Offset.zero);
            final d = pos - c;
            final inner = s.shortestSide / 2 * hole;
            final depth = ((d.distance - inner) / ringW(s)).floor();
            if (depth < 0) return null;
            var a = math.atan2(d.dy, d.dx) + math.pi / 2;
            if (a < 0) a += 2 * math.pi;
            for (var i = 0; i < arcs.length; i++) {
              final arc = arcs[i];
              if (arc.depth == depth && a >= arc.a0 && a < arc.a1) {
                return VizHit(i,
                    header: arc.path.join(' › '),
                    items: [LegendItem(formatValue(arc.value / total, 'percent:1'), arc.color, value: formatValue(arc.value, format))],
                    detail: {'label': arc.label, 'path': arc.path, 'value': arc.value, 'node': {for (final e in arc.node.entries) if (e.key != 'children') e.key: e.value}});
              }
            }
            return null;
          },
        ),
      ),
    );
  }
}

class _SunPainter extends CustomPainter {
  _SunPainter(this.arcs, this.hole, this.ringW, this.p, this.hover, this.center, this.caption);
  final List<_Arc> arcs;
  final double hole, ringW;
  final VizPalette p;
  final int? hover;
  final String center, caption;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final inner = size.shortestSide / 2 * hole;
    final hovered = hover == null ? null : arcs[hover!];
    for (var i = 0; i < arcs.length; i++) {
      final a = arcs[i];
      final r0 = inner + a.depth * ringW + 1.5, r1 = inner + (a.depth + 1) * ringW - 1.5;
      final gap = math.min(0.012, (a.a1 - a.a0) / 4);
      final s0 = a.a0 - math.pi / 2 + gap, s1 = a.a1 - math.pi / 2 - gap;
      final path = Path()
        ..arcTo(Rect.fromCircle(center: c, radius: r1), s0, s1 - s0, true)
        ..arcTo(Rect.fromCircle(center: c, radius: r0), s1, s0 - s1, false)
        ..close();
      final lit = hovered == null || (hovered.path.length <= a.path.length && a.path.take(hovered.path.length).join('\u0000') == hovered.path.join('\u0000'));
      canvas.drawPath(path, Paint()..color = a.color.withValues(alpha: lit ? 1 : 0.35));
    }
    paintText(canvas, center, c.translate(0, -2), VizText.value(p).copyWith(fontSize: math.max(12, inner / 2.6), fontWeight: FontWeight.w700), align: 0, valign: 1);
    paintText(canvas, caption, c.translate(0, 2), VizText.label(p), align: 0, valign: -1);
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.hover != hover || old.arcs != arcs;
}

/// A calendar heatmap (contribution graph): one cell per day, columns are
/// weeks, darker for more; month and weekday labels and a less–more scale.
class CalendarHeatmap extends StatelessWidget {
  const CalendarHeatmap({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data']);
    final df = '${props['date'] ?? 'date'}', vf = '${props['value'] ?? 'value'}';
    final format = _s(props['format']);
    final byDay = <String, (double, Map<String, dynamic>)>{};
    DateTime? last;
    for (final r in rows) {
      final d = asTime(field(r, df));
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      byDay[dayKey(day)] = ((byDay[dayKey(day)]?.$1 ?? 0) + asDouble(field(r, vf), 1), r);
      if (last == null || day.isAfter(last)) last = day;
    }
    final endProp = asTime(props['end']);
    final end = endProp != null ? DateTime(endProp.year, endProp.month, endProp.day) : (last ?? DateTime.now());
    final weeks = asInt(props['weeks'], 26).clamp(4, 53);
    // Columns start on Monday.
    final endWeekStart = end.subtract(Duration(days: end.weekday - 1));
    final start = endWeekStart.subtract(Duration(days: 7 * (weeks - 1)));
    final maxV = byDay.values.fold<double>(0, (m, v) => math.max(m, v.$1));
    final color = p.parse(props['color']) ?? p.accent;
    Color shade(double v) {
      if (v <= 0) return p.neutral;
      final t = maxV <= 0 ? 1.0 : (v / maxV);
      final step = (t * 4).ceil().clamp(1, 4);
      return Color.lerp(p.tonal(color, 1.6), color, (step - 1) / 3)!;
    }

    const labelW = 28.0, labelH = 16.0;
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        LayoutBuilder(builder: (context, box) {
          final w = widthIn(box, weeks * 16.0 + labelW);
          final cell = ((w - labelW) / weeks).clamp(8.0, 22.0);
          final size = Size(labelW + cell * weeks, labelH + cell * 7);
          (int, int)? cellAt(Offset pos) {
            final c = ((pos.dx - labelW) / cell).floor(), r = ((pos.dy - labelH) / cell).floor();
            if (c < 0 || c >= weeks || r < 0 || r > 6) return null;
            return (c, r);
          }

          DateTime dayOf((int, int) cr) => start.add(Duration(days: cr.$1 * 7 + cr.$2));
          return Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: size.width,
              child: VizCanvas(
                height: size.height,
                fallbackWidth: size.width,
                onSelect: onSelect,
                painter: (s, hover) => _CalHeatPainter(start, end, weeks, cell, labelW, labelH, byDay, shade, p, hover),
                hitTest: (pos, s) {
                  final cr = cellAt(pos);
                  if (cr == null) return null;
                  final d = dayOf(cr);
                  if (d.isAfter(end)) return null;
                  final v = byDay[dayKey(d)];
                  return VizHit(cr.$1 * 7 + cr.$2,
                      header: formatValue(d.toIso8601String(), 'date'),
                      items: [LegendItem('Value', shade(v?.$1 ?? 0), value: formatValue(v?.$1 ?? 0, format))],
                      detail: {'date': dayKey(d), 'value': v?.$1 ?? 0, if (v != null) 'row': v.$2});
                },
              ),
            ),
          );
        }),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Less', style: VizText.label(p)),
          const SizedBox(width: 6),
          for (final v in [0.0, .25, .5, .75, 1.0])
            Container(width: 11, height: 11, margin: const EdgeInsets.only(right: 3), decoration: BoxDecoration(color: shade(v * maxV + (v == 0 ? 0 : 1e-9)), borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 3),
          Text('More', style: VizText.label(p)),
        ]),
      ]),
    );
  }
}

class _CalHeatPainter extends CustomPainter {
  _CalHeatPainter(this.start, this.end, this.weeks, this.cell, this.labelW, this.labelH, this.byDay, this.shade, this.p, this.hover);
  final DateTime start, end;
  final int weeks;
  final double cell, labelW, labelH;
  final Map<String, (double, Map<String, dynamic>)> byDay;
  final Color Function(double) shade;
  final VizPalette p;
  final int? hover;

  @override
  void paint(Canvas canvas, Size size) {
    final style = VizText.label(p).copyWith(fontSize: 10);
    for (final (r, l) in [(0, 'Mon'), (2, 'Wed'), (4, 'Fri')]) {
      paintText(canvas, l, Offset(0, labelH + cell * (r + .5)), style, valign: 0);
    }
    var lastMonth = -1;
    final radius = Radius.circular(math.max(2, cell * 0.22));
    for (var c = 0; c < weeks; c++) {
      final weekStart = start.add(Duration(days: c * 7));
      if (weekStart.month != lastMonth) {
        if (c < weeks - 1 || lastMonth == -1) paintText(canvas, monthNames[weekStart.month - 1].substring(0, 3), Offset(labelW + c * cell, 0), style);
        lastMonth = weekStart.month;
      }
      for (var r = 0; r < 7; r++) {
        final d = weekStart.add(Duration(days: r));
        if (d.isAfter(end)) continue;
        final rect = Rect.fromLTWH(labelW + c * cell + 1.5, labelH + r * cell + 1.5, cell - 3, cell - 3);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), Paint()..color = shade(byDay[dayKey(d)]?.$1 ?? 0));
        if (hover == c * 7 + r) canvas.drawRRect(RRect.fromRectAndRadius(rect.inflate(1), radius), Paint()..color = p.textPrimary..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }
    }
  }

  @override
  bool shouldRepaint(_CalHeatPainter old) => old.hover != hover || old.byDay != byDay || old.cell != cell;
}

class _Word {
  _Word(this.text, this.value, this.row, this.index);
  final String text;
  final double value;
  final Map<String, dynamic> row;
  final int index;
  Rect rect = Rect.zero;
  double size = 12;
  Color color = Colors.black;
}

/// A word cloud: words sized by weight, placed on a spiral from the center
/// without overlapping.
class WordCloud extends StatelessWidget {
  const WordCloud({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data'] ?? props['words']);
    final tf = '${props['label'] ?? props['text'] ?? 'text'}', vf = '${props['value'] ?? 'value'}';
    final height = asDouble(props['height'], 220).clamp(100, 800).toDouble();
    final words = <_Word>[];
    for (var i = 0; i < rows.length; i++) {
      final t = asText(field(rows[i], tf) ?? rows[i]['label'] ?? rows[i]['word']);
      if (t.isEmpty) continue;
      words.add(_Word(t, asDouble(field(rows[i], vf) ?? rows[i]['weight'], 1), rows[i], i));
    }
    words.sort((a, b) => b.value.compareTo(a.value));
    final shown = words.take(asInt(props['max'], 60)).toList();
    if (shown.isEmpty) return ChartFrame(title: _s(props['title']), child: NoData(height: height));
    final hi = shown.first.value, lo = shown.last.value;
    final colorful = asBool(props['colorful'], true);
    Size? laid;
    void layout(Size s) {
      if (laid == s) return;
      laid = s;
      final placed = <Rect>[];
      final minF = asDouble(props['minSize'], 12), maxF = asDouble(props['maxSize'], math.min(44, s.width / 7));
      for (final (i, w) in shown.indexed) {
        final t = hi == lo ? 1.0 : math.sqrt((w.value - lo) / (hi - lo));
        w.size = minF + (maxF - minF) * t;
        w.color = colorful ? p.series(i % VizPalette.maxSeries) : Color.lerp(p.textMuted, p.accent, t)!;
        final m = measureText(w.text, TextStyle(fontSize: w.size, fontWeight: FontWeight.w700));
        w.rect = Rect.zero;
        for (var k = 0; k < 900; k++) {
          final a = k * 0.35, r = 2.2 * a;
          final c = Offset(s.width / 2 + r * math.cos(a) * 1.6, s.height / 2 + r * math.sin(a));
          final rect = Rect.fromCenter(center: c, width: m.width + 6, height: m.height);
          if (rect.left < 0 || rect.right > s.width || rect.top < 0 || rect.bottom > s.height) continue;
          if (placed.any((o) => o.overlaps(rect))) continue;
          w.rect = rect;
          placed.add(rect);
          break;
        }
      }
    }

    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: VizCanvas(
        height: height,
        onSelect: onSelect,
        painter: (s, hover) {
          layout(s);
          return _CloudPainter(shown, hover, p);
        },
        hitTest: (pos, s) {
          layout(s);
          for (var i = 0; i < shown.length; i++) {
            if (shown[i].rect != Rect.zero && shown[i].rect.contains(pos)) {
              return VizHit(i, header: shown[i].text, items: [LegendItem('Weight', shown[i].color, value: formatValue(shown[i].value, null))], detail: {'text': shown[i].text, 'value': shown[i].value, 'row': shown[i].row});
            }
          }
          return null;
        },
      ),
    );
  }
}

class _CloudPainter extends CustomPainter {
  _CloudPainter(this.words, this.hover, this.p);
  final List<_Word> words;
  final int? hover;
  final VizPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      if (w.rect == Rect.zero) continue;
      paintText(canvas, w.text, w.rect.center,
          p.font(TextStyle(fontSize: w.size, fontWeight: FontWeight.w700, color: hover == null || hover == i ? w.color : w.color.withValues(alpha: 0.35))),
          align: 0, valign: 0);
    }
  }

  @override
  bool shouldRepaint(_CloudPainter old) => old.hover != hover || old.words != words;
}
