/// Tables beyond the data grid: a pivot table and a leaderboard.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'charts/cartesian_chart.dart' show ChartSelect;
import 'charts/chart_frame.dart';
import 'data_widgets.dart';
import 'palette.dart';
import 'values.dart';

double? _aggregate(List<double> vs, String how) {
  if (how == 'count') return vs.length.toDouble();
  if (vs.isEmpty) return null;
  return switch (how) {
    'avg' || 'mean' || 'average' => vs.reduce((a, b) => a + b) / vs.length,
    'min' => vs.reduce(math.min),
    'max' => vs.reduce(math.max),
    _ => vs.reduce((a, b) => a + b),
  };
}

List<String> _fields(Object? v) => [for (final f in asList(v)) if ('$f'.isNotEmpty) '$f'];

/// A pivot table: rows grouped by `rows` (one field or several), columns by
/// `columns`, cells the `aggregate` (sum, count, avg, min, max) of `value`,
/// with totals and cells shaded by magnitude.
class PivotTable extends StatelessWidget {
  const PivotTable({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final data = asRows(props['data']);
    final rowFields = _fields(props['rows']);
    final colFields = _fields(props['columns']);
    final vf = props['value'] == null ? null : '${props['value']}';
    final how = '${props['aggregate'] ?? (vf == null ? 'count' : 'sum')}';
    final format = props['format'] == null ? (how == 'count' ? 'integer' : null) : '${props['format']}';
    final totals = asBool(props['totals'], true);
    final heat = asBool(props['heat'], true);
    String keyOf(Map<String, dynamic> r, List<String> fs) => fs.isEmpty ? 'All' : fs.map((f) => asText(field(r, f))).join(' · ');
    final rowKeys = <String>[], colKeys = <String>[];
    final cells = <String, List<double>>{};
    final rowAll = <String, List<double>>{}, colAll = <String, List<double>>{};
    final all = <double>[];
    for (final r in data) {
      final rk = keyOf(r, rowFields), ck = keyOf(r, colFields);
      if (!rowKeys.contains(rk)) rowKeys.add(rk);
      if (!colKeys.contains(ck)) colKeys.add(ck);
      final v = vf == null ? 1.0 : asNum(field(r, vf))?.toDouble();
      if (v == null) continue;
      (cells['$rk\u0000$ck'] ??= []).add(v);
      (rowAll[rk] ??= []).add(v);
      (colAll[ck] ??= []).add(v);
      all.add(v);
    }
    if (asBool(props['sort'], false)) {
      rowKeys.sort();
      colKeys.sort();
    }
    if (rowKeys.isEmpty) return ChartFrame(title: props['title'] as String?, child: const NoData());
    final values = {for (final e in cells.entries) e.key: _aggregate(e.value, how)};
    final finite = values.values.whereType<double>();
    final lo = finite.isEmpty ? 0.0 : finite.reduce(math.min), hi = finite.isEmpty ? 1.0 : finite.reduce(math.max);
    final color = p.parse(props['color']) ?? p.accent;
    final showCols = colFields.isNotEmpty;

    TextStyle head = VizText.label(p).copyWith(fontSize: 12, fontWeight: FontWeight.w700, color: p.textSecondary);
    TextStyle num0 = VizText.value(p).copyWith(fontSize: 13);
    Widget cell(String text, {TextStyle? style, Color? bg, bool right = true, VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Container(
            color: bg,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            alignment: right ? Alignment.centerRight : Alignment.centerLeft,
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style ?? num0),
          ),
        );
    final header = [
      cell(rowFields.isEmpty ? '' : rowFields.join(' · '), style: head, right: false),
      for (final ck in showCols ? colKeys : const ['Value']) cell(showCols ? ck : (vf == null ? 'Count' : '${how[0].toUpperCase()}${how.substring(1)} of $vf'), style: head),
      if (totals && showCols) cell('Total', style: head),
    ];
    final body = [
      for (final rk in rowKeys)
        [
          cell(rk, style: VizText.value(p).copyWith(fontSize: 13, fontWeight: FontWeight.w600), right: false),
          for (final ck in colKeys)
            () {
              final v = values['$rk\u0000$ck'];
              final t = v == null || hi == lo ? 0.0 : (v - lo) / (hi - lo);
              return cell(v == null ? '—' : formatValue(v, format),
                  bg: heat && v != null ? Color.lerp(Colors.transparent, p.tonal(color, 2.4), t) : null,
                  onTap: onSelect == null || v == null ? null : () => onSelect!({'row': rk, 'column': ck, 'value': v}));
            }(),
          if (totals && showCols) cell(formatValue(_aggregate(rowAll[rk] ?? const [], how), format), style: num0.copyWith(fontWeight: FontWeight.w700)),
        ],
      if (totals && rowKeys.length > 1)
        [
          cell('Total', style: head.copyWith(color: p.textPrimary), right: false),
          for (final ck in colKeys) cell(formatValue(_aggregate(colAll[ck] ?? const [], how), format), style: num0.copyWith(fontWeight: FontWeight.w700)),
          if (showCols) cell(formatValue(_aggregate(all, how), format), style: num0.copyWith(fontWeight: FontWeight.w800)),
        ],
    ];
    final table = Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(horizontalInside: BorderSide(color: p.grid)),
      children: [
        TableRow(decoration: BoxDecoration(color: p.scheme.surfaceContainerHigh), children: header),
        for (final (i, r) in body.indexed)
          TableRow(
            decoration: totals && rowKeys.length > 1 && i == body.length - 1 ? BoxDecoration(color: p.scheme.surfaceContainer) : null,
            children: r,
          ),
      ],
    );
    return ChartFrame(
      title: props['title'] as String?,
      subtitle: props['subtitle'] as String?,
      child: LayoutBuilder(builder: (context, box) {
        Widget out = ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: p.grid), borderRadius: BorderRadius.circular(16)),
            child: table,
          ),
        );
        if (box.maxWidth.isFinite) {
          out = SingleChildScrollView(scrollDirection: Axis.horizontal, child: ConstrainedBox(constraints: BoxConstraints(minWidth: box.maxWidth), child: out));
        }
        final maxH = asNum(props['maxHeight'])?.toDouble();
        if (maxH != null) out = ConstrainedBox(constraints: BoxConstraints(maxHeight: maxH), child: SingleChildScrollView(child: out));
        return out;
      }),
    );
  }
}

/// A leaderboard: rows ranked by value (top three on medal colors), each
/// with an avatar, a name, a subtitle, a bar against the leader and an
/// optional rank change; `highlight` marks one entry (e.g. the viewer).
class Leaderboard extends StatelessWidget {
  const Leaderboard({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  static const _medals = [Color(0xFFE6B422), Color(0xFFA7ADB4), Color(0xFFC0773A)];

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final nf = '${props['label'] ?? props['name'] ?? 'name'}', vf = '${props['value'] ?? 'value'}';
    final rows = asRows(props['data']).indexed.toList()
      ..sort((a, b) => (asNum(field(b.$2, vf)) ?? 0).compareTo(asNum(field(a.$2, vf)) ?? 0));
    final shown = rows.take(asInt(props['max'], 10)).toList();
    final format = props['format'] as String?;
    if (shown.isEmpty) return ChartFrame(title: props['title'] as String?, child: const NoData());
    final top = (asNum(field(shown.first.$2, vf)) ?? 0).toDouble();
    final highlight = props['highlight'] == null ? null : asText(props['highlight']);
    final bar = asBool(props['showBar'], true);
    return ChartFrame(
      title: props['title'] as String?,
      subtitle: props['subtitle'] as String?,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        for (final (rank, (i, r)) in shown.indexed)
          () {
            final name = asText(field(r, nf));
            final v = (asNum(field(r, vf)) ?? 0).toDouble();
            final me = highlight != null && (name == highlight || asText(r['id']) == highlight);
            final change = asNum(r['change'])?.toInt();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Material(
                color: me ? p.scheme.secondaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: onSelect == null ? null : () => onSelect!({'index': i, 'rank': rank + 1, 'row': r}),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: rank < 3 ? p.tonal(_medals[rank], 2.6) : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Text('${rank + 1}',
                            style: VizText.value(p).copyWith(fontWeight: FontWeight.w800, color: rank < 3 ? p.onTonal(_medals[rank]) : p.textSecondary)),
                      ),
                      const SizedBox(width: 10),
                      KitAvatar(name: name, url: (r['avatar'] ?? r['image'] ?? r['url']) as String?, size: 36),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: VizText.title(p).copyWith(fontSize: 14)),
                          if (r['subtitle'] != null) Text(asText(r['subtitle']), maxLines: 1, overflow: TextOverflow.ellipsis, style: VizText.subtitle(p)),
                          if (bar) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: top <= 0 ? 0 : (v / top).clamp(0, 1),
                                minHeight: 5,
                                color: rank < 3 ? _medals[rank] : p.accent,
                                backgroundColor: p.neutral,
                              ),
                            ),
                          ],
                        ]),
                      ),
                      const SizedBox(width: 12),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                        Text(formatValue(v, format), style: VizText.value(p).copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                        if (change != null && change != 0)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(change > 0 ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded, size: 18, color: change > 0 ? VizPalette.good : VizPalette.critical),
                            Text('${change.abs()}', style: VizText.label(p).copyWith(color: change > 0 ? VizPalette.good : VizPalette.critical)),
                          ]),
                      ]),
                    ]),
                  ),
                ),
              ),
            );
          }(),
      ]),
    );
  }
}
