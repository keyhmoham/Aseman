/// Magnitude over two dimensions (heatmap) and part-to-whole by area
/// (treemap).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../palette.dart';
import '../values.dart';
import 'cartesian_chart.dart' show ChartSelect;
import 'chart_frame.dart';

/// A heatmap: one cell per (row, column), colored by value on the blue ramp
/// (or blue ↔ red through gray when values change sign).
class Heatmap extends StatefulWidget {
  const Heatmap({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  State<Heatmap> createState() => _HeatmapState();
}

class _HeatmapState extends State<Heatmap> {
  (int, int)? _hover;
  Offset? _pointer;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final props = widget.props;
    final format = props['format'] as String?;
    // Either a matrix (rows × columns labels + values[r][c]) or long rows of
    // {x, y, value}.
    var rowLabels = [
      for (final r in asList(props['rows'])) formatValue(r, null)
    ];
    var colLabels = [
      for (final c in asList(props['columns'])) formatValue(c, null)
    ];
    final cells = <(int, int), double>{};
    if (props['values'] is List) {
      final m = props['values'] as List;
      for (var r = 0; r < m.length; r++) {
        final row = asList(m[r]);
        for (var c = 0; c < row.length; c++) {
          final v = asNum(row[c])?.toDouble();
          if (v != null) cells[(r, c)] = v;
        }
      }
      final cols = m.fold<int>(0, (w, r) => math.max(w, asList(r).length));
      if (rowLabels.length < m.length) {
        rowLabels = [
          for (var i = 0; i < m.length; i++)
            i < rowLabels.length ? rowLabels[i] : '${i + 1}'
        ];
      }
      if (colLabels.length < cols) {
        colLabels = [
          for (var i = 0; i < cols; i++)
            i < colLabels.length ? colLabels[i] : '${i + 1}'
        ];
      }
    } else {
      final xf = '${props['x'] ?? 'x'}', yf = '${props['y'] ?? 'y'}';
      final vf = '${props['value'] ?? 'value'}';
      final xs = <String>[], ys = <String>[];
      for (final row in asRows(props['data'])) {
        final x = formatValue(field(row, xf), props['xFormat'] as String?);
        final y = formatValue(field(row, yf), props['yFormat'] as String?);
        if (!xs.contains(x)) xs.add(x);
        if (!ys.contains(y)) ys.add(y);
        final v = asNum(field(row, vf))?.toDouble();
        if (v != null) cells[(ys.indexOf(y), xs.indexOf(x))] = v;
      }
      rowLabels = ys;
      colLabels = xs;
    }
    if (cells.isEmpty) {
      return ChartFrame(
          title: props['title'] as String?, child: const NoData());
    }
    final lo = cells.values.reduce(math.min),
        hi = cells.values.reduce(math.max);
    final diverging = asBool(props['diverging'], lo < 0 && hi > 0);
    final maxAbs = math.max(lo.abs(), hi.abs());
    Color colorOf(double v) => diverging
        ? p.diverging(maxAbs == 0 ? 0 : v / maxAbs)
        : p.sequential(hi == lo ? 0.6 : (v - lo) / (hi - lo));
    final showValues = asBool(props['showValues']);
    final cellH = asDouble(props['cellHeight'], 28).clamp(12, 80).toDouble();
    final label = VizText.label(p);
    final rowW = math.min(
        120.0,
        rowLabels.fold<double>(
                0, (w, l) => math.max(w, measureText(l, label).width)) +
            8);
    final height = rowLabels.length * cellH + 22;

    return ChartFrame(
      title: props['title'] as String?,
      subtitle: props['subtitle'] as String?,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: height,
            child: LayoutBuilder(builder: (context, box) {
              final cellW =
                  (box.maxWidth - rowW) / math.max(1, colLabels.length);
              (int, int)? hit(Offset o) {
                final c = ((o.dx - rowW) / cellW).floor();
                final r = (o.dy / cellH).floor();
                if (c < 0 ||
                    r < 0 ||
                    c >= colLabels.length ||
                    r >= rowLabels.length) {
                  return null;
                }
                return cells.containsKey((r, c)) ? (r, c) : null;
              }

              void move(Offset o) => setState(() {
                    _pointer = o;
                    _hover = hit(o);
                  });
              final hover = _hover;
              return MouseRegion(
                onHover: (e) => move(e.localPosition),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    move(d.localPosition);
                    final h = hit(d.localPosition);
                    if (h != null) {
                      widget.onSelect?.call({
                        'row': rowLabels[h.$1],
                        'column': colLabels[h.$2],
                        'value': cells[h],
                      });
                    }
                  },
                  child: Stack(children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _HeatPainter(
                          rows: rowLabels,
                          cols: colLabels,
                          cells: cells,
                          colorOf: colorOf,
                          rowW: rowW,
                          cellW: cellW,
                          cellH: cellH,
                          hover: hover,
                          p: p,
                          values:
                              showValues ? (v) => formatValue(v, format) : null,
                        ),
                      ),
                    ),
                    if (hover != null && _pointer != null)
                      Positioned.fill(
                        child: CustomSingleChildLayout(
                          delegate: TooltipLayout(_pointer!),
                          child: ChartTooltip(
                            header:
                                '${rowLabels[hover.$1]} · ${colLabels[hover.$2]}',
                            items: [
                              LegendItem(
                                  props['valueLabel'] as String? ?? 'Value',
                                  colorOf(cells[hover]!),
                                  value: formatValue(cells[hover], format)),
                            ],
                          ),
                        ),
                      ),
                  ]),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          _ScaleLegend(
            from: diverging ? -maxAbs : lo,
            to: diverging ? maxAbs : hi,
            colorOf: colorOf,
            format: format,
          ),
        ],
      ),
    );
  }
}

class _HeatPainter extends CustomPainter {
  _HeatPainter({
    required this.rows,
    required this.cols,
    required this.cells,
    required this.colorOf,
    required this.rowW,
    required this.cellW,
    required this.cellH,
    required this.hover,
    required this.p,
    this.values,
  });
  final List<String> rows;
  final List<String> cols;
  final Map<(int, int), double> cells;
  final Color Function(double) colorOf;
  final double rowW, cellW, cellH;
  final (int, int)? hover;
  final VizPalette p;
  final String Function(double)? values;

  @override
  void paint(Canvas canvas, Size size) {
    final label = VizText.label(p);
    for (var r = 0; r < rows.length; r++) {
      paintText(canvas, rows[r], Offset(rowW - 8, (r + 0.5) * cellH), label,
          align: 1, valign: 0, maxWidth: rowW - 8);
    }
    final widest = cols.fold<double>(
        0, (w, c) => math.max(w, measureText(c, label).width));
    final every = math.max(1, ((widest + 8) / math.max(1, cellW)).ceil());
    for (var c = 0; c < cols.length; c += every) {
      paintText(canvas, cols[c],
          Offset(rowW + (c + 0.5) * cellW, rows.length * cellH + 4), label,
          align: 0, maxWidth: cellW * every);
    }
    for (final e in cells.entries) {
      final (r, c) = e.key;
      final rect = Rect.fromLTWH(rowW + c * cellW + 1, r * cellH + 1,
          math.max(1, cellW - 2), math.max(1, cellH - 2));
      final color = colorOf(e.value);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)),
          Paint()..color = color);
      if (hover == e.key) {
        canvas.drawRRect(
            RRect.fromRectAndRadius(rect.inflate(1), const Radius.circular(3)),
            Paint()
              ..color = p.textPrimary
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
      if (values != null) {
        final text = values!(e.value);
        final style = VizText.value(p)
            .copyWith(fontSize: 10, color: VizPalette.onFill(color));
        if (measureText(text, style).width <= rect.width - 4) {
          paintText(canvas, text, rect.center, style, align: 0, valign: 0);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_HeatPainter old) => true;
}

class _ScaleLegend extends StatelessWidget {
  const _ScaleLegend(
      {required this.from,
      required this.to,
      required this.colorOf,
      this.format});
  final double from, to;
  final Color Function(double) colorOf;
  final String? format;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(formatValue(from, format), style: VizText.label(p)),
        const SizedBox(width: 6),
        Container(
          width: 120,
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(colors: [
              for (var i = 0; i <= 8; i++) colorOf(from + (to - from) * i / 8)
            ]),
          ),
        ),
        const SizedBox(width: 6),
        Text(formatValue(to, format), style: VizText.label(p)),
      ],
    );
  }
}

class _Tile {
  _Tile(this.index, this.label, this.value, this.color);
  final int index;
  final String label;
  final double value;
  final Color color;
  Rect rect = Rect.zero;
}

/// A treemap: rectangles sized by value (squarified), colored by group (in
/// order of first appearance) or by a signed measure (`colorBy`, e.g. a
/// change in percent: red ↔ gray ↔ blue).
class Treemap extends StatefulWidget {
  const Treemap({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  State<Treemap> createState() => _TreemapState();
}

class _TreemapState extends State<Treemap> {
  int? _hover;
  Offset? _pointer;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final props = widget.props;
    final rows = asRows(props['data']);
    final lf = '${props['label'] ?? 'label'}',
        vf = '${props['value'] ?? 'value'}';
    final gf = props['group'] as String?;
    final cf = props['colorBy'] as String?;
    final format = props['format'] as String?;
    final colorFormat = props['colorFormat'] as String?;
    final height = asDouble(props['height'], 260).clamp(100, 900).toDouble();

    final groups = <String>[];
    var maxAbs = 0.0;
    if (cf != null) {
      for (final r in rows) {
        maxAbs = math.max(maxAbs, (asNum(field(r, cf)) ?? 0).abs().toDouble());
      }
    }
    final tiles = <_Tile>[];
    for (var i = 0; i < rows.length; i++) {
      final v = asNum(field(rows[i], vf))?.toDouble();
      if (v == null || v <= 0) continue;
      Color color;
      if (cf != null) {
        final c = asNum(field(rows[i], cf))?.toDouble() ?? 0;
        color = p.diverging(maxAbs == 0 ? 0 : c / maxAbs);
      } else if (gf != null) {
        final g = formatValue(field(rows[i], gf), null);
        if (!groups.contains(g)) groups.add(g);
        color = p.series(groups.indexOf(g));
      } else {
        color = p.parse(field(rows[i], 'color')) ?? p.series(0);
      }
      tiles.add(_Tile(i, formatValue(field(rows[i], lf), null), v, color));
    }
    if (tiles.isEmpty) {
      return ChartFrame(
          title: props['title'] as String?, child: NoData(height: height));
    }
    tiles.sort((a, b) => b.value.compareTo(a.value));

    return ChartFrame(
      title: props['title'] as String?,
      subtitle: props['subtitle'] as String?,
      legend: groups.length > 1
          ? [
              for (var i = 0; i < groups.length; i++)
                LegendItem(groups[i], p.series(i))
            ]
          : const [],
      child: SizedBox(
        height: height,
        child: LayoutBuilder(builder: (context, box) {
          _squarify(tiles, Offset.zero & Size(box.maxWidth, height));
          int? hit(Offset o) {
            for (var i = 0; i < tiles.length; i++) {
              if (tiles[i].rect.contains(o)) return i;
            }
            return null;
          }

          void move(Offset o) => setState(() {
                _pointer = o;
                _hover = hit(o);
              });
          final hover =
              _hover != null && _hover! < tiles.length ? _hover : null;
          return MouseRegion(
            onHover: (e) => move(e.localPosition),
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                move(d.localPosition);
                final i = hit(d.localPosition);
                if (i != null) {
                  widget.onSelect?.call({
                    'index': tiles[i].index,
                    'row': rows[tiles[i].index],
                    'label': tiles[i].label,
                    'value': tiles[i].value,
                  });
                }
              },
              child: Stack(children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TreePainter(tiles, hover, p, (t) {
                      final row = rows[t.index];
                      return cf != null
                          ? formatValue(field(row, cf), colorFormat)
                          : formatValue(t.value, format);
                    }),
                  ),
                ),
                if (hover != null && _pointer != null)
                  Positioned.fill(
                    child: CustomSingleChildLayout(
                      delegate: TooltipLayout(_pointer!),
                      child: ChartTooltip(header: tiles[hover].label, items: [
                        LegendItem(props['valueLabel'] as String? ?? 'Value',
                            tiles[hover].color,
                            value: formatValue(tiles[hover].value, format)),
                        if (cf != null)
                          LegendItem(props['colorLabel'] as String? ?? cf,
                              tiles[hover].color,
                              value: formatValue(
                                  field(rows[tiles[hover].index], cf),
                                  colorFormat)),
                        if (gf != null)
                          LegendItem(gf, tiles[hover].color,
                              value: formatValue(
                                  field(rows[tiles[hover].index], gf), null)),
                      ]),
                    ),
                  ),
              ]),
            ),
          );
        }),
      ),
    );
  }

  /// Squarified treemap layout of [tiles] (sorted by value, descending).
  static void _squarify(List<_Tile> tiles, Rect area) {
    final total = tiles.fold<double>(0, (s, t) => s + t.value);
    if (total <= 0) return;
    final scale = area.width * area.height / total;
    var rect = area;
    var i = 0;
    while (i < tiles.length) {
      final short = math.min(rect.width, rect.height);
      final row = <_Tile>[tiles[i]];
      double worst(List<_Tile> r) {
        final s = r.fold<double>(0, (a, t) => a + t.value * scale);
        final mx = r.map((t) => t.value * scale).reduce(math.max);
        final mn = r.map((t) => t.value * scale).reduce(math.min);
        return math.max(
            short * short * mx / (s * s), s * s / (short * short * mn));
      }

      var j = i + 1;
      while (j < tiles.length && worst([...row, tiles[j]]) <= worst(row)) {
        row.add(tiles[j]);
        j++;
      }
      final sum = row.fold<double>(0, (a, t) => a + t.value * scale);
      final horizontalStrip = rect.width >= rect.height;
      final thickness = sum / short;
      var offset = 0.0;
      for (final t in row) {
        final len = t.value * scale / thickness;
        t.rect = horizontalStrip
            ? Rect.fromLTWH(rect.left, rect.top + offset, thickness, len)
            : Rect.fromLTWH(rect.left + offset, rect.top, len, thickness);
        offset += len;
      }
      rect = horizontalStrip
          ? Rect.fromLTRB(
              rect.left + thickness, rect.top, rect.right, rect.bottom)
          : Rect.fromLTRB(
              rect.left, rect.top + thickness, rect.right, rect.bottom);
      i = j;
    }
  }
}

class _TreePainter extends CustomPainter {
  _TreePainter(this.tiles, this.hover, this.p, this.caption);
  final List<_Tile> tiles;
  final int? hover;
  final VizPalette p;
  final String Function(_Tile) caption;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < tiles.length; i++) {
      final t = tiles[i];
      final r = t.rect.deflate(1);
      if (r.width <= 0 || r.height <= 0) continue;
      canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(3)),
          Paint()
            ..color = hover == null || hover == i
                ? t.color
                : t.color.withValues(alpha: 0.7));
      final ink = VizPalette.onFill(t.color);
      final title = p.font(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ink));
      final sub = p.font(TextStyle(
          fontSize: 11,
          color: ink.withValues(alpha: 0.85),
          fontFeatures: const [FontFeature.tabularFigures()]));
      final ts = measureText(t.label, title);
      if (r.width >= math.min(ts.width, 40) + 10 && r.height >= ts.height + 8) {
        paintText(canvas, t.label, r.topLeft + const Offset(6, 5), title,
            maxWidth: r.width - 10);
        final c = caption(t);
        if (r.height >= ts.height * 2 + 12) {
          paintText(canvas, c, r.topLeft + Offset(6, 7 + ts.height), sub,
              maxWidth: r.width - 10);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_TreePainter old) => true;
}
