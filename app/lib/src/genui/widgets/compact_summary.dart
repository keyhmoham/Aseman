/// A frontend's compact digest — what a phone-board widget shows about the
/// data the frontend shows in full — and its view.
///
/// A digest is made of blocks, each optional: a hero metric (value, delta,
/// trend, progress), a mini chart (area, bars, candles, donut), a mini list
/// of rows, metrics, status chips, a thumbnail, a title and a caption. The
/// view lays them out for the widget's size (small 1×1, medium 2×1, large
/// 2×2) and shape, in the tool's accent color.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../elpian/core/media.dart';
import '../../features/tools/ui_kit/kit.dart' as kit;
import '../catalog/style.dart';
import '../runtime/format.dart';
import '../runtime/presentation.dart';

String _s(Object? v) => v == null ? '' : stringifyValue(v);
String? _f(Object? v) => v is String && v.isNotEmpty ? v : null;
List<Object?> _list(Object? v) => v is List ? v : const [];
Map<Object?, Object?> _map(Object? v) => v is Map ? v : const {};

/// Formats [v] by [format], or picks a readable form of a number.
String formatCompactValue(Object? v, [String? format]) {
  if (format != null) return kit.formatValue(v, format);
  final n = v is num ? v : null;
  if (n == null) return stringifyValue(v);
  if (n.abs() >= 100000) return kit.formatCompact(n);
  return specFormatNumber({
    'value': n,
    'decimals': n == n.roundToDouble() ? 0 : (n.abs() < 10 ? 2 : 1),
  });
}

/// The headline number.
class CompactHero {
  const CompactHero({
    this.label = '',
    this.value,
    this.format,
    this.delta,
    this.deltaFormat,
    this.deltaLabel = '',
    this.goodDown = false,
    this.progress,
    this.status = '',
    this.trend = const [],
  });

  factory CompactHero.fromJson(Map<Object?, Object?> m) {
    final progress = m['progress'];
    num? fraction;
    if (progress is Map) {
      final v = toNum(progress['value']);
      final min = toNum(progress['min']) ?? 0;
      final max = toNum(progress['max']) ?? 1;
      if (v != null && max > min) fraction = (v - min) / (max - min);
    } else {
      fraction = toNum(progress);
    }
    return CompactHero(
      label: _s(m['label'] ?? m['title']),
      value: m['value'],
      format: _f(m['format']),
      delta: toNum(m['delta']),
      deltaFormat: _f(m['deltaFormat']),
      deltaLabel: _s(m['deltaLabel']),
      goodDown: m['goodDirection'] == 'down',
      progress: fraction?.clamp(0, 1),
      status: _s(m['status']),
      trend: CompactSummary.trendOf(m['trend']),
    );
  }

  final String label;
  final Object? value;
  final String? format;
  final num? delta;
  final String? deltaFormat;
  final String deltaLabel;
  final bool goodDown;
  final num? progress;
  final String status;
  final List<num> trend;

  bool get hasValue => value != null && _s(value).isNotEmpty;
  String get shown => formatCompactValue(value, format);
}

/// A small chart: `area` (line), `bar`, `candle` (closes) or `donut`.
class CompactChart {
  const CompactChart(
      {this.kind = 'area',
      this.values = const [],
      this.labels = const [],
      this.format});

  factory CompactChart.fromJson(Map<Object?, Object?> m) {
    final kind = '${m['kind'] ?? m['type'] ?? 'area'}';
    final rows = _list(m['rows'] ?? m['data']);
    final field = _f(m['field']);
    final labelField = _f(m['labelField']);
    final values = <num>[];
    final labels = <String>[];
    if (m['values'] is List) {
      for (final v in m['values'] as List) {
        if (toNum(v) case final num n) values.add(n);
      }
    } else {
      for (final r in rows) {
        final n = toNum(r is Map
            ? kit.field(r, field ?? CompactSummary._guessField(r))
            : r);
        if (n == null) continue;
        values.add(n);
        labels.add(r is Map && labelField != null
            ? _s(kit.field(r, labelField))
            : r is Map
                ? _s(r[CompactSummary._guessLabel(r)])
                : '');
      }
    }
    return CompactChart(
        kind: switch (kind) {
          'line' || 'scatter' || 'bubble' => 'area',
          'histogram' => 'bar',
          'candlestick' => 'candle',
          'pie' || 'treemap' => 'donut',
          _ => kind,
        },
        values: values,
        labels: labels,
        format: _f(m['format']));
  }

  final String kind;
  final List<num> values;
  final List<String> labels;
  final String? format;

  bool get isEmpty => values.length < (kind == 'donut' ? 1 : 2);
}

/// One row of a mini list.
class CompactRow {
  const CompactRow(
      {required this.title,
      this.subtitle = '',
      this.value = '',
      this.delta,
      this.deltaFormat,
      this.image = '',
      this.status = ''});

  final String title;
  final String subtitle;
  final String value;
  final num? delta;
  final String? deltaFormat;
  final String image;
  final String status;
}

/// A short list: the first rows of a table, list or timeline.
class CompactList {
  const CompactList({this.rows = const [], this.total = 0, this.label = ''});

  /// From `{rows, title?, subtitle?, value?, valueFormat?, delta?,
  /// deltaFormat?, image?, status?, label?}` (field names of each row; the
  /// ones not given are guessed), or `{items: [{title, subtitle, value,
  /// delta}]}`.
  factory CompactList.fromJson(Map<Object?, Object?> m) {
    if (m['items'] is List) {
      final items = [
        for (final i in m['items'] as List)
          if (i is Map)
            CompactRow(
              title: _s(i['title'] ?? i['label'] ?? i['name']),
              subtitle: _s(i['subtitle'] ?? i['caption']),
              value: formatCompactValue(i['value'], _f(i['format'])),
              delta: toNum(i['delta']),
              deltaFormat: _f(i['deltaFormat']),
              image: _s(i['image']),
              status: _s(i['status']),
            )
      ];
      return CompactList(
          rows: items, total: items.length, label: _s(m['label']));
    }
    final rows = [
      for (final r in _list(m['rows'] ?? m['data']))
        if (r is Map) r
    ];
    if (rows.isEmpty) return CompactList(label: _s(m['label']));
    final first = rows.first;
    String? pick(Object? given, bool Function(String key, Object? v) test,
        {Set<String> not = const {}}) {
      if (given is String && given.isNotEmpty) return given;
      for (final e in first.entries) {
        final k = '${e.key}';
        if (!not.contains(k) && test(k, e.value)) return k;
      }
      return null;
    }

    const names = [
      'symbol', 'name', 'title', 'label', 'ticker', 'asset', 'id', //
    ];
    final title = _f(m['title']) ??
        names.firstWhere((n) => first[n] is String, orElse: () => '');
    final titleField = title.isNotEmpty
        ? title
        : pick(null, (k, v) => v is String && v.isNotEmpty) ?? '';
    final change = RegExp(r'change|pct|percent|delta|return|diff|move',
        caseSensitive: false);
    final deltaField =
        pick(m['delta'], (k, v) => v is num && change.hasMatch(k));
    final valueField = pick(m['value'], (k, v) => v is num,
        not: {if (deltaField != null) deltaField});
    final imageField = pick(m['image'],
        (k, v) => v is String && RegExp(r'^(image|logo|avatar|icon|url)$').hasMatch(k));
    final subtitleField = pick(
        m['subtitle'],
        (k, v) =>
            v is String &&
            v.isNotEmpty &&
            !RegExp(r'^(id|url|image|logo|avatar|icon)$').hasMatch(k),
        not: {titleField, if (imageField != null) imageField});
    final valueFormat = _f(m['valueFormat']);
    final deltaFormat = _f(m['deltaFormat']) ??
        (deltaField != null && rows.every((r) {
          final n = toNum(r[deltaField]);
          return n == null || n.abs() <= 1.5;
        })
            ? '+percent:2'
            : '+number:2');
    final statusField = _f(m['status']);
    return CompactList(
      total: rows.length,
      label: _s(m['label']),
      rows: [
        for (final r in rows.take(6))
          CompactRow(
            title: _s(kit.field(r, titleField)),
            subtitle: subtitleField == null
                ? ''
                : _s(kit.field(r, subtitleField)),
            value: valueField == null
                ? ''
                : formatCompactValue(kit.field(r, valueField), valueFormat),
            delta: deltaField == null ? null : toNum(kit.field(r, deltaField)),
            deltaFormat: deltaFormat,
            image: imageField == null ? '' : _s(kit.field(r, imageField)),
            status: statusField == null ? '' : _s(kit.field(r, statusField)),
          ),
      ],
    );
  }

  final List<CompactRow> rows;
  final int total;
  final String label;

  bool get isEmpty => rows.isEmpty;
}

/// One secondary value.
class CompactMetric {
  const CompactMetric(
      {required this.label,
      this.value,
      this.format,
      this.delta,
      this.deltaFormat});

  final String label;
  final Object? value;
  final String? format;
  final num? delta;
  final String? deltaFormat;

  String get shown => formatCompactValue(value, format);
}

/// A status chip.
class CompactChip {
  const CompactChip(this.text, [this.status = '']);
  final String text;
  final String status;
}

/// What a compact widget shows. Static programs publish it
/// (`tool.compact`); for A2UI surfaces it is derived from their components
/// and data when they bring no `compact` component of their own.
class CompactSummary {
  const CompactSummary({
    this.title = '',
    this.caption = '',
    this.icon = '',
    this.image = '',
    this.hero,
    this.chart,
    this.list,
    this.metrics = const [],
    this.chips = const [],
  });

  /// From JSON: `{title?, caption?, icon?, image?, hero?: {label, value,
  /// format, delta, deltaFormat, deltaLabel, goodDirection, progress, status,
  /// trend}, chart?: {kind, values | rows + field + labelField, format},
  /// list?: {rows, title, subtitle, value, valueFormat, delta, …} | {items},
  /// metrics?: [{label, value, format, delta, deltaFormat}], chips?:
  /// [{text, status}], data?: (the data model — what is shown when nothing
  /// else is)}`. The flat form of earlier summaries (`value`, `delta`,
  /// `trend`, `progress`, `badge`, …) reads as the hero.
  factory CompactSummary.fromJson(Object? json) {
    final m = _map(json);
    var hero = m['hero'] is Map ? CompactHero.fromJson(m['hero'] as Map) : null;
    if (hero == null &&
        (m.containsKey('value') ||
            m.containsKey('progress') ||
            m.containsKey('trend'))) {
      hero = CompactHero.fromJson({...m, 'label': m['label'] ?? m['title']});
    }
    var chart = m['chart'] is Map
        ? CompactChart.fromJson(m['chart'] as Map)
        : null;
    if (chart != null && chart.isEmpty) chart = null;
    if (chart == null && hero != null && hero.trend.length >= 2) {
      chart = CompactChart(values: hero.trend);
    }
    var list = m['list'] is Map ? CompactList.fromJson(m['list'] as Map) : null;
    if (list != null && list.isEmpty) list = null;
    final metrics = [
      for (final x in _list(m['metrics']))
        if (x is Map && x['value'] != null)
          CompactMetric(
            label: _s(x['label']),
            value: x['value'],
            format: _f(x['format']),
            delta: toNum(x['delta']),
            deltaFormat: _f(x['deltaFormat']),
          ),
    ];
    final chips = [
      for (final c in _list(m['chips']))
        if (c is Map && _s(c['text']).isNotEmpty)
          CompactChip(_s(c['text']), _s(c['status']))
        else if (c is String && c.isNotEmpty)
          CompactChip(c),
      if (_s(m['badge']).isNotEmpty) CompactChip(_s(m['badge']), _s(m['status'])),
    ];
    // A KeyValue's object: its scalars.
    if (m['kv'] is Map) {
      for (final e in (m['kv'] as Map).entries) {
        if (metrics.length >= 6) break;
        if (e.value is num || (e.value is String && '${e.value}'.length <= 40)) {
          metrics.add(CompactMetric(
              label: CompactSummary._humanize('${e.key}'), value: e.value));
        }
      }
    }
    // An order book: best bid and ask, and the spread.
    if (m['orderBook'] is Map) {
      final book = m['orderBook'] as Map;
      num? best(Object? side) {
        final first = _list(side).firstOrNull;
        return toNum(first is Map ? first['price'] : first is List ? first.first : null);
      }

      final bid = best(book['bids']), ask = best(book['asks']);
      if (bid != null) metrics.add(CompactMetric(label: 'Bid', value: bid));
      if (ask != null) metrics.add(CompactMetric(label: 'Ask', value: ask));
      if (bid != null && ask != null) {
        hero ??= CompactHero(
            label: 'Spread',
            value: ask - bid,
            format: 'number:2',
            deltaLabel: '');
      }
    }
    var summary = CompactSummary(
      title: _s(m['title']),
      caption: _s(m['caption']),
      icon: _s(m['icon']),
      image: _s(m['image']),
      hero: hero == null || (!hero.hasValue && hero.progress == null)
          ? null
          : hero,
      chart: chart,
      list: list,
      metrics: metrics,
      chips: chips,
    );
    if (summary.isThin && m['data'] is Map) {
      summary = summary.withData(m['data'] as Map);
    }
    return summary;
  }

  /// Numbers of a trend: a list (of numbers, or of rows), or `{rows,
  /// field}`.
  static List<num> trendOf(Object? v, [String? field]) {
    if (v is Map) return trendOf(v['rows'] ?? v['data'], v['field'] as String?);
    if (v is! List) return const [];
    return [
      for (final x in v)
        if (toNum(x is Map ? kit.field(x, field ?? _guessField(x)) : x)
            case final num n)
          n
    ];
  }

  static String _guessField(Map<Object?, Object?> row) {
    for (final k in ['value', 'close', 'price', 'y', 'total', 'amount']) {
      if (row[k] is num) return k;
    }
    return row.keys
        .firstWhere((k) => row[k] is num, orElse: () => 'value')
        .toString();
  }

  static String _guessLabel(Map<Object?, Object?> row) {
    for (final k in ['label', 'name', 'symbol', 'x', 'date', 'day', 'time']) {
      if (row[k] != null) return k;
    }
    return row.keys
        .firstWhere((k) => row[k] is String, orElse: () => 'label')
        .toString();
  }

  final String title;
  final String caption;
  final String icon;
  final String image;
  final CompactHero? hero;
  final CompactChart? chart;
  final CompactList? list;
  final List<CompactMetric> metrics;
  final List<CompactChip> chips;

  /// Nothing but words.
  bool get isThin =>
      hero == null && chart == null && list == null && metrics.isEmpty;

  bool get isEmpty => isThin && chips.isEmpty && title.isEmpty && caption.isEmpty;

  /// How many blocks it has (a rich digest suits a large widget).
  int get richness => [
        hero != null,
        chart != null,
        list != null,
        metrics.length >= 2,
        chips.isNotEmpty,
      ].where((b) => b).length;

  /// This digest filled from a data model: its first number as the hero,
  /// its first list of records as the list (or the chart, for a series of
  /// numbers), its other scalars as metrics.
  CompactSummary withData(Map<Object?, Object?> data) {
    CompactHero? hero = this.hero;
    CompactList? list = this.list;
    CompactChart? chart = this.chart;
    final metrics = [...this.metrics];
    var caption = this.caption;
    void visit(Map<Object?, Object?> m, String prefix, int depth) {
      for (final e in m.entries) {
        final key = '${e.key}';
        final label = _humanize(prefix.isEmpty ? key : key);
        final v = e.value;
        if (v is num) {
          if (hero == null) {
            hero = CompactHero(label: label, value: v);
          } else if (metrics.length < 4) {
            metrics.add(CompactMetric(label: label, value: v));
          }
        } else if (v is List && v.isNotEmpty) {
          if (v.first is Map && list == null) {
            final l = CompactList.fromJson({'rows': v, 'label': label});
            if (!l.isEmpty) list = l;
          } else if (v.first is num && chart == null && v.length >= 2) {
            chart = CompactChart(values: [for (final x in v) toNum(x) ?? 0]);
          }
        } else if (v is String && v.isNotEmpty && v.length <= 80) {
          if (metrics.length < 4 && depth > 0) {
            metrics.add(CompactMetric(label: label, value: v));
          } else if (caption.isEmpty && depth == 0) {
            caption = v;
          }
        } else if (v is Map && depth < 2) {
          visit(v, key, depth + 1);
        }
      }
    }

    visit(data, '', 0);
    return CompactSummary(
      title: title,
      caption: caption,
      icon: icon,
      image: image,
      hero: hero,
      chart: chart,
      list: list,
      metrics: metrics,
      chips: chips,
    );
  }

  /// This digest without the titles that repeat [shown] (lower case), the
  /// name its widget's header already shows.
  CompactSummary untitled(String shown) {
    bool same(String t) => t.trim().toLowerCase() == shown;
    final list = this.list;
    return CompactSummary(
      title: same(title) ? '' : title,
      caption: caption,
      icon: icon,
      image: image,
      hero: hero,
      chart: chart,
      list: list != null && same(list.label)
          ? CompactList(rows: list.rows, total: list.total)
          : list,
      metrics: metrics,
      chips: chips,
    );
  }

  static String _humanize(String key) {
    final words = key
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .trim();
    return words.isEmpty ? key : words[0].toUpperCase() + words.substring(1);
  }
}

/// A [CompactSummary] laid out for the widget it stands in (the size, shape
/// and accent of the enclosing [FrontendPresentation]).
class CompactSummaryView extends StatelessWidget {
  const CompactSummaryView({super.key, required this.summary});

  final CompactSummary summary;

  @override
  Widget build(BuildContext context) {
    final presentation = FrontendPresentation.maybeOf(context);
    final scheme = Theme.of(context).colorScheme;
    final accent = presentation?.accent ?? scheme.primary;
    final size = presentation?.size ?? 'medium';
    final round =
        presentation?.shape == 'circle' || presentation?.shape == 'pill';
    // The widget's header names it already: no second title.
    // (A small widget's header is its icon alone: it keeps them.)
    final shown = size == 'small' || presentation?.shape == 'circle'
        ? ''
        : presentation?.title.trim().toLowerCase() ?? '';
    return LayoutBuilder(builder: (context, box) {
      final s = shown.isEmpty ? summary : summary.untitled(shown);
      if (s.isEmpty) return const SizedBox.shrink();
      if (size == 'small' || presentation?.shape == 'circle') {
        return _Small(summary: s, accent: accent, centered: round);
      }
      if (size == 'large' && box.maxHeight > 200) {
        return _Large(summary: s, accent: accent);
      }
      return _Medium(summary: s, accent: accent, height: box.maxHeight);
    });
  }
}

// ---------------------------------------------------------------------------
// Layouts
// ---------------------------------------------------------------------------

class _Small extends StatelessWidget {
  const _Small(
      {required this.summary, required this.accent, required this.centered});
  final CompactSummary summary;
  final Color accent;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final hero = s.hero;
    final align = centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    if (hero != null && hero.progress != null) {
      return _Ring(hero: hero, accent: accent);
    }
    if (hero == null && s.chart?.kind == 'donut') {
      return _Donut(chart: s.chart!, legend: false, center: true);
    }
    if (hero == null && s.list != null) {
      return _Count(
          list: s.list!,
          label: s.list!.label.isNotEmpty ? s.list!.label : s.title,
          accent: accent,
          centered: centered);
    }
    if (hero == null) {
      return _Words(summary: s, accent: accent, centered: centered);
    }
    return Column(
      crossAxisAlignment: align,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (hero.label.isNotEmpty)
          _Label(hero.label, center: centered),
        _HeroValue(hero: hero, size: 24, centered: centered),
        if (hero.delta != null) ...[
          const SizedBox(height: 4),
          _DeltaPill(
              delta: hero.delta!,
              format: hero.deltaFormat,
              goodDown: hero.goodDown),
        ],
        if (s.chart != null && s.chart!.kind != 'donut') ...[
          const SizedBox(height: 6),
          Flexible(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 30),
                  child: _MiniChart(chart: s.chart!, accent: accent))),
        ] else if (s.caption.isNotEmpty || s.metrics.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
              s.caption.isNotEmpty
                  ? s.caption
                  : '${s.metrics.first.label} ${s.metrics.first.shown}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: genUiTextStyle(context, 'caption').copyWith(fontSize: 11)),
        ],
      ],
    );
  }
}

class _Medium extends StatelessWidget {
  const _Medium(
      {required this.summary, required this.accent, required this.height});
  final CompactSummary summary;
  final Color accent;
  final double height;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final hero = s.hero;
    // The side block: a chart, else the list, else metrics.
    final Widget? side = s.chart != null
        ? (s.metrics.isNotEmpty && height > 104
            // A chart over the first further figure.
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                    Expanded(child: _MiniChart(chart: s.chart!, accent: accent)),
                    const SizedBox(height: 6),
                    SizedBox(
                        height: 36,
                        child: _Metrics(
                            metrics: s.metrics, max: 1, inline: true)),
                  ])
            : _MiniChart(chart: s.chart!, accent: accent))
        : s.list != null
            ? _MiniList(list: s.list!, accent: accent, max: 3, dense: true)
            : s.metrics.isNotEmpty
                ? _Metrics(metrics: s.metrics, max: 3)
                : s.image.isNotEmpty
                    ? _Thumb(url: s.image)
                    : null;
    if (hero == null) {
      if (s.list != null) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (s.title.isNotEmpty || s.list!.label.isNotEmpty)
            _Label(s.title.isNotEmpty ? s.title : s.list!.label,
                trailing: s.list!.total > 3 ? '${s.list!.total}' : null),
          Expanded(
              child: _MiniList(
                  list: s.list!,
                  accent: accent,
                  max: math.max(1, (height / 30).floor()),
                  dense: true)),
        ]);
      }
      if (s.chart != null) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (s.title.isNotEmpty) _Label(s.title),
          Expanded(
              child: s.chart!.kind == 'donut'
                  ? _Donut(chart: s.chart!, legend: true)
                  : _MiniChart(chart: s.chart!, accent: accent)),
        ]);
      }
      if (s.metrics.isNotEmpty) {
        return _Metrics(metrics: s.metrics, max: 4, grid: true);
      }
      return _Words(summary: s, accent: accent, centered: false);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        flex: 5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (hero.label.isNotEmpty) _Label(hero.label),
            _HeroValue(hero: hero, size: 26),
            Row(children: [
              if (hero.delta != null)
                _DeltaPill(
                    delta: hero.delta!,
                    format: hero.deltaFormat,
                    goodDown: hero.goodDown),
              if (hero.deltaLabel.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                    child: Text(hero.deltaLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: genUiTextStyle(context, 'caption')
                            .copyWith(fontSize: 11))),
              ],
              if (hero.delta == null && s.chips.isNotEmpty)
                Flexible(child: _Chips(chips: s.chips, max: 2)),
            ]),
            if (hero.progress != null)
              _Bar(progress: hero.progress!, accent: accent, status: hero.status),
          ],
        ),
      ),
      if (side != null) ...[
        const SizedBox(width: 12),
        Expanded(flex: 4, child: side),
      ],
    ]);
  }
}

class _Large extends StatelessWidget {
  const _Large({required this.summary, required this.accent});
  final CompactSummary summary;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final hero = s.hero;
    final blocks = <Widget>[];
    if (hero != null) {
      blocks.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (hero.label.isNotEmpty) _Label(hero.label),
            _HeroValue(hero: hero, size: 32),
            const SizedBox(height: 4),
            Row(children: [
              if (hero.delta != null)
                _DeltaPill(
                    delta: hero.delta!,
                    format: hero.deltaFormat,
                    goodDown: hero.goodDown),
              if (hero.deltaLabel.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                    child: Text(hero.deltaLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: genUiTextStyle(context, 'caption')
                            .copyWith(fontSize: 11))),
              ],
            ]),
          ]),
        ),
        if (hero.progress != null)
          SizedBox(
              width: 64, height: 64, child: _Ring(hero: hero, accent: accent))
        else if (s.image.isNotEmpty)
          SizedBox(width: 64, height: 64, child: _Thumb(url: s.image)),
      ]));
    } else if (s.title.isNotEmpty) {
      blocks.add(Text(s.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: genUiTextStyle(context, 'h5')));
    }
    // (Blocks with their flex: a list takes more room than a chart.)
    final flexible = <(Widget, int)>[];
    if (s.chart != null) {
      flexible.add((s.chart!.kind == 'donut'
          ? _Donut(chart: s.chart!, legend: true)
          : _MiniChart(chart: s.chart!, accent: accent, axisLabels: true), 2));
    }
    if (s.list != null) {
      flexible.add((
        LayoutBuilder(builder: (context, box) {
          // Every row when they all fit, else as many as fit (rows a little
          // tighter when that shows one more) above the "more" line.
          final all = s.list!.rows.length;
          final room = box.maxHeight - 18;
          final roomy = (room / 40).floor();
          final tight = (room / 34).floor();
          final rowHeight = tight > roomy && roomy < all ? 34.0 : 40.0;
          final max = all * 40 <= box.maxHeight
              ? all
              : (room / rowHeight).floor();
          return _MiniList(
              list: s.list!,
              accent: accent,
              max: math.max(1, max),
              rowHeight: rowHeight);
        }),
        3
      ));
    } else if (s.metrics.isNotEmpty) {
      flexible.add((_Metrics(metrics: s.metrics, max: 4, grid: true), 2));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...blocks,
      for (final (f, flex) in flexible) ...[
        const SizedBox(height: 10),
        Expanded(flex: flex, child: f),
      ],
      if (flexible.isEmpty) const Spacer(),
      if (s.list != null && s.metrics.isNotEmpty) ...[
        const SizedBox(height: 8),
        SizedBox(height: 36, child: _Metrics(metrics: s.metrics, max: 3, inline: true)),
      ],
      if (s.chips.isNotEmpty && (hero?.delta != null || hero == null)) ...[
        const SizedBox(height: 8),
        _Chips(chips: s.chips, max: 4),
      ],
      if (s.caption.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(s.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: genUiTextStyle(context, 'caption').copyWith(fontSize: 11.5)),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _Label extends StatelessWidget {
  const _Label(this.text, {this.center = false, this.trailing});
  final String text;
  final bool center;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: .3,
        color: Theme.of(context).colorScheme.onSurfaceVariant);
    final label = Text(text.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: style);
    if (trailing == null) return label;
    return Row(children: [
      Expanded(child: label),
      Text(trailing!, style: style),
    ]);
  }
}

class _HeroValue extends StatelessWidget {
  const _HeroValue(
      {required this.hero, required this.size, this.centered = false});
  final CompactHero hero;
  final double size;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = hero.status.isEmpty
        ? null
        : kit.VizPalette.of(context).status(hero.status);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: centered ? Alignment.center : Alignment.centerLeft,
      child: Text(hero.hasValue ? hero.shown : '—',
          maxLines: 1,
          style: TextStyle(
              fontSize: size,
              height: 1.1,
              fontWeight: FontWeight.w800,
              letterSpacing: -.6,
              color: status ?? scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()])),
    );
  }
}

/// A signed change as a tinted pill with its direction.
class _DeltaPill extends StatelessWidget {
  const _DeltaPill(
      {required this.delta, this.format, this.goodDown = false});
  final num delta;
  final String? format;
  final bool goodDown;

  @override
  Widget build(BuildContext context) {
    final up = delta > 0, down = delta < 0;
    final good = goodDown ? down : up;
    final color = up || down
        ? (good ? kit.VizPalette.good : kit.VizPalette.critical)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final f = format ?? '+percent:2';
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
            up
                ? Icons.arrow_drop_up_rounded
                : down
                    ? Icons.arrow_drop_down_rounded
                    : Icons.remove_rounded,
            size: 18,
            color: color),
        Text(kit.formatValue(delta, f.startsWith('+') ? f : '+$f'),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

class _MiniChart extends StatelessWidget {
  const _MiniChart(
      {required this.chart, required this.accent, this.axisLabels = false});
  final CompactChart chart;
  final Color accent;
  final bool axisLabels;

  @override
  Widget build(BuildContext context) {
    if (chart.kind == 'donut') return _Donut(chart: chart, legend: true);
    final values = chart.values;
    final rising = values.isEmpty || values.last >= values.first;
    final color = chart.kind == 'bar'
        ? accent
        : rising
            ? kit.VizPalette.good
            : kit.VizPalette.critical;
    final min = values.reduce(math.min), max = values.reduce(math.max);
    final palette = kit.VizPalette.of(context);
    return LayoutBuilder(builder: (context, box) {
      final h = box.maxHeight.isFinite ? box.maxHeight : 60.0;
      final spark = kit.Sparkline(
        values: [for (final v in values) v.toDouble()],
        color: color,
        height: math.max(12, axisLabels ? h - 16 : h),
        bars: chart.kind == 'bar',
        area: chart.kind != 'bar',
      );
      if (!axisLabels || h < 60) return spark;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: spark),
        const SizedBox(height: 2),
        Row(children: [
          Text(chart.labels.isNotEmpty ? chart.labels.first : '',
              style: kit.VizText.label(palette)),
          const Spacer(),
          Text(
              'L ${formatCompactValue(min, chart.format)}  ·  H ${formatCompactValue(max, chart.format)}',
              style: kit.VizText.label(palette)),
          const Spacer(),
          Text(chart.labels.isNotEmpty ? chart.labels.last : '',
              style: kit.VizText.label(palette)),
        ]),
      ]);
    });
  }
}

class _Donut extends StatelessWidget {
  const _Donut(
      {required this.chart, required this.legend, this.center = false});
  final CompactChart chart;
  final bool legend;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final palette = kit.VizPalette.of(context);
    final slices = <(String, num)>[
      for (var i = 0; i < chart.values.length; i++)
        (i < chart.labels.length ? chart.labels[i] : '', chart.values[i])
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final top = slices.take(4).toList();
    final rest = slices.skip(4).fold<num>(0, (s, x) => s + x.$2);
    if (rest > 0) top.add(('Other', rest));
    final total = top.fold<num>(0, (s, x) => s + x.$2);
    final colors = [
      for (var i = 0; i < top.length; i++)
        top[i].$1 == 'Other' ? palette.other : palette.series(i)
    ];
    final ring = AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
          painter: _DonutPainter([for (final t in top) t.$2.toDouble()], colors,
              palette.neutral)),
    );
    if (!legend) {
      if (!center || top.isEmpty || total == 0) return Center(child: ring);
      return Center(
        child: Stack(alignment: Alignment.center, children: [
          ring,
          FractionallySizedBox(
            widthFactor: .42,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(kit.formatValue(top.first.$2 / total, 'percent:0'),
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 18)),
                Text(top.first.$1,
                    style: kit.VizText.label(palette).copyWith(fontSize: 10)),
              ]),
            ),
          ),
        ]),
      );
    }
    return Row(children: [
      ring,
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < top.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(children: [
                  Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: colors[i], shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(top[i].$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: kit.VizText.label(palette))),
                  Text(
                      total == 0
                          ? ''
                          : kit.formatValue(top[i].$2 / total, 'percent:0'),
                      style: kit.VizText.value(palette).copyWith(fontSize: 11)),
                ]),
              ),
          ],
        ),
      ),
    ]);
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.values, this.colors, this.track);
  final List<double> values;
  final List<Color> colors;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2;
    final stroke = r * .34;
    final rect = Rect.fromCircle(
        center: size.center(Offset.zero), radius: r - stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final total = values.fold<double>(0, (s, v) => s + v);
    if (total <= 0) {
      canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
      return;
    }
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      canvas.drawArc(rect, start + .02, math.max(0, sweep - .04), false,
          paint..color = colors[i]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.values != values || old.colors != colors;
}

class _MiniList extends StatelessWidget {
  const _MiniList(
      {required this.list,
      required this.accent,
      required this.max,
      this.dense = false,
      this.rowHeight});
  final CompactList list;
  final Color accent;
  final int max;
  final bool dense;
  final double? rowHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = kit.VizPalette.of(context);
    final rows = list.rows.take(max).toList();
    final more = list.total - rows.length;
    final rowHeight = this.rowHeight ?? (dense ? 30.0 : 40.0);
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++)
          Flexible(
            child: SizedBox(
              height: rowHeight,
              child: Row(children: [
                if (!dense) ...[
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: rows[i].image.isNotEmpty
                        ? ClipOval(
                            child: ElpianMediaImage(
                                src: rows[i].image,
                                fit: BoxFit.cover,
                                width: 26,
                                height: 26))
                        : kit.KitAvatar(
                            name: rows[i].title,
                            size: 26,
                            color: palette.series(i)),
                  ),
                  const SizedBox(width: 8),
                ] else ...[
                  Container(
                      width: 3,
                      height: 16,
                      decoration: BoxDecoration(
                          color: rows[i].status.isEmpty
                              ? accent.withValues(alpha: .7)
                              : palette.status(rows[i].status),
                          borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(rows[i].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: dense ? 12.5 : 13,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                      if (!dense && rows[i].subtitle.isNotEmpty)
                        Text(rows[i].subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: kit.VizText.label(palette)),
                    ],
                  ),
                ),
                if (rows[i].status.isNotEmpty && !dense)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: kit.Pill(
                        text: rows[i].status,
                        color: palette.status(rows[i].status) ==
                                Theme.of(context).colorScheme.primary
                            ? palette.series(1)
                            : palette.status(rows[i].status)),
                  ),
                if (rows[i].value.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(rows[i].value,
                        style: kit.VizText.value(palette).copyWith(
                            fontSize: dense ? 12 : 12.5,
                            fontWeight: FontWeight.w700)),
                  ),
                if (rows[i].delta != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                        kit.formatValue(rows[i].delta,
                            rows[i].deltaFormat ?? '+percent:1'),
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: rows[i].delta! > 0
                                ? kit.VizPalette.good
                                : rows[i].delta! < 0
                                    ? kit.VizPalette.critical
                                    : scheme.onSurfaceVariant,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ),
              ]),
            ),
          ),
        if (more > 0 && !dense)
          Align(
            alignment: Alignment.centerLeft,
            child: Text('+$more more',
                style: kit.VizText.label(palette)
                    .copyWith(fontWeight: FontWeight.w700, color: accent)),
          ),
      ],
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics(
      {required this.metrics,
      required this.max,
      this.grid = false,
      this.inline = false});
  final List<CompactMetric> metrics;
  final int max;
  final bool grid;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final palette = kit.VizPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final shown = metrics.take(max).toList();
    Widget cell(CompactMetric m) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(m.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: kit.VizText.label(palette)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(m.shown,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                if (m.delta != null) ...[
                  const SizedBox(width: 4),
                  kit.TrendText(
                      value: m.delta,
                      format: m.deltaFormat ?? '+percent:1',
                      arrow: false,
                      style: kit.VizText.value(palette).copyWith(fontSize: 11)),
                ],
              ]),
            ),
          ],
        );
    if (inline || (grid && shown.length > 1)) {
      final perRow = inline ? shown.length : 2;
      final rows = <List<CompactMetric>>[
        for (var i = 0; i < shown.length; i += perRow)
          shown.sublist(i, math.min(shown.length, i + perRow))
      ];
      return Column(children: [
        for (final r in rows)
          Expanded(
            child: Row(children: [
              for (final m in r) Expanded(child: cell(m)),
              for (var k = r.length; k < perRow; k++) const Spacer(),
            ]),
          ),
      ]);
    }
    return Column(children: [
      for (final m in shown) Expanded(child: cell(m)),
    ]);
  }
}

class _Chips extends StatelessWidget {
  const _Chips({required this.chips, required this.max});
  final List<CompactChip> chips;
  final int max;

  @override
  Widget build(BuildContext context) {
    final palette = kit.VizPalette.of(context);
    return ClipRect(
      child: Wrap(spacing: 6, runSpacing: 4, children: [
        for (final c in chips.take(max))
          kit.Pill(
              text: c.text,
              color: c.status.isEmpty
                  ? palette.series(chips.indexOf(c))
                  : palette.status(c.status)),
      ]),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.hero, required this.accent});
  final CompactHero hero;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = hero.status.isEmpty
        ? accent
        : kit.VizPalette.of(context).status(hero.status);
    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(fit: StackFit.expand, children: [
          CircularProgressIndicator(
              value: hero.progress!.toDouble(),
              strokeWidth: 7,
              strokeCap: StrokeCap.round,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: FittedBox(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                      hero.hasValue
                          ? hero.shown
                          : kit.formatValue(hero.progress, 'percent'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 18)),
                  if (hero.label.isNotEmpty)
                    Text(hero.label,
                        style: TextStyle(
                            fontSize: 10, color: scheme.onSurfaceVariant)),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar(
      {required this.progress, required this.accent, required this.status});
  final num progress;
  final Color accent;
  final String status;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(
            value: progress.toDouble(),
            minHeight: 6,
            color: status.isEmpty
                ? accent
                : kit.VizPalette.of(context).status(status),
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest),
      );
}

class _Count extends StatelessWidget {
  const _Count(
      {required this.list,
      required this.label,
      required this.accent,
      required this.centered});
  final CompactList list;
  final String label;
  final Color accent;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final first = list.rows.isEmpty ? null : list.rows.first;
    return Column(
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text('${list.total}',
              style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: accent,
                  height: 1.1)),
        ),
        Text(label.isEmpty ? 'items' : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: genUiTextStyle(context, 'caption').copyWith(fontSize: 11)),
        if (first != null) ...[
          const SizedBox(height: 4),
          Text(first.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ],
    );
  }
}

class _Words extends StatelessWidget {
  const _Words(
      {required this.summary, required this.accent, required this.centered});
  final CompactSummary summary;
  final Color accent;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final icon = genUiIcon(s.icon);
    return Column(
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) Icon(icon, size: 26, color: accent),
        if (s.title.isNotEmpty)
          Text(s.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: genUiTextStyle(context, 'h5').copyWith(fontSize: 15)),
        if (s.caption.isNotEmpty)
          Flexible(
            child: Text(s.caption,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: centered ? TextAlign.center : TextAlign.start,
                style: genUiTextStyle(context, 'caption')),
          ),
        if (s.chips.isNotEmpty) ...[
          const SizedBox(height: 6),
          _Chips(chips: s.chips, max: 3),
        ],
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(AppShape.control),
        child: ElpianMediaImage(src: url, fit: BoxFit.cover),
      );
}
