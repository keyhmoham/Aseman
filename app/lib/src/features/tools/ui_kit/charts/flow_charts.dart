/// Charts of stages and flows: funnel, waterfall, sankey and gantt.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data_widgets.dart' show Pill;
import '../palette.dart';
import '../values.dart';
import 'cartesian_chart.dart' show ChartSelect;
import 'chart_frame.dart';
import 'viz_canvas.dart';

String? _s(Object? v) => v == null ? null : '$v';

/// A funnel: one stage per row, each a centered rounded bar as wide as its
/// share of the first stage, with its value, its share of the first stage
/// and the conversion from the stage before.
class FunnelChart extends StatelessWidget {
  const FunnelChart({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data'] ?? props['values']);
    final lf = '${props['label'] ?? 'label'}';
    final vf = '${props['value'] ?? 'value'}';
    final format = _s(props['format']);
    final stages = [
      for (var i = 0; i < rows.length; i++)
        (i, formatValue(field(rows[i], lf) ?? 'Stage ${i + 1}', null), asNum(field(rows[i], vf))?.toDouble() ?? 0)
    ];
    if (stages.isEmpty) return ChartFrame(title: _s(props['title']), subtitle: _s(props['subtitle']), child: const NoData());
    final first = stages.first.$3 <= 0 ? 1.0 : stages.first.$3;
    final top = stages.map((s) => s.$3).reduce(math.max);
    final base = p.parse(props['color']) ?? p.accent;
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (n, (i, label, v)) in stages.indexed) ...[
            if (n > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Center(
                  child: Text(
                    '↓ ${formatValue(stages[n - 1].$3 <= 0 ? 0 : v / stages[n - 1].$3, 'percent:1')} continue',
                    style: VizText.label(p).copyWith(fontSize: 11),
                  ),
                ),
              ),
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onSelect == null ? null : () => onSelect!({'index': i, 'row': rows[i], 'label': label, 'value': v}),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: VizText.title(p).copyWith(fontSize: 14))),
                    const SizedBox(width: 8),
                    Text(formatValue(v, format), style: VizText.value(p).copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Pill(text: formatValue(v / first, 'percent:0'), color: base, dot: false),
                  ]),
                  const SizedBox(height: 6),
                  LayoutBuilder(builder: (context, box) {
                    final w = widthIn(box);
                    final t = top <= 0 ? 0.0 : (v / top).clamp(0.0, 1.0);
                    return Center(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: t),
                        duration: const Duration(milliseconds: 700),
                        curve: Curves.easeOutCubic,
                        builder: (context, t, _) => Container(
                          width: math.max(12, w * t),
                          height: 28,
                          decoration: BoxDecoration(
                            color: Color.lerp(base, p.tonal(base, 2), n / math.max(1, stages.length - 1) * 0.7),
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    );
                  }),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A waterfall: how a starting value moves to an end value through
/// increases (green) and decreases (red); rows with `total: true` (or
/// `type: "total"`) are drawn as full bars of the running total.
class WaterfallChart extends StatelessWidget {
  const WaterfallChart({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data'] ?? props['values']);
    final lf = '${props['label'] ?? props['x'] ?? 'label'}';
    final vf = '${props['value'] ?? props['y'] ?? 'value'}';
    final format = _s(props['format'] ?? props['yFormat']);
    final height = asDouble(props['height'], 240).clamp(140, 800).toDouble();
    // (label, from, to, kind) — kind: 0 total, 1 up, -1 down.
    final bars = <(String, double, double, int)>[];
    var run = asDouble(props['start'], 0);
    if (props['start'] != null) bars.add((asText(props['startLabel'] ?? 'Start'), 0, run, 0));
    for (var i = 0; i < rows.length; i++) {
      final label = formatValue(field(rows[i], lf) ?? '${i + 1}', null);
      final isTotal = asBool(rows[i]['total']) || rows[i]['type'] == 'total';
      final v = asNum(field(rows[i], vf))?.toDouble();
      if (isTotal) {
        if (v != null) run = v;
        bars.add((label, 0, run, 0));
      } else {
        final d = v ?? 0;
        bars.add((label, run, run + d, d >= 0 ? 1 : -1));
        run += d;
      }
    }
    if (asBool(props['showTotal'], true) && bars.isNotEmpty && bars.last.$4 != 0) bars.add((asText(props['totalLabel'] ?? 'Total'), 0, run, 0));
    if (bars.isEmpty) return ChartFrame(title: _s(props['title']), child: NoData(height: height));
    final lo = math.min(0.0, bars.map((b) => math.min(b.$2, b.$3)).reduce(math.min));
    final hi = math.max(0.0, bars.map((b) => math.max(b.$2, b.$3)).reduce(math.max));
    final ticks = niceTicks(lo, hi == lo ? lo + 1 : hi);
    final offset = props['start'] != null ? 1 : 0;
    final up = p.parse(props['upColor']) ?? VizPalette.good;
    final down = p.parse(props['downColor']) ?? VizPalette.critical;
    final total = p.parse(props['color']) ?? p.accent;

    Rect plotOf(Size s) => Rect.fromLTRB(44, 8, s.width - 4, s.height - 26);
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      legend: [LegendItem('Increase', up), LegendItem('Decrease', down), LegendItem('Total', total)],
      child: VizCanvas(
        height: height,
        onSelect: onSelect,
        painter: (size, hover) => _WaterfallPainter(bars, ticks, plotOf(size), p, up, down, total, hover, format),
        hitTest: (pos, size) {
          final plot = plotOf(size);
          final band = plot.width / bars.length;
          final i = ((pos.dx - plot.left) / band).floor();
          if (i < 0 || i >= bars.length) return null;
          final b = bars[i];
          final row = i - offset >= 0 && i - offset < rows.length ? rows[i - offset] : null;
          return VizHit(i,
              header: b.$1,
              items: [
                if (b.$4 != 0) LegendItem(b.$4 > 0 ? 'Increase' : 'Decrease', b.$4 > 0 ? up : down, value: formatValue(b.$3 - b.$2, '+${format ?? 'number'}')),
                LegendItem(b.$4 == 0 ? 'Total' : 'Running total', total, value: formatValue(b.$3, format)),
              ],
              detail: {'label': b.$1, 'value': b.$3 - b.$2, 'total': b.$3, if (row != null) 'row': row});
        },
      ),
    );
  }
}

class _WaterfallPainter extends CustomPainter {
  _WaterfallPainter(this.bars, this.ticks, this.plot, this.p, this.up, this.down, this.total, this.hover, this.format);
  final List<(String, double, double, int)> bars;
  final List<double> ticks;
  final Rect plot;
  final VizPalette p;
  final Color up, down, total;
  final int? hover;
  final String? format;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = ticks.first, hi = ticks.last;
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
    final grid = Paint()..color = p.grid..strokeWidth = 1;
    for (final t in ticks) {
      canvas.drawLine(Offset(plot.left, y(t)), Offset(plot.right, y(t)), grid);
      paintText(canvas, formatValue(t, format ?? 'compact'), Offset(plot.left - 6, y(t)), VizText.label(p), align: 1, valign: 0);
    }
    final band = plot.width / bars.length;
    final w = math.min(56.0, band * 0.62);
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final cx = plot.left + band * (i + 0.5);
      final top = y(math.max(b.$2, b.$3)), bottom = y(math.min(b.$2, b.$3));
      final color = b.$4 == 0 ? total : (b.$4 > 0 ? up : down);
      final r = Rect.fromLTRB(cx - w / 2, top, cx + w / 2, math.max(bottom, top + 2));
      if (hover == i) canvas.drawRect(Rect.fromLTRB(plot.left + band * i, plot.top, plot.left + band * (i + 1), plot.bottom), Paint()..color = p.hover);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), Paint()..color = color);
      // A dashed connector to the next bar at the running total.
      if (i < bars.length - 1) {
        final ly = y(b.$3);
        final dash = Paint()..color = p.axis..strokeWidth = 1;
        for (var x = cx + w / 2; x < cx + band - w / 2; x += 6) {
          canvas.drawLine(Offset(x, ly), Offset(math.min(x + 3, cx + band - w / 2), ly), dash);
        }
      }
      paintText(canvas, b.$1, Offset(cx, plot.bottom + 6), VizText.label(p), align: 0, maxWidth: band - 2);
    }
    canvas.drawLine(Offset(plot.left, y(0)), Offset(plot.right, y(0)), Paint()..color = p.axis..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_WaterfallPainter old) => old.hover != hover || old.bars != bars || old.plot != plot;
}

class _SNode {
  _SNode(this.id, this.label);
  final String id;
  String label;
  Color? color;
  int layer = 0;
  double inV = 0, outV = 0;
  Rect rect = Rect.zero;
  double outY = 0, inY = 0;
  double get value => math.max(inV, outV);
}

class _SLink {
  _SLink(this.from, this.to, this.value, this.row);
  final _SNode from, to;
  final double value;
  final Map<String, dynamic> row;
  double y0 = 0, y1 = 0, thick = 0;
  Path path = Path();
}

/// A sankey diagram: flows (`links: [{from, to, value}]`) between nodes laid
/// out in layers from sources to sinks, each ribbon as thick as its value.
class SankeyChart extends StatelessWidget {
  const SankeyChart({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final linkRows = asRows(props['links'] ?? props['data'] ?? props['edges']);
    final sf = '${props['source'] ?? 'from'}', tf = '${props['target'] ?? 'to'}', vf = '${props['value'] ?? 'value'}';
    final format = _s(props['format']);
    final height = asDouble(props['height'], 300).clamp(160, 900).toDouble();
    final nodes = <String, _SNode>{};
    _SNode node(String id) => nodes.putIfAbsent(id, () => _SNode(id, id));
    for (final n in asRows(props['nodes'])) {
      final id = asText(n['id'] ?? n['label']);
      if (id.isEmpty) continue;
      node(id)
        ..label = asText(n['label'] ?? id)
        ..color = p.parse(n['color']);
    }
    final links = <_SLink>[];
    for (final r in linkRows) {
      final a = asText(field(r, sf) ?? r['source']), b = asText(field(r, tf) ?? r['target']);
      final v = asNum(field(r, vf))?.toDouble() ?? 0;
      if (a.isEmpty || b.isEmpty || a == b || v <= 0) continue;
      links.add(_SLink(node(a), node(b), v, r));
    }
    if (links.isEmpty) return ChartFrame(title: _s(props['title']), child: NoData(height: height));
    for (final l in links) {
      l.from.outV += l.value;
      l.to.inV += l.value;
    }
    // Layers: the longest path from a source (bounded, so cycles end).
    for (var pass = 0; pass < nodes.length; pass++) {
      var changed = false;
      for (final l in links) {
        if (l.to.layer < l.from.layer + 1 && l.from.layer + 1 < nodes.length) {
          l.to.layer = l.from.layer + 1;
          changed = true;
        }
      }
      if (!changed) break;
    }
    // Sinks align to the last layer.
    final last = nodes.values.map((n) => n.layer).reduce(math.max);
    for (final n in nodes.values) {
      if (n.outV == 0 && n.inV > 0) n.layer = last;
    }
    var i = 0;
    for (final n in nodes.values) {
      n.color ??= p.series(i++ % VizPalette.maxSeries);
    }

    void layout(Size size) {
      const nodeW = 12.0, gap = 10.0;
      final labelPad = math.min(110.0, size.width * 0.22);
      final layers = <int, List<_SNode>>{};
      for (final n in nodes.values) {
        (layers[n.layer] ??= []).add(n);
      }
      var scale = double.infinity;
      for (final ns in layers.values) {
        final sum = ns.fold<double>(0, (s, n) => s + n.value);
        scale = math.min(scale, (size.height - gap * (ns.length - 1)) / sum);
      }
      final x0 = 0.0, x1 = size.width - nodeW - labelPad;
      for (final e in layers.entries) {
        final ns = e.value..sort((a, b) => b.value.compareTo(a.value));
        final used = ns.fold<double>(0, (s, n) => s + n.value * scale) + gap * (ns.length - 1);
        var y = (size.height - used) / 2;
        final x = last == 0 ? x0 : x0 + (x1 - x0) * e.key / last;
        for (final n in ns) {
          final h = math.max(2.0, n.value * scale);
          n.rect = Rect.fromLTWH(x, y, nodeW, h);
          n.outY = y;
          n.inY = y;
          y += h + gap;
        }
      }
      links.sort((a, b) => a.to.rect.top.compareTo(b.to.rect.top));
      for (final l in links) {
        l.thick = math.max(1, l.value * scale);
        l.y0 = l.from.outY + l.thick / 2;
        l.from.outY += l.thick;
      }
      links.sort((a, b) => a.from.rect.top.compareTo(b.from.rect.top));
      for (final l in links) {
        l.y1 = l.to.inY + l.thick / 2;
        l.to.inY += l.thick;
        final xa = l.from.rect.right, xb = l.to.rect.left, mid = (xa + xb) / 2;
        l.path = Path()
          ..moveTo(xa, l.y0 - l.thick / 2)
          ..cubicTo(mid, l.y0 - l.thick / 2, mid, l.y1 - l.thick / 2, xb, l.y1 - l.thick / 2)
          ..lineTo(xb, l.y1 + l.thick / 2)
          ..cubicTo(mid, l.y1 + l.thick / 2, mid, l.y0 + l.thick / 2, xa, l.y0 + l.thick / 2)
          ..close();
      }
    }

    final ns = nodes.values.toList();
    Size? laid;
    void ensure(Size s) {
      if (laid != s) {
        layout(s);
        laid = s;
      }
    }

    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      child: VizCanvas(
        height: height,
        onSelect: onSelect,
        painter: (size, hover) {
          ensure(size);
          return _SankeyPainter(ns, links, p, hover, format);
        },
        hitTest: (pos, size) {
          ensure(size);
          for (var k = 0; k < ns.length; k++) {
            if (ns[k].rect.inflate(4).contains(pos)) {
              final n = ns[k];
              return VizHit(k,
                  header: n.label,
                  items: [LegendItem('In', n.color!, value: formatValue(n.inV, format)), LegendItem('Out', n.color!, value: formatValue(n.outV, format))],
                  detail: {'node': n.id, 'label': n.label, 'value': n.value});
            }
          }
          for (var k = links.length - 1; k >= 0; k--) {
            if (links[k].path.contains(pos)) {
              final l = links[k];
              return VizHit(ns.length + k,
                  header: '${l.from.label} → ${l.to.label}',
                  items: [LegendItem('Flow', l.from.color!, value: formatValue(l.value, format))],
                  detail: {'from': l.from.id, 'to': l.to.id, 'value': l.value, 'row': l.row});
            }
          }
          return null;
        },
      ),
    );
  }
}

class _SankeyPainter extends CustomPainter {
  _SankeyPainter(this.nodes, this.links, this.p, this.hover, this.format);
  final List<_SNode> nodes;
  final List<_SLink> links;
  final VizPalette p;
  final int? hover;
  final String? format;

  @override
  void paint(Canvas canvas, Size size) {
    final hoverNode = hover != null && hover! < nodes.length ? nodes[hover!] : null;
    final hoverLink = hover != null && hover! >= nodes.length ? links[hover! - nodes.length] : null;
    for (final l in links) {
      final lit = hoverLink == l || hoverNode == l.from || hoverNode == l.to;
      final dim = (hoverNode != null || hoverLink != null) && !lit;
      canvas.drawPath(l.path, Paint()..color = l.from.color!.withValues(alpha: dim ? 0.12 : (lit ? 0.6 : 0.32)));
    }
    final maxX = nodes.map((n) => n.rect.left).reduce(math.max);
    for (final n in nodes) {
      canvas.drawRRect(RRect.fromRectAndRadius(n.rect, const Radius.circular(4)), Paint()..color = n.color!);
      final right = n.rect.left < maxX;
      paintText(canvas, '${n.label}  ${formatValue(n.value, format ?? 'compact')}',
          Offset(right ? n.rect.right + 6 : n.rect.right + 6, n.rect.center.dy), VizText.label(p).copyWith(fontSize: 12, color: p.textPrimary),
          valign: 0, maxWidth: math.max(40, size.width - n.rect.right - 8));
    }
  }

  @override
  bool shouldRepaint(_SankeyPainter old) => old.hover != hover || old.links != links;
}

/// A gantt chart: one row per task (`start` → `end`, optional `progress`
/// 0..1 and `group`), on a time axis with today marked; a task whose start
/// equals its end is a milestone.
class GanttChart extends StatelessWidget {
  const GanttChart({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data'] ?? props['tasks']);
    final lf = '${props['label'] ?? 'label'}', sf = '${props['start'] ?? 'start'}', ef = '${props['end'] ?? 'end'}';
    final tasks = <(int, String, DateTime, DateTime, double?, Color)>[];
    final groups = <String>[];
    for (var i = 0; i < rows.length; i++) {
      final s = asTime(field(rows[i], sf)), e = asTime(field(rows[i], ef)) ?? s;
      if (s == null || e == null) continue;
      final g = asText(rows[i]['group']);
      if (g.isNotEmpty && !groups.contains(g)) groups.add(g);
      final status = rows[i]['status'];
      final color = p.parse(rows[i]['color']) ??
          (status is String && status != 'info' ? p.status(status) : (g.isEmpty ? p.accent : p.series(groups.indexOf(g))));
      tasks.add((i, asText(field(rows[i], lf) ?? rows[i]['task'] ?? rows[i]['title'] ?? 'Task ${i + 1}'), s, e.isBefore(s) ? s : e,
          asNum(rows[i]['progress'])?.toDouble(), color));
    }
    const rowH = 34.0, axisH = 26.0;
    if (tasks.isEmpty) return ChartFrame(title: _s(props['title']), child: const NoData());
    var t0 = tasks.map((t) => t.$3).reduce((a, b) => a.isBefore(b) ? a : b);
    var t1 = tasks.map((t) => t.$4).reduce((a, b) => a.isAfter(b) ? a : b);
    if (!t1.isAfter(t0)) t1 = t0.add(const Duration(days: 1));
    final pad = t1.difference(t0) * 0.03;
    t0 = t0.subtract(pad);
    t1 = t1.add(pad);
    final height = axisH + rowH * tasks.length + 4;
    final timeFormat = _s(props['timeFormat']);
    return ChartFrame(
      title: _s(props['title']),
      subtitle: _s(props['subtitle']),
      legend: [for (var g = 0; g < groups.length; g++) LegendItem(groups[g], p.series(g))],
      child: LayoutBuilder(builder: (context, box) {
        final w = widthIn(box, 480);
        final labelW = math.min(160.0, w * 0.3);
        return SizedBox(
          width: w,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: labelW,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(height: axisH),
                for (final t in tasks)
                  SizedBox(
                    height: rowH,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(t.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: VizText.value(p).copyWith(fontSize: 13)),
                    ),
                  ),
              ]),
            ),
            Expanded(
              child: VizCanvas(
                height: height,
                onSelect: onSelect,
                painter: (size, hover) => _GanttPainter(tasks, t0, t1, rowH, axisH, p, hover, timeFormat),
                hitTest: (pos, size) {
                  final k = ((pos.dy - axisH) / rowH).floor();
                  if (k < 0 || k >= tasks.length) return null;
                  final t = tasks[k];
                  return VizHit(k,
                      header: t.$2,
                      items: [
                        LegendItem('Start', t.$6, value: formatValue(t.$3.toIso8601String(), timeFormat ?? 'date')),
                        LegendItem('End', t.$6, value: formatValue(t.$4.toIso8601String(), timeFormat ?? 'date')),
                        if (t.$5 != null) LegendItem('Progress', t.$6, value: formatValue(t.$5, 'percent')),
                      ],
                      detail: {'row': rows[t.$1], 'label': t.$2});
                },
              ),
            ),
          ]),
        );
      }),
    );
  }
}

class _GanttPainter extends CustomPainter {
  _GanttPainter(this.tasks, this.t0, this.t1, this.rowH, this.axisH, this.p, this.hover, this.timeFormat);
  final List<(int, String, DateTime, DateTime, double?, Color)> tasks;
  final DateTime t0, t1;
  final double rowH, axisH;
  final VizPalette p;
  final int? hover;
  final String? timeFormat;

  @override
  void paint(Canvas canvas, Size size) {
    final span = t1.difference(t0).inMilliseconds.toDouble();
    double x(DateTime t) => t.difference(t0).inMilliseconds / span * size.width;
    // Ticks: days, weeks or months by span.
    final days = span / 86400000;
    final ticks = <DateTime>[];
    var t = DateTime(t0.year, t0.month, t0.day);
    if (days > 120) {
      t = DateTime(t0.year, t0.month);
      while (t.isBefore(t1)) {
        ticks.add(t);
        t = DateTime(t.year, t.month + (days > 700 ? 3 : 1));
      }
    } else {
      final step = days > 28 ? 7 : (days > 10 ? 2 : 1);
      while (t.isBefore(t1)) {
        ticks.add(t);
        t = t.add(Duration(days: step));
      }
    }
    final grid = Paint()..color = p.grid..strokeWidth = 1;
    final fmt = days > 120 ? (DateTime d) => '${monthNames[d.month - 1].substring(0, 3)}${d.month == 1 ? ' ${d.year}' : ''}' : (DateTime d) => formatValue(d.toIso8601String(), timeFormat ?? 'date').replaceAll(RegExp(r',? \d{4}$'), '');
    var lastLabel = -1e9;
    for (final d in ticks) {
      final xx = x(d);
      if (xx < 0) continue;
      canvas.drawLine(Offset(xx, axisH - 4), Offset(xx, size.height), grid);
      if (xx - lastLabel > 56) {
        paintText(canvas, fmt(d), Offset(xx + 3, 4), VizText.label(p));
        lastLabel = xx;
      }
    }
    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      final top = axisH + i * rowH;
      if (hover == i) canvas.drawRect(Rect.fromLTWH(0, top, size.width, rowH), Paint()..color = p.hover);
      final a = x(task.$3), b = x(task.$4);
      if (b - a < 1) {
        // Milestone: a diamond.
        final c = Offset(a, top + rowH / 2);
        canvas.drawPath(Path()..moveTo(c.dx, c.dy - 8)..lineTo(c.dx + 8, c.dy)..lineTo(c.dx, c.dy + 8)..lineTo(c.dx - 8, c.dy)..close(), Paint()..color = task.$6);
        continue;
      }
      final r = RRect.fromRectAndRadius(Rect.fromLTRB(a, top + 7, b, top + rowH - 7), const Radius.circular(10));
      canvas.drawRRect(r, Paint()..color = task.$5 == null ? task.$6 : p.tonal(task.$6, 2.2));
      if (task.$5 != null) {
        canvas.save();
        canvas.clipRRect(r);
        canvas.drawRect(Rect.fromLTRB(a, top, a + (b - a) * task.$5!.clamp(0, 1), top + rowH), Paint()..color = task.$6);
        canvas.restore();
      }
    }
    final now = DateTime.now();
    if (now.isAfter(t0) && now.isBefore(t1)) {
      final xx = x(now);
      canvas.drawLine(Offset(xx, axisH - 6), Offset(xx, size.height), Paint()..color = p.scheme.error..strokeWidth = 2);
      canvas.drawCircle(Offset(xx, axisH - 6), 3, Paint()..color = p.scheme.error);
    }
  }

  @override
  bool shouldRepaint(_GanttPainter old) => old.hover != hover || old.tasks != tasks;
}
