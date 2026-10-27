/// Part-to-whole and radial charts: pie / donut, radar, and the gauge.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../elpian/core/lenient.dart';
import '../palette.dart';
import '../values.dart';
import 'cartesian_chart.dart' show ChartSelect;
import 'chart_frame.dart';

class _Slice {
  _Slice(this.label, this.value, this.color, this.index);
  final String label;
  final double value;
  final Color color;

  /// The row index (-1 for the folded "Other").
  final int index;
}

/// Pie and donut: slices in data order, past eight folded into "Other",
/// separated by a 2px gap; the legend carries each slice's value and share.
class PieChart extends StatefulWidget {
  const PieChart({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  State<PieChart> createState() => _PieChartState();
}

class _PieChartState extends State<PieChart> {
  int? _hover;
  Offset? _pointer;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final props = widget.props;
    final rows = asRows(props['data'] ?? props['values']);
    final labelField = '${props['label'] ?? props['x'] ?? 'label'}';
    final valueField = '${props['value'] ?? props['y'] ?? 'value'}';
    final format = looseStr(props['format'] ?? props['yFormat']);
    final donut = props['type'] == 'donut' || asBool(props['donut']);
    final height = asDouble(props['height'], 220).clamp(120, 800).toDouble();

    final slices = <_Slice>[];
    var other = 0.0;
    for (var i = 0; i < rows.length; i++) {
      final v = asNum(field(rows[i], valueField))?.toDouble();
      if (v == null || v <= 0) continue;
      final label = formatValue(field(rows[i], labelField) ?? '${i + 1}', null);
      if (slices.length < VizPalette.maxSeries - 1 ||
          (slices.length == VizPalette.maxSeries - 1 &&
              rows.length == VizPalette.maxSeries)) {
        final color = p.parse(field(rows[i], 'color'), index: slices.length) ??
            p.series(slices.length);
        slices.add(_Slice(label, v, color, i));
      } else {
        other += v;
      }
    }
    if (other > 0) slices.add(_Slice('Other', other, p.other, -1));
    final total = slices.fold<double>(0, (s, x) => s + x.value);
    if (slices.isEmpty || total <= 0) {
      return ChartFrame(
          title: looseStr(props['title']),
          subtitle: looseStr(props['subtitle']),
          child: NoData(height: height));
    }
    String share(double v) =>
        '${formatNumber(v / total * 100, decimals: v / total < 0.1 ? 1 : 0)}%';

    final chart = SizedBox(
      height: height,
      child: LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, height);
        final center = size.center(Offset.zero);
        final radius = math.min(size.width, size.height) / 2 - 6;
        int? hitAt(Offset pos) {
          final d = pos - center;
          final r = d.distance;
          if (r > radius + 4 || (donut && r < radius * 0.6)) return null;
          var a = math.atan2(d.dy, d.dx) + math.pi / 2;
          if (a < 0) a += 2 * math.pi;
          var acc = 0.0;
          for (var i = 0; i < slices.length; i++) {
            acc += slices[i].value / total * 2 * math.pi;
            if (a <= acc) return i;
          }
          return null;
        }

        void move(Offset pos) => setState(() {
              _pointer = pos;
              _hover = hitAt(pos);
            });
        final hover = _hover != null && _hover! < slices.length ? _hover : null;
        return MouseRegion(
          onHover: (e) => move(e.localPosition),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              move(d.localPosition);
              final i = hitAt(d.localPosition);
              if (i != null && slices[i].index >= 0) {
                widget.onSelect?.call({
                  'index': slices[i].index,
                  'row': rows[slices[i].index],
                  'label': slices[i].label,
                  'value': slices[i].value,
                });
              }
            },
            child: Stack(children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _PiePainter(slices, total, donut, hover, p,
                      center: donut
                          ? (looseStr(props['centerLabel']) ??
                              formatValue(total, format))
                          : null,
                      centerCaption: donut
                          ? (looseStr(props['centerCaption']) ?? 'Total')
                          : null),
                ),
              ),
              if (hover != null && _pointer != null)
                Positioned.fill(
                  child: CustomSingleChildLayout(
                    delegate: TooltipLayout(_pointer!),
                    child: ChartTooltip(header: slices[hover].label, items: [
                      LegendItem(
                          share(slices[hover].value), slices[hover].color,
                          value: formatValue(slices[hover].value, format)),
                    ]),
                  ),
                ),
            ]),
          ),
        );
      }),
    );
    return ChartFrame(
      title: looseStr(props['title']),
      subtitle: looseStr(props['subtitle']),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          chart,
          const SizedBox(height: 10),
          Legend(items: [
            for (final s in slices)
              LegendItem(s.label, s.color,
                  value: formatValue(s.value, format) == share(s.value)
                      ? share(s.value)
                      : '${formatValue(s.value, format)} · ${share(s.value)}'),
          ]),
        ],
      ),
    );
  }
}

class _PiePainter extends CustomPainter {
  _PiePainter(this.slices, this.total, this.donut, this.hover, this.p,
      {this.center, this.centerCaption});
  final List<_Slice> slices;
  final double total;
  final bool donut;
  final int? hover;
  final VizPalette p;
  final String? center;
  final String? centerCaption;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 6;
    var start = -math.pi / 2;
    final gap = Paint()
      ..color = p.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i].value / total * 2 * math.pi;
      final r = radius + (hover == i ? 4 : 0);
      final rect = Rect.fromCircle(center: c, radius: r);
      final color = hover == null || hover == i
          ? slices[i].color
          : slices[i].color.withValues(alpha: 0.55);
      if (donut) {
        final thickness = r * 0.4;
        canvas.drawArc(
            Rect.fromCircle(center: c, radius: r - thickness / 2),
            start,
            sweep,
            false,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = thickness);
      } else {
        canvas.drawArc(rect, start, sweep, true, Paint()..color = color);
      }
      // The 2px separating gap along the slice's leading edge.
      if (slices.length > 1) {
        canvas.drawLine(
            c +
                Offset(math.cos(start), math.sin(start)) *
                    (donut ? r * 0.6 : 0),
            c + Offset(math.cos(start), math.sin(start)) * (r + 1),
            gap);
      }
      start += sweep;
    }
    if (donut && center != null) {
      final big = p.font(TextStyle(
          fontSize: math.max(14, radius * 0.22),
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
          fontFeatures: const [FontFeature.tabularFigures()]));
      paintText(canvas, center!, c, big,
          align: 0,
          valign: centerCaption == null ? 0 : 1,
          maxWidth: radius * 1.1);
      if (centerCaption != null) {
        paintText(
            canvas, centerCaption!, c + const Offset(0, 2), VizText.label(p),
            align: 0, maxWidth: radius * 1.1);
      }
    }
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.hover != hover || old.slices != slices || old.p.dark != p.dark;
}

/// Radar: one polygon per series over the categories (axes).
class RadarChart extends StatefulWidget {
  const RadarChart({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  State<RadarChart> createState() => _RadarChartState();
}

class _RadarChartState extends State<RadarChart> {
  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final props = widget.props;
    final rows = asRows(props['data']);
    final axisField = '${props['x'] ?? props['label'] ?? 'label'}';
    final series = <(String, String, Color)>[];
    final spec = props['series'] ?? props['y'];
    for (final s in spec is List ? spec : [spec ?? 'value']) {
      if (series.length >= VizPalette.maxSeries) break;
      final m = s is Map ? asMap(s) : {'field': s};
      final f = '${m['field'] ?? m['key'] ?? ''}';
      if (f.isEmpty) continue;
      series.add((
        f,
        '${m['label'] ?? f}',
        p.parse(m['color']) ?? p.series(series.length)
      ));
    }
    final height = asDouble(props['height'], 260).clamp(140, 800).toDouble();
    if (rows.length < 3 || series.isEmpty) {
      return ChartFrame(
          title: looseStr(props['title']),
          child:
              NoData(height: height, text: 'A radar needs three or more axes'));
    }
    var max = asNum(props['max'])?.toDouble() ?? 0;
    if (props['max'] == null) {
      for (final r in rows) {
        for (final s in series) {
          max = math.max(max, asNum(field(r, s.$1))?.toDouble() ?? 0);
        }
      }
      max = niceTicks(0, max).last;
    }
    return ChartFrame(
      title: looseStr(props['title']),
      subtitle: looseStr(props['subtitle']),
      legend: series.length > 1
          ? [for (final s in series) LegendItem(s.$2, s.$3, line: true)]
          : const [],
      child: SizedBox(
        height: height,
        child: CustomPaint(
          size: Size.infinite,
          painter: _RadarPainter([
            for (final r in rows) formatValue(field(r, axisField), null)
          ], [
            for (final s in series)
              (
                s.$3,
                [for (final r in rows) asNum(field(r, s.$1))?.toDouble() ?? 0]
              )
          ], max <= 0 ? 1 : max, p),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.axes, this.series, this.max, this.p);
  final List<String> axes;
  final List<(Color, List<double>)> series;
  final double max;
  final VizPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final label = VizText.label(p);
    final c = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 28;
    final n = axes.length;
    Offset at(int i, double t) {
      final a = -math.pi / 2 + 2 * math.pi * i / n;
      return c + Offset(math.cos(a), math.sin(a)) * radius * t;
    }

    final grid = Paint()
      ..color = p.grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var ring = 1; ring <= 4; ring++) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final o = at(i, ring / 4);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path..close(), grid);
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(c, at(i, 1), grid);
      final o = at(i, 1.12);
      final dx = (o.dx - c.dx).abs() < 4 ? 0.0 : (o.dx > c.dx ? -1.0 : 1.0);
      paintText(canvas, axes[i], o, label, align: dx, valign: 0, maxWidth: 90);
    }
    for (final (color, values) in series) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final o = at(i, (values[i] / max).clamp(0, 1));
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.12));
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => true;
}

/// A small inline trend: a line (or bars) with the latest value accented.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color,
    this.height = 32,
    this.width,
    this.bars = false,
    this.area = false,
  });

  factory Sparkline.fromProps(Map<String, dynamic> props, VizPalette p) {
    final f = looseStr(props['field']);
    final values = [
      for (final v in asList(props['values'] ?? props['data']))
        asNum(f != null ? field(v, f) : (v is Map ? (v['value'] ?? v['y']) : v))
            ?.toDouble()
    ];
    return Sparkline(
      values: values,
      color: p.parse(props['color']),
      height: asSize(props['height'], 32),
      width: asSizeOrNull(props['width']),
      bars: props['type'] == 'bar',
      area: props['type'] == 'area' || asBool(props['area']),
    );
  }

  final List<double?> values;
  final Color? color;
  final double height;
  final double? width;
  final bool bars;
  final bool area;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    return LayoutBuilder(builder: (context, box) {
      final w = width ?? (box.maxWidth.isFinite ? box.maxWidth : 96.0);
      return SizedBox(
        height: height,
        width: w,
        child: CustomPaint(
          painter: _SparkPainter(values, color ?? p.accent, bars, area, p),
        ),
      );
    });
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color, this.bars, this.area, this.p);
  final List<double?> values;
  final Color color;
  final bool bars;
  final bool area;
  final VizPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final vs = values.whereType<double>().toList();
    if (vs.isEmpty) return;
    var lo = vs.reduce(math.min), hi = vs.reduce(math.max);
    if (bars) lo = math.min(lo, 0);
    if (hi == lo) hi = lo + 1;
    const pad = 4.0;
    final h = size.height - pad * 2;
    double y(double v) => pad + h - (v - lo) / (hi - lo) * h;
    final n = values.length;
    if (bars) {
      final band = size.width / n;
      final w = math.max(1.0, math.min(8.0, band - 2));
      for (var i = 0; i < n; i++) {
        final v = values[i];
        if (v == null) continue;
        final x = band * (i + 0.5);
        final r = Rect.fromLTRB(
            x - w / 2, math.min(y(v), y(0)), x + w / 2, math.max(y(v), y(0)));
        canvas.drawRRect(
            barRect(r, vertical: true, positive: v >= 0),
            Paint()
              ..color = i == n - 1 ? color : color.withValues(alpha: 0.45));
      }
      return;
    }
    final step = n <= 1 ? 0.0 : (size.width - pad * 2) / (n - 1);
    final path = Path();
    Offset? last;
    Offset? first;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null) continue;
      final o = Offset(pad + step * i, y(v));
      if (last == null) {
        path.moveTo(o.dx, o.dy);
        first = o;
      } else {
        path.lineTo(o.dx, o.dy);
      }
      last = o;
    }
    if (area && first != null && last != null) {
      final fill = Path.from(path)
        ..lineTo(last.dx, size.height)
        ..lineTo(first.dx, size.height)
        ..close();
      canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.12));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
    if (last != null) {
      canvas.drawCircle(last, 3, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color;
}

/// A gauge: a 240° arc whose fill carries severity; the track is a lighter
/// step of the same color.
class Gauge extends StatelessWidget {
  const Gauge({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final value = asNum(props['value'])?.toDouble() ?? 0;
    final min = asNum(props['min'])?.toDouble() ?? 0;
    final max = asNum(props['max'])?.toDouble() ?? 100;
    final format = looseStr(props['format']);
    // Thresholds: [{value, status|color}] — the fill takes the color of the
    // highest threshold the value reaches.
    Color fill = p.parse(props['color']) ?? p.accent;
    for (final t in asList(props['thresholds'])) {
      final m = asMap(t);
      final at = asNum(m['value'])?.toDouble();
      if (at != null && value >= at) {
        fill = p.parse(m['color'] ?? m['status']) ?? fill;
      }
    }
    final size = asDouble(props['size'], 160).clamp(80, 480).toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size * 0.82,
          child: CustomPaint(
            painter: _GaugePainter(
              t: max == min ? 0 : ((value - min) / (max - min)).clamp(0, 1),
              fill: fill,
              p: p,
              value: formatValue(value, format),
              minLabel: formatValue(min, format),
              maxLabel: formatValue(max, format),
            ),
          ),
        ),
        if (props['label'] != null)
          Text('${props['label']}',
              textAlign: TextAlign.center, style: VizText.subtitle(p)),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.t,
    required this.fill,
    required this.p,
    required this.value,
    required this.minLabel,
    required this.maxLabel,
  });
  final double t;
  final Color fill;
  final VizPalette p;
  final String value;
  final String minLabel;
  final String maxLabel;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.09;
    final radius = size.width / 2 - stroke / 2;
    final c = Offset(size.width / 2, size.width / 2);
    const start = math.pi * 5 / 6, sweep = math.pi * 4 / 3;
    final rect = Rect.fromCircle(center: c, radius: radius);
    final track = Color.lerp(fill, p.surface, 0.78)!;
    canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = track
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round);
    if (t > 0) {
      canvas.drawArc(
          rect,
          start,
          sweep * t,
          false,
          Paint()
            ..color = fill
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round);
    }
    paintText(
        canvas,
        value,
        c,
        p.font(TextStyle(
            fontSize: size.width * 0.17,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()])),
        align: 0,
        valign: 0,
        maxWidth: radius * 1.5);
    final label = VizText.label(p);
    final endY = c.dy + radius * math.sin(start) + stroke;
    paintText(
        canvas, minLabel, Offset(c.dx + radius * math.cos(start), endY), label,
        align: 0);
    paintText(canvas, maxLabel,
        Offset(c.dx + radius * math.cos(start + sweep), endY), label,
        align: 0);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.t != t || old.fill != fill || old.value != value;
}
