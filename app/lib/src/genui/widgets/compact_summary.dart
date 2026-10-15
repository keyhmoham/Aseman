/// A frontend's compact summary — the minimal information a phone-board tile
/// shows about the data the frontend shows in full — and its view, laid out
/// for the tile's size and shape.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/tools/ui_kit/kit.dart' as kit;
import '../catalog/style.dart';
import '../runtime/format.dart';
import '../runtime/presentation.dart';

/// One secondary value of a summary.
class CompactMetric {
  const CompactMetric({
    required this.label,
    this.value,
    this.format,
    this.delta,
    this.deltaFormat,
  });

  final String label;
  final Object? value;
  final String? format;
  final num? delta;
  final String? deltaFormat;
}

/// What a compact tile shows. Static programs publish it (`tool.compact`);
/// for A2UI surfaces it is derived from their components when they bring no
/// `compact` component of their own.
class CompactSummary {
  const CompactSummary({
    this.title = '',
    this.caption = '',
    this.value,
    this.format,
    this.delta,
    this.deltaFormat,
    this.deltaLabel = '',
    this.goodDown = false,
    this.trend = const [],
    this.progress,
    this.status = '',
    this.icon = '',
    this.badge = '',
    this.image = '',
    this.metrics = const [],
  });

  /// From JSON (what programs send; A2UI-derived specs, resolved).
  /// `trend` is a list of numbers, or `{rows, field}`; `progress` a fraction
  /// (or `{value, max}`).
  factory CompactSummary.fromJson(Object? json) {
    final m = json is Map ? json : const <String, Object?>{};
    String s(String k) => m[k] == null ? '' : stringifyValue(m[k]);
    String? f(String k) =>
        m[k] is String && (m[k] as String).isNotEmpty ? m[k] as String : null;
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
    return CompactSummary(
      title: s('title'),
      caption: s('caption'),
      value: m['value'],
      format: f('format'),
      delta: toNum(m['delta']),
      deltaFormat: f('deltaFormat'),
      deltaLabel: s('deltaLabel'),
      goodDown: m['goodDirection'] == 'down',
      trend: trendOf(m['trend']),
      progress: fraction?.clamp(0, 1),
      status: s('status'),
      icon: s('icon'),
      badge: s('badge'),
      image: s('image'),
      metrics: [
        for (final x in m['metrics'] is List ? m['metrics'] as List : const [])
          if (x is Map)
            CompactMetric(
              label: x['label'] == null ? '' : stringifyValue(x['label']),
              value: x['value'],
              format: x['format'] is String ? x['format'] as String : null,
              delta: toNum(x['delta']),
              deltaFormat: x['deltaFormat'] is String
                  ? x['deltaFormat'] as String
                  : null,
            ),
      ],
    );
  }

  /// Numbers of a trend: a list (of numbers, or of rows with `field`), or
  /// `{rows, field}`.
  static List<num> trendOf(Object? v, [String? field]) {
    if (v is Map) return trendOf(v['rows'] ?? v['data'], v['field'] as String?);
    if (v is! List) return const [];
    return [
      for (final x in v)
        if (toNum(x is Map ? kit.field(x, field ?? _guessField(x)) : x)
            case final num n)
          n,
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

  final String title;
  final String caption;
  final Object? value;
  final String? format;
  final num? delta;
  final String? deltaFormat;
  final String deltaLabel;
  final bool goodDown;
  final List<num> trend;
  final num? progress;
  final String status;
  final String icon;
  final String badge;
  final String image;
  final List<CompactMetric> metrics;

  bool get hasValue => value != null && stringifyValue(value).isNotEmpty;

  bool get isEmpty =>
      !hasValue &&
      metrics.isEmpty &&
      trend.isEmpty &&
      progress == null &&
      caption.isEmpty &&
      title.isEmpty;

  String get shownValue =>
      format != null ? kit.formatValue(value, format) : _auto(value);

  static String _auto(Object? v) {
    final n = v is num ? v : null;
    if (n == null) return stringifyValue(v);
    return n.abs() >= 100000
        ? kit.formatCompact(n)
        : specFormatNumber({'value': n, 'decimals': n.abs() < 10 ? 2 : null});
  }
}

/// A [CompactSummary] laid out for the tile it stands in (the size and shape
/// of the enclosing [FrontendPresentation]).
class CompactSummaryView extends StatelessWidget {
  const CompactSummaryView({super.key, required this.summary});

  final CompactSummary summary;

  @override
  Widget build(BuildContext context) {
    final presentation = FrontendPresentation.maybeOf(context);
    final size = presentation?.size ?? 'medium';
    final round = presentation?.shape == 'circle';
    final s = summary;
    final scheme = Theme.of(context).colorScheme;
    final palette = kit.VizPalette.of(context);
    final status = s.status.isEmpty ? null : palette.status(s.status);

    Widget value(double fontSize) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: round ? Alignment.center : Alignment.centerLeft,
      child: Text(
        s.shownValue,
        maxLines: 1,
        style: TextStyle(
          fontSize: fontSize,
          height: 1.1,
          fontWeight: FontWeight.w800,
          letterSpacing: -.4,
          color: status ?? scheme.onSurface,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    Widget? delta([double fontSize = 12.5]) => s.delta == null
        ? null
        : kit.TrendText(
            value: s.delta,
            format: s.deltaFormat ?? '+percent:2',
            goodDown: s.goodDown,
            suffix: s.deltaLabel.isEmpty || size == 'small'
                ? null
                : s.deltaLabel,
            style: kit.VizText.value(
              palette,
            ).copyWith(fontSize: fontSize, fontWeight: FontWeight.w700),
          );
    Widget spark(double height) => SizedBox(
      height: height,
      child: kit.Sparkline.fromProps({
        'values': s.trend,
        'height': height,
        'area': true,
        'color': (s.delta ?? (s.trend.last - s.trend.first)) < 0
            ? 'critical'
            : 'good',
      }, palette),
    );
    Widget? progress() => s.progress == null
        ? null
        : ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: s.progress!.toDouble(),
              minHeight: 6,
              color: status ?? scheme.primary,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          );
    final caption = s.caption.isEmpty
        ? null
        : Text(
            s.caption,
            maxLines: size == 'large' ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            textAlign: round ? TextAlign.center : TextAlign.start,
            style: genUiTextStyle(context, 'caption').copyWith(fontSize: 11.5),
          );
    final title = s.title.isEmpty
        ? null
        : Text(
            s.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: round ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          );

    // Small tiles and circles: the one value that matters, centered.
    if (size == 'small' || round) {
      final icon = genUiIcon(s.icon);
      if (s.progress != null && !s.hasValue) {
        return Center(
          child: AspectRatio(
            aspectRatio: 1,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: s.progress!.toDouble(),
                    strokeWidth: 6,
                    color: status ?? scheme.primary,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                  Center(
                    child: Text(
                      kit.formatValue(s.progress, 'percent'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: round
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          if (icon != null && !s.hasValue)
            Icon(icon, size: 30, color: status ?? scheme.primary)
          else if (title != null && round)
            title,
          if (s.hasValue) value(round ? 20 : 22),
          ?delta(11.5),
          if (!s.hasValue && s.trend.length >= 2)
            Expanded(child: spark(double.infinity)),
          if (!s.hasValue && caption != null) caption,
        ],
      );
    }

    final large = size == 'large';
    final trend = s.trend.length >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.max,
      children: [
        ?title,
        if (s.hasValue)
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: value(large ? 30 : 24)),
              if (s.badge.isNotEmpty) ...[
                const SizedBox(width: 6),
                kit.Pill(
                  text: s.badge,
                  color: status ?? palette.series(0),
                  variant: 'tonal',
                ),
              ],
            ],
          ),
        ?delta(),
        if (trend && (large || s.metrics.isEmpty))
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: spark(double.infinity),
            ),
          )
        else if (s.metrics.isEmpty)
          const Spacer(),
        if (s.metrics.isNotEmpty)
          Expanded(
            flex: large ? 2 : 1,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _Metrics(metrics: s.metrics.take(large ? 4 : 2).toList()),
            ),
          ),
        if (progress() case final p?) ...[const SizedBox(height: 6), p],
        if (caption != null) ...[const SizedBox(height: 4), caption],
      ],
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.metrics});
  final List<CompactMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final palette = kit.VizPalette.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final rows = math.max(1, (box.maxHeight / 22).floor());
        return Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (final m in metrics.take(rows))
              SizedBox(
                height: math.min(22, box.maxHeight),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: kit.VizText.label(palette),
                      ),
                    ),
                    Text(
                      m.format != null
                          ? kit.formatValue(m.value, m.format)
                          : CompactSummary._auto(m.value),
                      style: kit.VizText.value(palette),
                    ),
                    if (m.delta != null) ...[
                      const SizedBox(width: 6),
                      kit.TrendText(
                        value: m.delta,
                        format: m.deltaFormat ?? '+percent:1',
                        arrow: false,
                        style: kit.VizText.value(
                          palette,
                        ).copyWith(fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
