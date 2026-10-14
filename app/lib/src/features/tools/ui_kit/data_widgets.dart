/// Figures and small data views: stat tiles, trends, badges, avatars,
/// progress, ratings, key–value lists, timelines and callouts.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'charts/polar_charts.dart';
import 'palette.dart';
import 'values.dart';

/// A signed number with an arrow, colored by direction (green up, red
/// down; [goodDown] inverts it). The arrow carries the direction too, so
/// color is never alone.
class TrendText extends StatelessWidget {
  const TrendText({
    super.key,
    required this.value,
    this.format,
    this.style,
    this.goodDown = false,
    this.arrow = true,
    this.suffix,
  });

  final num? value;
  final String? format;
  final TextStyle? style;
  final bool goodDown;
  final bool arrow;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final v = value;
    if (v == null) return const SizedBox.shrink();
    final up = v > 0, down = v < 0;
    final good = goodDown ? down : up;
    final color = up || down
        ? (good ? VizPalette.good : VizPalette.critical)
        : p.textSecondary;
    final base = (style ?? VizText.value(p)).copyWith(color: color);
    final f = format ?? '+number';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (arrow && (up || down))
          Icon(up ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              size: (base.fontSize ?? 13) + 6, color: color),
        Flexible(
          child: Text(
            '${formatValue(v, f.startsWith('+') ? f : '+$f')}${suffix == null ? '' : ' $suffix'}',
            overflow: TextOverflow.ellipsis,
            style: base,
          ),
        ),
      ],
    );
  }
}

/// A pill-shaped label (a badge, a tag, a status).
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.text,
    required this.color,
    this.variant = 'tonal',
    this.icon,
  });

  final String text;
  final Color color;

  /// tonal (default), filled, outline.
  final String variant;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final filled = variant == 'filled';
    final outline = variant == 'outline';
    final bg = filled
        ? color
        : outline
            ? Colors.transparent
            : color.withValues(alpha: p.dark ? 0.24 : 0.14);
    final fg = filled ? VizPalette.onFill(color) : p.textPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: outline ? Border.all(color: color) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: filled ? fg : color),
            const SizedBox(width: 4),
          ] else if (!filled) ...[
            Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500, color: fg)),
          ),
        ],
      ),
    );
  }

  static Widget fromProps(Map<String, dynamic> props, VizPalette p) => Pill(
        text: asText(props['text'] ?? props['label'] ?? props['value']),
        color: p.parse(props['color'] ?? props['status']) ?? p.series(0),
        variant: '${props['variant'] ?? 'tonal'}',
        icon: iconFor(props['icon']),
      );
}

class KitAvatar extends StatelessWidget {
  const KitAvatar(
      {super.key, this.name = '', this.url, this.size = 36, this.color});
  final String name;
  final String? url;
  final double size;
  final Color? color;

  static Widget fromProps(Map<String, dynamic> props, VizPalette p) =>
      KitAvatar(
        name: asText(props['name'] ?? props['label']),
        url: props['url'] as String? ?? props['image'] as String?,
        size: asDouble(props['size'], 36),
        color: p.parse(props['color']),
      );

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final initials =
        words.take(2).map((w) => w.characters.first.toUpperCase()).join();
    final hue =
        color ?? p.series(name.codeUnits.fold<int>(0, (a, b) => a + b) % 8);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: hue, shape: BoxShape.circle),
      child: Text(initials,
          style: TextStyle(
              fontSize: size * 0.4,
              fontWeight: FontWeight.w600,
              color: VizPalette.onFill(hue))),
    );
    if (url == null || url!.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(url!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback),
    );
  }
}

/// A stat tile: label, value (auto-compacted), an optional delta against a
/// named period, and an optional trend sparkline.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final size = '${props['size'] ?? 'default'}';
    final hero = size == 'hero';
    final compact = size == 'compact';
    final raw = props['value'];
    final format = props['format'] as String?;
    final value = format == null && raw is num && raw.abs() >= 10000
        ? formatCompact(raw)
        : formatValue(raw, format);
    final delta = asNum(props['delta']);
    final trend = asList(props['trend']);
    final icon = iconFor(props['icon']);
    final status = props['status'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          if (icon != null) ...[
            Icon(icon,
                size: 16,
                color: status != null ? p.status(status) : p.textSecondary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(asText(props['label']),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: compact ? 12 : 13, color: p.textSecondary)),
          ),
        ]),
        SizedBox(height: compact ? 2 : 4),
        // Big figures shrink to fit rather than lose digits.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              maxLines: 1,
              style: TextStyle(
                  fontSize: hero
                      ? 48
                      : compact
                          ? 20
                          : 28,
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary)),
        ),
        if (delta != null || props['caption'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              if (delta != null)
                TrendText(
                  value: delta,
                  format: props['deltaFormat'] as String? ?? '+number',
                  goodDown: props['goodDirection'] == 'down',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
                ),
              if (props['deltaLabel'] != null || props['caption'] != null) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(asText(props['deltaLabel'] ?? props['caption']),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.textMuted)),
                ),
              ],
            ]),
          ),
        if (trend.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Sparkline(
              values: [
                for (final t in trend)
                  asNum(t is Map ? t['value'] : t)?.toDouble()
              ],
              height: hero ? 48 : 32,
              color: p.parse(props['color']),
              area: true,
            ),
          ),
      ],
    );
  }
}

/// Progress: a linear bar or a ring. A value ≤ 1 without `max` is a
/// fraction.
class ProgressView extends StatelessWidget {
  const ProgressView({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final v = asNum(props['value'])?.toDouble();
    final max =
        asNum(props['max'])?.toDouble() ?? (v != null && v <= 1 ? 1 : 100);
    final t = v == null || max == 0 ? null : (v / max).clamp(0.0, 1.0);
    final color = p.parse(props['color'] ?? props['status']) ?? p.series(0);
    final track = Color.lerp(color, p.surface, 0.8)!;
    final label = props['label'] == null ? null : asText(props['label']);
    final showValue = asBool(props['showValue'], true) && v != null;
    final text = showValue
        ? (props['format'] != null
            ? formatValue(v, props['format'] as String)
            : max == 1
                ? formatValue(v, 'percent')
                : max == 100
                    ? '${formatValue(v, null)}%'
                    : '${formatValue(v, null)} / ${formatValue(max, null)}')
        : null;
    if (props['variant'] == 'circular') {
      final size = asDouble(props['size'], 56);
      return Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: size,
          height: size,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: t,
                strokeWidth: math.max(3, size / 10),
                color: color,
                backgroundColor: track,
                strokeCap: StrokeCap.round,
              ),
            ),
            if (text != null)
              Text(text,
                  style: VizText.value(p)
                      .copyWith(fontSize: math.max(10, size / 4.5))),
          ]),
        ),
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(label, style: VizText.subtitle(p)),
          ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null || text != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              if (label != null)
                Expanded(
                    child: Text(label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: p.textPrimary))),
              if (text != null) Text(text, style: VizText.value(p)),
            ]),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: t,
            minHeight: asDouble(props['thickness'], 8),
            color: color,
            backgroundColor: track,
          ),
        ),
      ],
    );
  }
}

/// Stars: [value] of [max], with halves.
class RatingView extends StatelessWidget {
  const RatingView({super.key, required this.props, this.onChange});
  final Map<String, dynamic> props;
  final void Function(int value)? onChange;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final v = asDouble(props['value'], 0);
    final max = asInt(props['max'], 5).clamp(1, 10);
    final size = asDouble(props['size'], 20);
    final color = p.parse(props['color']) ?? VizPalette.warning;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= max; i++)
          GestureDetector(
            onTap: onChange == null ? null : () => onChange!(i),
            child: Icon(
              v >= i
                  ? Icons.star_rounded
                  : v >= i - 0.5
                      ? Icons.star_half_rounded
                      : Icons.star_outline_rounded,
              size: size,
              color: v >= i - 0.5 ? color : p.textMuted,
            ),
          ),
        if (asBool(props['showValue']))
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(formatValue(v, 'number:1'), style: VizText.value(p)),
          ),
      ],
    );
  }
}

/// Label → value pairs (a description list), in one or more columns.
class KeyValueList extends StatelessWidget {
  const KeyValueList({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final items = <(String, Widget)>[];
    final style = TextStyle(
        fontSize: 13.5,
        color: p.textPrimary,
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()]);
    Widget valueOf(Object? v, String? format, String? type) {
      if (type == 'trend')
        return TrendText(value: asNum(v), format: format, style: style);
      if (type == 'badge')
        return Pill(
            text: formatValue(v, format),
            color: p.parse(asText(v).toLowerCase()) ?? p.series(0));
      if (v is List) {
        return Text(v.map((x) => formatValue(x, format)).join(', '),
            style: style);
      }
      return Text(formatValue(v, format), style: style);
    }

    final list = props['items'];
    if (list is List) {
      for (final item in list) {
        final m = asMap(item);
        items.add((
          asText(m['label'] ?? m['key']),
          valueOf(m['value'], m['format'] as String?, m['type'] as String?)
        ));
      }
    } else {
      final data = asMap(props['data']);
      final formats = asMap(props['formats']);
      for (final e in data.entries) {
        if (e.value is Map) continue;
        items.add((
          asText(asMap(props['labels'])[e.key] ?? _humanize(e.key)),
          valueOf(e.value, formats[e.key] as String?, null)
        ));
      }
    }
    final columns = asInt(props['columns'], 1).clamp(1, 4);
    final vertical = props['layout'] == 'vertical' || columns > 1;
    Widget entry((String, Widget) e) => vertical
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(e.$1,
                    style: TextStyle(fontSize: 12, color: p.textSecondary)),
                const SizedBox(height: 2),
                e.$2,
              ],
            ),
          )
        : Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.grid))),
            child: Row(children: [
              Expanded(
                  child: Text(e.$1,
                      style: TextStyle(fontSize: 13, color: p.textSecondary))),
              const SizedBox(width: 12),
              Flexible(
                  child: Align(alignment: Alignment.centerRight, child: e.$2)),
            ]),
          );
    if (columns == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [for (final e in items) entry(e)],
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final cols = math.max(1, math.min(columns, (box.maxWidth / 140).floor()));
      final w = (box.maxWidth - (cols - 1) * 16) / cols;
      return Wrap(
        spacing: 16,
        children: [for (final e in items) SizedBox(width: w, child: entry(e))],
      );
    });
  }
}

String _humanize(String field) {
  final s = field
      .replaceAll(RegExp(r'[_\-.]'), ' ')
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .trim();
  return s.isEmpty ? field : s[0].toUpperCase() + s.substring(1);
}

/// A vertical timeline of events: a dot per event (its status color and
/// icon), title, time and description.
class TimelineView extends StatelessWidget {
  const TimelineView({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final void Function(Map<String, dynamic> detail)? onSelect;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final rows = asRows(props['data'] ?? props['items']);
    final tf = '${props['titleField'] ?? 'title'}';
    final sf = '${props['descriptionField'] ?? 'description'}';
    final timeField = '${props['timeField'] ?? 'time'}';
    final timeFormat = props['timeFormat'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows.length; i++)
          InkWell(
            onTap: onSelect == null
                ? null
                : () => onSelect!({'index': i, 'row': rows[i]}),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 24,
                    child: Column(children: [
                      Container(
                        width: 2,
                        height: 6,
                        color: i == 0 ? Colors.transparent : p.axis,
                      ),
                      _dot(rows[i], p),
                      Expanded(
                        child: Container(
                          width: 2,
                          color: i == rows.length - 1
                              ? Colors.transparent
                              : p.axis,
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14, top: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(children: [
                            Expanded(
                              child: Text(
                                  asText(field(rows[i], tf) ??
                                      field(rows[i], 'label')),
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: p.textPrimary)),
                            ),
                            if (field(rows[i], timeField) != null)
                              Text(
                                  formatValue(
                                      field(rows[i], timeField), timeFormat),
                                  style:
                                      VizText.label(p).copyWith(fontSize: 12)),
                          ]),
                          if (field(rows[i], sf) != null ||
                              field(rows[i], 'subtitle') != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                  asText(field(rows[i], sf) ??
                                      field(rows[i], 'subtitle')),
                                  style: TextStyle(
                                      fontSize: 13, color: p.textSecondary)),
                            ),
                          if (field(rows[i], 'status') != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Pill(
                                  text: asText(field(rows[i], 'status')),
                                  color: p.status(
                                      asText(field(rows[i], 'status')))),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _dot(Map<String, dynamic> row, VizPalette p) {
    final status = row['status'] as String?;
    final color = p.parse(row['color']) ??
        (status != null ? p.status(status) : p.series(0));
    final icon = iconFor(row['icon']);
    if (icon != null) {
      return Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, size: 13, color: VizPalette.onFill(color)),
      );
    }
    return Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: p.surface, width: 2),
      ),
    );
  }
}

/// A highlighted message: info, good, warning or critical, with its icon.
class Callout extends StatelessWidget {
  const Callout({super.key, required this.props, this.children = const []});
  final Map<String, dynamic> props;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final severity = '${props['severity'] ?? props['status'] ?? 'info'}';
    final color = severity == 'info' ? p.series(0) : p.status(severity);
    final icon = iconFor(props['icon']) ??
        switch (severity) {
          'good' || 'success' => Icons.check_circle_outline,
          'warning' => Icons.warning_amber_rounded,
          'critical' || 'error' || 'serious' => Icons.error_outline,
          _ => Icons.info_outline,
        };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: p.dark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (props['title'] != null)
                  Text(asText(props['title']),
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary)),
                if (props['text'] != null)
                  Padding(
                    padding:
                        EdgeInsets.only(top: props['title'] != null ? 2 : 0),
                    child: Text(asText(props['text']),
                        style: TextStyle(fontSize: 13, color: p.textSecondary)),
                  ),
                ...children,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
