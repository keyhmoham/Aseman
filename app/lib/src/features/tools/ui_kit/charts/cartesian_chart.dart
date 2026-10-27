/// Charts on x/y axes: line, area, bar (vertical or horizontal, grouped or
/// stacked), scatter, bubble, candlestick and histogram. One value axis
/// always: two measures of different scale belong in two charts.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../elpian/core/lenient.dart';
import '../palette.dart';
import '../values.dart';
import 'chart_frame.dart';

/// Called when a mark is tapped: `{index, row, x, series, value}`.
typedef ChartSelect = void Function(Map<String, dynamic> detail);

class SeriesSpec {
  const SeriesSpec(this.field, this.label, this.color);
  final String field;
  final String label;
  final Color color;
}

/// A chart's configuration, read from props.
class ChartSpec {
  ChartSpec({
    required this.type,
    required this.rows,
    required this.xField,
    required this.series,
    this.title,
    this.subtitle,
    this.stacked = false,
    this.horizontal = false,
    this.smooth = false,
    this.points = false,
    this.zero = false,
    this.valueLabels = false,
    this.legend,
    this.xFormat,
    this.yFormat,
    this.xTitle,
    this.yTitle,
    this.min,
    this.max,
    this.height = 240,
    this.sizeField,
    this.ohlc = const ['open', 'high', 'low', 'close'],
  });

  final String type;
  final List<Map<String, dynamic>> rows;
  final String xField;
  final List<SeriesSpec> series;
  final String? title;
  final String? subtitle;
  final bool stacked;
  final bool horizontal;
  final bool smooth;
  final bool points;
  final bool zero;
  final bool valueLabels;
  final bool? legend;
  final String? xFormat;
  final String? yFormat;
  final String? xTitle;
  final String? yTitle;
  final double? min;
  final double? max;
  final double height;
  final String? sizeField;
  final List<String> ohlc;

  bool get isBar => type == 'bar' || type == 'column' || type == 'histogram';
  bool get isLine => type == 'line' || type == 'area';
  bool get isScatter => type == 'scatter' || type == 'bubble';
  bool get isCandle => type == 'candlestick' || type == 'ohlc';

  /// Reads a chart from [props] (see the kit's README for the props).
  static ChartSpec fromProps(Map<String, dynamic> props, VizPalette p) {
    var type = '${props['type'] ?? props['kind'] ?? 'line'}'.toLowerCase();
    if (type == 'hbar') type = 'bar';
    var rows = asRows(props['data'] ?? props['rows'] ?? props['values']);
    final scalars =
        asList(props['data'] ?? props['values']).every((v) => v is! Map);
    String? x = props['x'] is String ? props['x'] as String : null;

    if (type == 'histogram') {
      final f = '${props['field'] ?? props['y'] ?? 'value'}';
      final values = [
        for (final r in rows)
          if (asNum(field(r, f)) != null) asNum(field(r, f))!.toDouble()
      ];
      rows =
          _bins(values, asInt(props['bins'], 0), looseStr(props['xFormat']));
      x = 'label';
      props = {
        ...props,
        'series': [
          {'field': 'count', 'label': props['label'] ?? 'Count'}
        ]
      };
    }

    if (scalars && type != 'histogram') {
      rows = [
        for (var i = 0; i < rows.length; i++)
          {'label': '${i + 1}', 'value': rows[i]['value']}
      ];
      x ??= 'label';
    }
    final first = rows.isEmpty ? const <String, dynamic>{} : rows.first;
    x ??= const ['x', 'label', 'name', 'date', 'time', 'category', 'period']
        .firstWhere(first.containsKey,
            orElse: () => first.keys.firstWhere(
                (k) => asNum(first[k]) == null || first[k] is String,
                orElse: () => first.keys.isEmpty ? 'x' : first.keys.first));

    final ohlc = [
      '${props['open'] ?? 'open'}',
      '${props['high'] ?? 'high'}',
      '${props['low'] ?? 'low'}',
      '${props['close'] ?? 'close'}',
    ];
    final sizeField = props['size'] is String ? props['size'] as String : null;
    final series = <SeriesSpec>[];
    void add(Object? s) {
      if (series.length >= VizPalette.maxSeries) return;
      final m = s is Map ? asMap(s) : {'field': s};
      final f = '${m['field'] ?? m['key'] ?? m['y'] ?? m['value'] ?? ''}';
      if (f.isEmpty) return;
      final label = '${m['label'] ?? m['name'] ?? _humanize(f)}';
      final color =
          p.parse(m['color'], index: series.length) ?? p.series(series.length);
      series.add(SeriesSpec(f, label, color));
    }

    final spec = props['series'] ?? props['y'];
    if (spec is List) {
      spec.forEach(add);
    } else if (spec != null) {
      add(spec);
    } else if (type != 'candlestick' && type != 'ohlc') {
      for (final k in first.keys) {
        if (k == x || k == sizeField || first[k] is bool) continue;
        if (first[k] is num ||
            (first[k] is String && asNum(first[k]) != null && k != 'label')) {
          add(k);
        }
      }
    }
    if (type == 'candlestick' || type == 'ohlc') {
      series
        ..clear()
        ..add(SeriesSpec(
            ohlc[3], '${props['label'] ?? 'Price'}', VizPalette.good));
    }

    return ChartSpec(
      type: type,
      rows: rows,
      xField: x,
      series: series,
      title: looseStr(props['title']),
      subtitle: looseStr(props['subtitle']),
      stacked: asBool(props['stacked']),
      horizontal: asBool(props['horizontal']) || props['type'] == 'hbar',
      smooth: asBool(props['smooth']),
      points: asBool(props['points']),
      zero: asBool(
          props['zero'], type == 'bar' || type == 'area' || type == 'column'),
      valueLabels: asBool(props['valueLabels']),
      legend: props['legend'] is bool ? props['legend'] as bool : null,
      xFormat: looseStr(props['xFormat']),
      yFormat: looseStr(props['yFormat'] ?? props['format']),
      xTitle: looseStr(props['xLabel']) ?? looseStr(props['xTitle']),
      yTitle: looseStr(props['yLabel']) ?? looseStr(props['yTitle']),
      min: asNum(props['min'])?.toDouble(),
      max: asNum(props['max'])?.toDouble(),
      height: asDouble(props['height'], 240).clamp(80, 1200),
      sizeField: sizeField,
      ohlc: ohlc,
    );
  }

  static List<Map<String, dynamic>> _bins(
      List<double> values, int bins, String? format) {
    if (values.isEmpty) return [];
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final n = bins > 0
        ? bins
        : math.max(1, math.min(30, math.sqrt(values.length).ceil()));
    final width = hi == lo ? 1.0 : (hi - lo) / n;
    final counts = List<int>.filled(n, 0);
    for (final v in values) {
      counts[math.min(n - 1, ((v - lo) / width).floor())]++;
    }
    return [
      for (var i = 0; i < n; i++)
        {
          'label':
              '${formatValue(lo + i * width, format)}–${formatValue(lo + (i + 1) * width, format)}',
          'count': counts[i],
        }
    ];
  }

  String xLabelAt(int i) => formatValue(field(rows[i], xField), xFormat);

  double? valueAt(int i, String f) => asNum(field(rows[i], f))?.toDouble();
}

String _humanize(String field) {
  final s = field
      .replaceAll(RegExp(r'[_\-.]'), ' ')
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .trim();
  return s.isEmpty ? field : s[0].toUpperCase() + s.substring(1);
}

class CartesianChart extends StatefulWidget {
  const CartesianChart({super.key, required this.spec, this.onSelect});
  final ChartSpec spec;
  final ChartSelect? onSelect;

  @override
  State<CartesianChart> createState() => _CartesianChartState();
}

class _CartesianChartState extends State<CartesianChart> {
  Offset? _pointer;
  _Hit? _hit;

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final p = VizPalette.of(context);
    final legend = (spec.legend ?? spec.series.length > 1) && !spec.isCandle
        ? [
            for (final s in spec.series)
              LegendItem(s.label, s.color, line: spec.isLine)
          ]
        : const <LegendItem>[];
    if (spec.rows.isEmpty || spec.series.isEmpty) {
      return ChartFrame(
          title: spec.title,
          subtitle: spec.subtitle,
          child: NoData(height: spec.height));
    }
    return ChartFrame(
      title: spec.title,
      subtitle: spec.subtitle,
      legend: legend,
      child: SizedBox(
        height: spec.height,
        child: LayoutBuilder(builder: (context, box) {
          final size = Size(box.maxWidth, spec.height);
          final geo = _Geo(spec, size, p);
          final hit = _hit;
          return MouseRegion(
            onHover: (e) => _move(geo, e.localPosition),
            onExit: (_) => setState(() {
              _pointer = null;
              _hit = null;
            }),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                _move(geo, d.localPosition);
                final h = _hit;
                if (h != null) widget.onSelect?.call(_detail(h));
              },
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _CartesianPainter(geo, p, hit),
                    ),
                  ),
                  if (hit != null && _pointer != null)
                    Positioned.fill(
                      child: CustomSingleChildLayout(
                        delegate: TooltipLayout(_pointer!),
                        child: _tooltip(hit, p),
                      ),
                    ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  void _move(_Geo geo, Offset pos) {
    final hit = geo.hitTest(pos);
    if (hit == _hit && pos == _pointer) return;
    setState(() {
      _pointer = pos;
      _hit = hit;
    });
  }

  Map<String, dynamic> _detail(_Hit h) {
    final spec = widget.spec;
    final s = h.series != null ? spec.series[h.series!] : null;
    return {
      'index': h.index,
      'row': spec.rows[h.index],
      'x': field(spec.rows[h.index], spec.xField),
      if (s != null) 'series': s.field,
      if (s != null) 'value': field(spec.rows[h.index], s.field),
    };
  }

  Widget _tooltip(_Hit h, VizPalette p) {
    final spec = widget.spec;
    final row = spec.rows[h.index];
    if (spec.isCandle) {
      const names = ['Open', 'High', 'Low', 'Close'];
      final up = (spec.valueAt(h.index, spec.ohlc[3]) ?? 0) >=
          (spec.valueAt(h.index, spec.ohlc[0]) ?? 0);
      return ChartTooltip(header: spec.xLabelAt(h.index), items: [
        for (var i = 0; i < 4; i++)
          LegendItem(names[i], up ? VizPalette.good : VizPalette.critical,
              value: formatValue(field(row, spec.ohlc[i]), spec.yFormat)),
      ]);
    }
    if (spec.isScatter) {
      final s = spec.series[h.series ?? 0];
      return ChartTooltip(header: s.label, items: [
        LegendItem(spec.xTitle ?? _humanize(spec.xField), s.color,
            value: formatValue(field(row, spec.xField), spec.xFormat)),
        LegendItem(spec.yTitle ?? s.label, s.color,
            value: formatValue(field(row, s.field), spec.yFormat)),
        if (spec.sizeField != null)
          LegendItem(_humanize(spec.sizeField!), s.color,
              value: formatValue(field(row, spec.sizeField), null)),
      ]);
    }
    return ChartTooltip(header: spec.xLabelAt(h.index), items: [
      for (final s in spec.series)
        LegendItem(s.label, s.color,
            line: spec.isLine,
            value: formatValue(field(row, s.field), spec.yFormat)),
    ]);
  }
}

class _Hit {
  const _Hit(this.index, [this.series]);
  final int index;
  final int? series;

  @override
  bool operator ==(Object other) =>
      other is _Hit && other.index == index && other.series == series;

  @override
  int get hashCode => Object.hash(index, series);
}

/// Scales and the plot rectangle for one size.
class _Geo {
  _Geo(this.spec, this.size, this.p) {
    final labelStyle = VizText.label(p);
    n = spec.rows.length;

    // The value domain.
    var lo = double.infinity, hi = -double.infinity;
    void see(double? v) {
      if (v == null) return;
      lo = math.min(lo, v);
      hi = math.max(hi, v);
    }

    if (spec.isCandle) {
      for (var i = 0; i < n; i++) {
        see(spec.valueAt(i, spec.ohlc[1]));
        see(spec.valueAt(i, spec.ohlc[2]));
      }
    } else if (spec.stacked && !spec.isScatter) {
      for (var i = 0; i < n; i++) {
        var pos = 0.0, neg = 0.0;
        for (final s in spec.series) {
          final v = spec.valueAt(i, s.field) ?? 0;
          if (v >= 0) {
            pos += v;
          } else {
            neg += v;
          }
        }
        see(pos);
        see(neg);
      }
    } else {
      for (var i = 0; i < n; i++) {
        for (final s in spec.series) {
          see(spec.valueAt(i, s.field));
        }
      }
    }
    if (!lo.isFinite) {
      lo = 0;
      hi = 1;
    }
    if (spec.zero) {
      lo = math.min(lo, 0);
      hi = math.max(hi, 0);
    }
    if (spec.min != null) lo = spec.min!;
    if (spec.max != null) hi = spec.max!;
    ticks = niceTicks(lo, hi);
    vmin = spec.min ?? ticks.first;
    vmax = spec.max ?? ticks.last;
    if (vmax <= vmin) vmax = vmin + 1;
    ticks = ticks.where((t) => t >= vmin - 1e-9 && t <= vmax + 1e-9).toList();
    tickLabels = [for (final t in ticks) _axisLabel(t, spec.yFormat)];

    // Numeric x (scatter).
    if (spec.isScatter) {
      var xl = double.infinity, xh = -double.infinity;
      for (var i = 0; i < n; i++) {
        final v = asNum(field(spec.rows[i], spec.xField))?.toDouble();
        if (v == null) continue;
        xl = math.min(xl, v);
        xh = math.max(xh, v);
      }
      if (!xl.isFinite) {
        xl = 0;
        xh = 1;
      }
      xticks = niceTicks(xl, xh);
      xmin = xticks.first;
      xmax = xticks.last;
      if (xmax <= xmin) xmax = xmin + 1;
      var smin = double.infinity, smax = -double.infinity;
      if (spec.sizeField != null) {
        for (final r in spec.rows) {
          final v = asNum(field(r, spec.sizeField))?.toDouble();
          if (v == null) continue;
          smin = math.min(smin, v);
          smax = math.max(smax, v);
        }
      }
      sizeMin = smin.isFinite ? smin : 0;
      sizeMax = smax.isFinite ? smax : 1;
    }

    final labelH = measureText('0', labelStyle).height;
    final top = spec.yTitle != null ? labelH + 10 : 6.0;
    final bottomTitle = spec.xTitle != null ? labelH + 6 : 0.0;
    if (spec.horizontal && !spec.isScatter) {
      cats = [for (var i = 0; i < n; i++) spec.xLabelAt(i)];
      final widest = cats.fold<double>(
          0, (w, c) => math.max(w, measureText(c, labelStyle).width));
      final left = math.min(widest, size.width * 0.35) + 10;
      plot = Rect.fromLTRB(
          left, top, size.width - 12, size.height - labelH - 8 - bottomTitle);
      band = plot.height / math.max(1, n);
    } else {
      final widest = (spec.isScatter ? tickLabels : tickLabels).fold<double>(
          0, (w, t) => math.max(w, measureText(t, labelStyle).width));
      plot = Rect.fromLTRB(widest + 10, top, size.width - 8,
          size.height - labelH - 8 - bottomTitle);
      band = plot.width / math.max(1, n);
      if (!spec.isScatter) {
        cats = [for (var i = 0; i < n; i++) spec.xLabelAt(i)];
        final widestCat = cats.fold<double>(
            0, (w, c) => math.max(w, measureText(c, labelStyle).width));
        labelEvery = math.max(1, ((widestCat + 12) / math.max(1, band)).ceil());
      }
    }
  }

  final ChartSpec spec;
  final Size size;
  final VizPalette p;
  late final int n;
  late Rect plot;
  late double band;
  late double vmin, vmax;
  late List<double> ticks;
  late List<String> tickLabels;
  List<String> cats = const [];
  int labelEvery = 1;
  double xmin = 0, xmax = 1;
  List<double> xticks = const [];
  double sizeMin = 0, sizeMax = 1;

  static String _axisLabel(double v, String? format) {
    if (format != null && format.isNotEmpty) {
      final kind = format.replaceFirst('+', '').split(':').first;
      if (kind == 'percent' ||
          kind == 'currency' ||
          kind.startsWith('date') ||
          kind == 'time') {
        return formatValue(v, format.replaceFirst('+', ''));
      }
    }
    return v.abs() >= 10000 ? formatCompact(v) : formatValue(v, null);
  }

  /// The pixel position of value [v] along the value axis.
  double v2p(double v) {
    final t = (v - vmin) / (vmax - vmin);
    return spec.horizontal && !spec.isScatter
        ? plot.left + t * plot.width
        : plot.bottom - t * plot.height;
  }

  /// The center of category [i] along the category axis.
  double c2p(int i) => spec.horizontal
      ? plot.top + band * (i + 0.5)
      : plot.left + band * (i + 0.5);

  double x2p(double x) => plot.left + (x - xmin) / (xmax - xmin) * plot.width;

  double baseline() => v2p(vmin <= 0 && vmax >= 0 ? 0 : vmin);

  double bubbleRadius(Map<String, dynamic> row) {
    if (spec.type != 'bubble' || spec.sizeField == null) return 4;
    final v = asNum(field(row, spec.sizeField))?.toDouble() ?? sizeMin;
    final t = sizeMax == sizeMin ? 0.5 : (v - sizeMin) / (sizeMax - sizeMin);
    return 4 + math.sqrt(t.clamp(0, 1)) * 18;
  }

  _Hit? hitTest(Offset pos) {
    if (n == 0) return null;
    if (spec.isScatter) {
      _Hit? best;
      var bestD = 24.0;
      for (var i = 0; i < n; i++) {
        final x = asNum(field(spec.rows[i], spec.xField))?.toDouble();
        if (x == null) continue;
        for (var s = 0; s < spec.series.length; s++) {
          final y = spec.valueAt(i, spec.series[s].field);
          if (y == null) continue;
          final d = (Offset(x2p(x), v2p(y)) - pos).distance -
              bubbleRadius(spec.rows[i]) +
              4;
          if (d < bestD) {
            bestD = d;
            best = _Hit(i, s);
          }
        }
      }
      return best;
    }
    if (!plot.inflate(4).contains(pos)) return null;
    final along = spec.horizontal ? pos.dy - plot.top : pos.dx - plot.left;
    final i = (along / band).floor();
    return i >= 0 && i < n ? _Hit(i) : null;
  }
}

class _CartesianPainter extends CustomPainter {
  _CartesianPainter(this.g, this.p, this.hit);
  final _Geo g;
  final VizPalette p;
  final _Hit? hit;

  ChartSpec get spec => g.spec;

  @override
  void paint(Canvas canvas, Size size) {
    final label = VizText.label(p);
    final grid = Paint()
      ..color = p.grid
      ..strokeWidth = 1;
    final horizontal = spec.horizontal && !spec.isScatter;

    // Gridlines and value labels.
    for (var i = 0; i < g.ticks.length; i++) {
      final at = g.v2p(g.ticks[i]);
      if (horizontal) {
        canvas.drawLine(
            Offset(at, g.plot.top), Offset(at, g.plot.bottom), grid);
        paintText(canvas, g.tickLabels[i], Offset(at, g.plot.bottom + 6), label,
            align: 0);
      } else {
        canvas.drawLine(
            Offset(g.plot.left, at), Offset(g.plot.right, at), grid);
        paintText(canvas, g.tickLabels[i], Offset(g.plot.left - 8, at), label,
            align: 1, valign: 0);
      }
    }
    // The baseline.
    final axis = Paint()
      ..color = p.axis
      ..strokeWidth = 1;
    final base = g.baseline();
    if (horizontal) {
      canvas.drawLine(
          Offset(base, g.plot.top), Offset(base, g.plot.bottom), axis);
    } else {
      canvas.drawLine(
          Offset(g.plot.left, base), Offset(g.plot.right, base), axis);
    }

    // Category / x labels.
    if (spec.isScatter) {
      for (final t in g.xticks) {
        final x = g.x2p(t);
        if (x < g.plot.left - 1 || x > g.plot.right + 1) continue;
        canvas.drawLine(Offset(x, g.plot.top), Offset(x, g.plot.bottom), grid);
        paintText(canvas, _Geo._axisLabel(t, spec.xFormat),
            Offset(x, g.plot.bottom + 6), label,
            align: 0);
      }
    } else if (horizontal) {
      for (var i = 0; i < g.n; i++) {
        paintText(canvas, g.cats[i], Offset(g.plot.left - 8, g.c2p(i)), label,
            align: 1, valign: 0, maxWidth: g.plot.left - 10);
      }
    } else {
      for (var i = 0; i < g.n; i += g.labelEvery) {
        paintText(canvas, g.cats[i], Offset(g.c2p(i), g.plot.bottom + 6), label,
            align: 0, maxWidth: g.band * g.labelEvery - 4);
      }
    }
    // Axis titles.
    if (spec.yTitle != null) {
      paintText(canvas, spec.yTitle!, const Offset(0, 0), label);
    }
    if (spec.xTitle != null) {
      paintText(
          canvas, spec.xTitle!, Offset(g.plot.center.dx, size.height), label,
          align: 0, valign: 1);
    }

    // The hovered band.
    if (hit != null && !spec.isScatter && !spec.isLine) {
      final c = g.c2p(hit!.index);
      final r = horizontal
          ? Rect.fromLTRB(
              g.plot.left, c - g.band / 2, g.plot.right, c + g.band / 2)
          : Rect.fromLTRB(
              c - g.band / 2, g.plot.top, c + g.band / 2, g.plot.bottom);
      canvas.drawRect(r, Paint()..color = p.hover);
    }

    canvas.save();
    canvas.clipRect(g.plot.inflate(12));
    if (spec.isBar) {
      _bars(canvas);
    } else if (spec.isCandle) {
      _candles(canvas);
    } else if (spec.isScatter) {
      _scatter(canvas);
    } else {
      _lines(canvas);
    }
    canvas.restore();
  }

  void _bars(Canvas canvas) {
    final vertical = !spec.horizontal;
    final s = spec.series.length;
    final valueStyle = VizText.value(p).copyWith(fontSize: 11);
    for (var i = 0; i < g.n; i++) {
      final c = g.c2p(i);
      if (spec.stacked) {
        final w = math.min(24.0, g.band * 0.6);
        var pos = 0.0, neg = 0.0;
        // The last segment on each side carries the rounded end.
        var lastPos = -1, lastNeg = -1;
        for (var k = 0; k < s; k++) {
          final v = spec.valueAt(i, spec.series[k].field) ?? 0;
          if (v > 0) lastPos = k;
          if (v < 0) lastNeg = k;
        }
        for (var k = 0; k < s; k++) {
          final v = spec.valueAt(i, spec.series[k].field) ?? 0;
          if (v == 0) continue;
          final from = v > 0 ? pos : neg;
          final to = from + v;
          if (v > 0) {
            pos = to;
          } else {
            neg = to;
          }
          final a = g.v2p(from), b = g.v2p(to);
          // A 2px gap between segments: each gives up 1px at its inner joints.
          final startsAtBase = from == 0;
          final endsStack = k == (v > 0 ? lastPos : lastNeg);
          var r = vertical
              ? Rect.fromLTRB(
                  c - w / 2, math.min(a, b), c + w / 2, math.max(a, b))
              : Rect.fromLTRB(
                  math.min(a, b), c - w / 2, math.max(a, b), c + w / 2);
          r = _trim(
              r, vertical, v > 0, startsAtBase ? 0 : 1, endsStack ? 0 : 1);
          final paint = Paint()..color = _dim(spec.series[k].color, i);
          if (endsStack) {
            canvas.drawRRect(
                barRect(r, vertical: vertical, positive: v > 0), paint);
          } else {
            canvas.drawRect(r, paint);
          }
        }
        continue;
      }
      final group = g.band * 0.72;
      final w = math.max(2.0, math.min(24.0, (group - 2 * (s - 1)) / s));
      final total = s * w + (s - 1) * 2;
      for (var k = 0; k < s; k++) {
        final v = spec.valueAt(i, spec.series[k].field);
        if (v == null) continue;
        final start = c - total / 2 + k * (w + 2);
        final a = g.baseline(), b = g.v2p(v);
        final r = vertical
            ? Rect.fromLTRB(start, math.min(a, b), start + w, math.max(a, b))
            : Rect.fromLTRB(math.min(a, b), start, math.max(a, b), start + w);
        canvas.drawRRect(barRect(r, vertical: vertical, positive: v >= 0),
            Paint()..color = _dim(spec.series[k].color, i));
        if (spec.valueLabels) {
          final text = formatValue(v, spec.yFormat);
          final ts = measureText(text, valueStyle);
          if (vertical && ts.width <= w + 16) {
            paintText(
                canvas,
                text,
                Offset(start + w / 2, v >= 0 ? r.top - 3 : r.bottom + 3),
                valueStyle,
                align: 0,
                valign: v >= 0 ? 1 : -1);
          } else if (!vertical && ts.height <= w + 6) {
            paintText(
                canvas,
                text,
                Offset(v >= 0 ? r.right + 4 : r.left - 4, start + w / 2),
                valueStyle,
                align: v >= 0 ? -1 : 1,
                valign: 0);
          }
        }
      }
    }
  }

  Rect _trim(
      Rect r, bool vertical, bool positive, double atBase, double atEnd) {
    if (vertical) {
      return positive
          ? Rect.fromLTRB(r.left, r.top + atEnd, r.right, r.bottom - atBase)
          : Rect.fromLTRB(r.left, r.top + atBase, r.right, r.bottom - atEnd);
    }
    return positive
        ? Rect.fromLTRB(r.left + atBase, r.top, r.right - atEnd, r.bottom)
        : Rect.fromLTRB(r.left + atEnd, r.top, r.right - atBase, r.bottom);
  }

  /// Marks of other categories recede while one is hovered.
  Color _dim(Color c, int i) =>
      hit == null || hit!.index == i ? c : c.withValues(alpha: 0.55);

  void _candles(Canvas canvas) {
    final w = math.max(1.0, math.min(12.0, g.band * 0.6));
    for (var i = 0; i < g.n; i++) {
      final o = spec.valueAt(i, spec.ohlc[0]);
      final h = spec.valueAt(i, spec.ohlc[1]);
      final l = spec.valueAt(i, spec.ohlc[2]);
      final c = spec.valueAt(i, spec.ohlc[3]);
      if (o == null || c == null) continue;
      final color = _dim(c >= o ? VizPalette.good : VizPalette.critical, i);
      final x = g.c2p(i);
      if (h != null && l != null) {
        canvas.drawLine(
            Offset(x, g.v2p(h)),
            Offset(x, g.v2p(l)),
            Paint()
              ..color = color
              ..strokeWidth = 1);
      }
      final top = g.v2p(math.max(o, c)), bottom = g.v2p(math.min(o, c));
      canvas.drawRect(
          Rect.fromLTRB(x - w / 2, top, x + w / 2, math.max(bottom, top + 1)),
          Paint()..color = color);
    }
  }

  void _scatter(Canvas canvas) {
    final ring = Paint()
      ..color = p.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var k = 0; k < spec.series.length; k++) {
      final s = spec.series[k];
      for (var i = 0; i < g.n; i++) {
        final x = asNum(field(spec.rows[i], spec.xField))?.toDouble();
        final y = spec.valueAt(i, s.field);
        if (x == null || y == null) continue;
        final at = Offset(g.x2p(x), g.v2p(y));
        final r = g.bubbleRadius(spec.rows[i]);
        final hovered = hit?.index == i && hit?.series == k;
        final fill =
            spec.type == 'bubble' ? s.color.withValues(alpha: 0.7) : s.color;
        canvas.drawCircle(at, r + (hovered ? 2 : 0), Paint()..color = fill);
        canvas.drawCircle(at, r + (hovered ? 2 : 0) + 1, ring);
      }
    }
  }

  void _lines(Canvas canvas) {
    final cum = List<double>.filled(g.n, 0);
    final ring = Paint()
      ..color = p.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var k = 0; k < spec.series.length; k++) {
      final s = spec.series[k];
      final pts = <Offset?>[];
      final lower = <Offset?>[];
      for (var i = 0; i < g.n; i++) {
        final v = spec.valueAt(i, s.field);
        if (v == null) {
          pts.add(null);
          lower.add(null);
          continue;
        }
        final from = spec.stacked ? cum[i] : null;
        final to = spec.stacked ? cum[i] + v : v;
        if (spec.stacked) cum[i] = to;
        pts.add(Offset(g.c2p(i), g.v2p(to)));
        lower.add(Offset(g.c2p(i), from == null ? g.baseline() : g.v2p(from)));
      }
      // Runs of points without gaps.
      final runs = <List<int>>[];
      for (var i = 0; i < pts.length; i++) {
        if (pts[i] == null) continue;
        if (i == 0 || pts[i - 1] == null) {
          runs.add([i]);
        } else {
          runs.last.add(i);
        }
      }
      for (final run in runs) {
        final line = _path([for (final i in run) pts[i]!]);
        if (spec.type == 'area') {
          final area = Path.from(line);
          final back = [for (final i in run.reversed) lower[i]!];
          area.lineTo(back.first.dx, back.first.dy);
          _extend(area, back, smooth: spec.smooth && spec.stacked && k > 0);
          area.close();
          canvas.drawPath(
              area, Paint()..color = s.color.withValues(alpha: 0.12));
        }
        canvas.drawPath(
            line,
            Paint()
              ..color = s.color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round);
        if (spec.points || run.length == 1) {
          for (final i in run) {
            canvas.drawCircle(pts[i]!, 4, Paint()..color = s.color);
            canvas.drawCircle(pts[i]!, 5, ring);
          }
        }
      }
      // The end-dot.
      final last = pts.lastWhere((o) => o != null, orElse: () => null);
      if (last != null && !spec.points) {
        canvas.drawCircle(last, 4, Paint()..color = s.color);
        canvas.drawCircle(last, 5, ring);
      }
      if (hit != null && pts[hit!.index] != null) {
        canvas.drawCircle(pts[hit!.index]!, 4.5, Paint()..color = s.color);
        canvas.drawCircle(pts[hit!.index]!, 5.5, ring);
      }
    }
    if (hit != null) {
      final x = g.c2p(hit!.index);
      canvas.drawLine(
          Offset(x, g.plot.top),
          Offset(x, g.plot.bottom),
          Paint()
            ..color = p.axis
            ..strokeWidth = 1);
    }
  }

  Path _path(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    _extend(path, pts, smooth: spec.smooth);
    return path;
  }

  /// Continues [path] (standing at pts.first) through [pts].
  void _extend(Path path, List<Offset> pts, {required bool smooth}) {
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      if (smooth) {
        final mx = (a.dx + b.dx) / 2;
        path.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
      } else {
        path.lineTo(b.dx, b.dy);
      }
    }
  }

  @override
  bool shouldRepaint(_CartesianPainter old) =>
      old.hit != hit ||
      old.g.size != g.size ||
      !identical(old.g.spec, g.spec) ||
      old.p.dark != p.dark;
}
