/// A data table: typed, formatted columns, sorting, search, paging, a sticky
/// header, horizontal scrolling when the columns do not fit, and row taps.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'charts/cartesian_chart.dart' show ChartSelect;
import 'charts/polar_charts.dart';
import 'data_widgets.dart';
import 'palette.dart';
import 'values.dart';

class GridColumn {
  GridColumn({
    required this.field,
    required this.label,
    this.type = 'text',
    this.format,
    this.align,
    this.width,
    this.sortable = true,
    this.max,
    this.colors = const {},
    this.color,
  });

  factory GridColumn.fromSpec(Object? spec) {
    final m = spec is Map ? asMap(spec) : {'field': spec};
    final f = '${m['field'] ?? m['key'] ?? m['name'] ?? ''}';
    return GridColumn(
      field: f,
      label: '${m['label'] ?? m['title'] ?? _title(f)}',
      type: '${m['type'] ?? 'text'}',
      format: m['format'] as String?,
      align: m['align'] as String?,
      width: asNum(m['width'])?.toDouble(),
      sortable: asBool(m['sortable'], true),
      max: asNum(m['max'])?.toDouble(),
      colors: asMap(m['colors']),
      color: m['color'] as String?,
    );
  }

  final String field;
  final String label;

  /// text, number, trend (signed, colored with an arrow), badge, progress,
  /// sparkline, image, avatar, link, boolean.
  final String type;
  final String? format;
  final String? align;
  final double? width;
  final bool sortable;

  /// Progress columns: the value of a full bar (default 1 for fractions, else
  /// 100).
  final double? max;

  /// Badge columns: value → color or status name.
  final Map<String, dynamic> colors;

  /// `sign`: number colored by sign (with an arrow), or a color spec.
  final String? color;

  bool get numeric => type == 'number' || type == 'trend' || type == 'progress';

  double get minWidth =>
      width ??
      switch (type) {
        'number' || 'trend' => 96,
        'progress' => 140,
        'sparkline' => 110,
        'image' => 56,
        'boolean' => 72,
        'badge' => 104,
        _ => 128,
      };

  TextAlign get textAlign => switch (align) {
        'end' || 'right' => TextAlign.right,
        'center' => TextAlign.center,
        'start' || 'left' => TextAlign.left,
        _ => numeric ? TextAlign.right : TextAlign.left,
      };
}

String _title(String f) {
  final s = f
      .replaceAll(RegExp(r'[_\-.]'), ' ')
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .trim();
  return s.isEmpty ? f : s[0].toUpperCase() + s.substring(1);
}

class DataGrid extends StatefulWidget {
  const DataGrid({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  State<DataGrid> createState() => _DataGridState();
}

class _DataGridState extends State<DataGrid> {
  String? _sortField;
  bool _ascending = true;
  String _query = '';
  int _page = 0;
  int? _hover;

  @override
  void initState() {
    super.initState();
    _sortField = widget.props['sortBy'] as String?;
    _ascending = widget.props['sortDirection'] != 'desc';
  }

  List<GridColumn> _columns(List<Map<String, dynamic>> rows) {
    final spec = widget.props['columns'];
    if (spec is List && spec.isNotEmpty) {
      return [for (final c in spec) GridColumn.fromSpec(c)]
          .where((c) => c.field.isNotEmpty)
          .toList();
    }
    final first = rows.isEmpty ? const <String, dynamic>{} : rows.first;
    return [
      for (final e in first.entries)
        if (e.value is! Map)
          GridColumn(
              field: e.key,
              label: _title(e.key),
              type: e.value is num
                  ? 'number'
                  : e.value is bool
                      ? 'boolean'
                      : e.value is List
                          ? 'sparkline'
                          : 'text'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final props = widget.props;
    final rows = asRows(props['data'] ?? props['rows']);
    final columns = _columns(rows);
    final dense = asBool(props['dense']);
    final striped = asBool(props['striped']);
    final searchable = asBool(props['search']);
    final sortable = asBool(props['sortable'], true);
    final pageSize = asInt(props['pageSize'], 0);
    final maxHeight = asNum(props['maxHeight'])?.toDouble();
    final rowHeight = dense ? 36.0 : 44.0;

    // Filter, then sort (stable, by original index), then page.
    var indices = [for (var i = 0; i < rows.length; i++) i];
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      indices = indices
          .where((i) => columns.any((c) =>
              formatValue(field(rows[i], c.field), c.format)
                  .toLowerCase()
                  .contains(q)))
          .toList();
    }
    if (_sortField != null) {
      int cmp(int a, int b) {
        final x = field(rows[a], _sortField), y = field(rows[b], _sortField);
        final nx = asNum(x), ny = asNum(y);
        int c;
        if (nx != null && ny != null) {
          c = nx.compareTo(ny);
        } else if (x == null || y == null) {
          c = x == null ? (y == null ? 0 : 1) : -1;
          return c == 0 ? a.compareTo(b) : c; // nulls last either way
        } else {
          c = asText(x).toLowerCase().compareTo(asText(y).toLowerCase());
        }
        if (!_ascending) c = -c;
        return c == 0 ? a.compareTo(b) : c;
      }

      indices.sort(cmp);
    }
    final total = indices.length;
    final pages = pageSize > 0 ? math.max(1, (total / pageSize).ceil()) : 1;
    final page = _page.clamp(0, pages - 1);
    final visible = pageSize > 0
        ? indices.skip(page * pageSize).take(pageSize).toList()
        : indices;

    final header = TextStyle(
        fontSize: 12, fontWeight: FontWeight.w600, color: p.textSecondary);
    final body = TextStyle(
        fontSize: dense ? 12.5 : 13.5,
        color: p.textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()]);

    Widget cellBox(GridColumn c, double width, Widget child) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 12),
            child: Align(
              alignment: switch (c.textAlign) {
                TextAlign.right => Alignment.centerRight,
                TextAlign.center => Alignment.center,
                _ => Alignment.centerLeft,
              },
              child: child,
            ),
          ),
        );

    return LayoutBuilder(builder: (context, box) {
      final available = box.maxWidth.isFinite ? box.maxWidth : 800.0;
      final minTotal = columns.fold<double>(0, (s, c) => s + c.minWidth);
      final scroll = minTotal > available;
      final scale = scroll ? 1.0 : available / math.max(1, minTotal);
      final widths = [for (final c in columns) c.minWidth * scale];
      final tableWidth = scroll ? minTotal : available;

      Widget headerRow = Container(
        height: rowHeight,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.axis)),
        ),
        child: Row(children: [
          for (var k = 0; k < columns.length; k++)
            cellBox(
              columns[k],
              widths[k],
              InkWell(
                onTap: sortable && columns[k].sortable
                    ? () => setState(() {
                          if (_sortField == columns[k].field) {
                            _ascending = !_ascending;
                          } else {
                            _sortField = columns[k].field;
                            _ascending = !columns[k].numeric;
                          }
                        })
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(columns[k].label,
                          overflow: TextOverflow.ellipsis,
                          textAlign: columns[k].textAlign,
                          style: header),
                    ),
                    if (_sortField == columns[k].field)
                      Icon(
                          _ascending
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          size: 14,
                          color: p.textSecondary),
                  ],
                ),
              ),
            ),
        ]),
      );

      final rowWidgets = [
        for (var r = 0; r < visible.length; r++)
          MouseRegion(
            onEnter: (_) => setState(() => _hover = visible[r]),
            onExit: (_) => setState(() => _hover = null),
            cursor: widget.onSelect != null
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onSelect == null
                  ? null
                  : () => widget.onSelect!(
                      {'index': visible[r], 'row': rows[visible[r]]}),
              child: Container(
                height: rowHeight,
                decoration: BoxDecoration(
                  color: _hover == visible[r] && widget.onSelect != null
                      ? p.hover
                      : striped && r.isOdd
                          ? p.hover.withValues(alpha: 0.5)
                          : null,
                  border: Border(bottom: BorderSide(color: p.grid)),
                ),
                child: Row(children: [
                  for (var k = 0; k < columns.length; k++)
                    cellBox(columns[k], widths[k],
                        _cell(columns[k], rows[visible[r]], body, p)),
                ]),
              ),
            ),
          ),
      ];

      Widget bodyList = rowWidgets.isEmpty
          ? SizedBox(
              height: rowHeight * 1.5,
              child: Center(
                  child: Text('${props['emptyText'] ?? 'No rows'}',
                      style: VizText.subtitle(p))),
            )
          : Column(mainAxisSize: MainAxisSize.min, children: rowWidgets);
      if (maxHeight != null) {
        bodyList = ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: math.max(rowHeight, maxHeight - rowHeight)),
          child: SingleChildScrollView(child: bodyList),
        );
      }
      Widget table = SizedBox(
        width: tableWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [headerRow, bodyList],
        ),
      );
      if (scroll) {
        table = SingleChildScrollView(
            scrollDirection: Axis.horizontal, child: table);
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (props['title'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${props['title']}', style: VizText.title(p)),
            ),
          if (searchable)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: '${props['searchHint'] ?? 'Search'}',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() {
                  _query = v.trim();
                  _page = 0;
                }),
              ),
            ),
          table,
          if (pageSize > 0 && total > pageSize)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                      '${page * pageSize + 1}–${math.min(total, (page + 1) * pageSize)} of $total',
                      style: VizText.label(p).copyWith(fontSize: 12)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Previous',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: page > 0
                        ? () => setState(() => _page = page - 1)
                        : null,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Next',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: page < pages - 1
                        ? () => setState(() => _page = page + 1)
                        : null,
                  ),
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _cell(
      GridColumn c, Map<String, dynamic> row, TextStyle style, VizPalette p) {
    final v = field(row, c.field);
    switch (c.type) {
      case 'trend':
        return TrendText(
            value: asNum(v), format: c.format ?? '+number', style: style);
      case 'badge':
        if (v == null) return const SizedBox.shrink();
        final text = formatValue(v, c.format);
        return Pill(
            text: text,
            color: p.parse(c.colors[text] ?? c.colors['$v']) ??
                p.parse(text.toLowerCase()) ??
                p.series(0));
      case 'progress':
        final n = asNum(v)?.toDouble();
        if (n == null) return const SizedBox.shrink();
        final max = c.max ?? (n <= 1 ? 1 : 100);
        return Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (n / max).clamp(0, 1),
                minHeight: 6,
                color: p.parse(c.color) ?? p.series(0),
                backgroundColor:
                    (p.parse(c.color) ?? p.series(0)).withValues(alpha: 0.18),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(formatValue(n, c.format ?? (max == 1 ? 'percent' : null)),
              style: style.copyWith(fontSize: 12)),
        ]);
      case 'sparkline':
        return Sparkline(values: [
          for (final x in asList(v))
            asNum(x is Map ? x['value'] : x)?.toDouble()
        ], height: 24, color: p.parse(c.color));
      case 'image':
        final url = asText(v);
        if (url.isEmpty) return const SizedBox.shrink();
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.network(url,
              width: 28,
              height: 28,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const SizedBox(width: 28, height: 28)),
        );
      case 'avatar':
        return Row(mainAxisSize: MainAxisSize.min, children: [
          KitAvatar(name: asText(v), size: 24),
          const SizedBox(width: 8),
          Flexible(
              child: Text(asText(v),
                  overflow: TextOverflow.ellipsis, style: style)),
        ]);
      case 'boolean':
        final b = asBool(v);
        return Icon(b ? Icons.check_circle : Icons.remove_circle_outline,
            size: 18, color: b ? VizPalette.good : p.textMuted);
      case 'link':
        return Text(formatValue(v, c.format),
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(
                color: p.scheme.primary, decoration: TextDecoration.underline));
    }
    if (c.color == 'sign') {
      return TrendText(
          value: asNum(v), format: c.format, style: style, arrow: false);
    }
    final color = p.parse(c.color);
    return Text(formatValue(v, c.format),
        overflow: TextOverflow.ellipsis,
        textAlign: c.textAlign,
        style: color == null ? style : style.copyWith(color: color));
  }
}
