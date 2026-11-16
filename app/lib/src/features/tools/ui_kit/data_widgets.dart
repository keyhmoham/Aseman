/// Figures and small data views: stat tiles, trends, badges, avatars,
/// progress, ratings, key–value lists, timelines and callouts.
library;

import 'dart:math' as math;
import '../../../core/theme/app_shape.dart';

import 'package:aseman/src/elpian/core/lenient.dart';
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
    this.dot = true,
  });

  final String text;
  final Color color;

  /// tonal (default), filled, outline.
  final String variant;
  final IconData? icon;

  /// Whether a tonal or outlined pill without an icon shows a color dot.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final filled = variant == 'filled';
    final outline = variant == 'outline' || variant == 'outlined';
    final bg = filled
        ? color
        : outline
        ? Colors.transparent
        : p.tonal(color);
    final fg = filled ? VizPalette.onFill(color) : p.onTonal(color);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOutCubicEmphasized,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: outline
            ? Border.all(color: color.withValues(alpha: 0.7))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: filled ? fg : color),
            const SizedBox(width: 4),
          ] else if (!filled && dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: p.font(
                TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                  color: fg,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget fromProps(Map<String, dynamic> props, VizPalette p) => Pill(
    text: asText(props['text'] ?? props['label'] ?? props['value']),
    color: p.parse(props['color'] ?? props['status']) ?? p.accent,
    variant: '${props['variant'] ?? 'tonal'}',
    icon: iconFor(props['icon']),
    dot: asBool(props['dot'], props['status'] != null),
  );
}

class KitAvatar extends StatelessWidget {
  const KitAvatar({
    super.key,
    this.name = '',
    this.url,
    this.size = 36,
    this.color,
  });
  final String name;
  final String? url;
  final double size;
  final Color? color;

  static Widget fromProps(Map<String, dynamic> props, VizPalette p) =>
      KitAvatar(
        name: asText(props['name'] ?? props['label']),
        url: looseStr(props['url']) ?? looseStr(props['image']),
        size: asSize(props['size'], 36),
        color: p.parse(props['color']),
      );

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final initials = words
        .take(2)
        .map((w) => w.characters.first.toUpperCase())
        .join();
    final hue =
        color ?? p.series(name.codeUnits.fold<int>(0, (a, b) => a + b) % 8);
    // Tonal: a soft fill of the hue with its ink, as M3 avatars are drawn.
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: p.tonal(hue, 1.6),
        shape: BoxShape.circle,
      ),
      child: Text(
        initials,
        style: p.font(
          TextStyle(
            fontSize: size * 0.38,
            fontWeight: FontWeight.w700,
            color: p.onTonal(hue),
          ),
        ),
      ),
    );
    if (url == null || url!.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

/// A stat tile: label, value (auto-compacted), an optional delta against a
/// named period, and an optional trend sparkline. The icon sits in a tonal
/// rounded square; the delta is a tonal chip with its arrow.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final size = '${props['size'] ?? 'default'}';
    final hero = size == 'hero';
    final compact = size == 'compact';
    final raw = props['value'] ??
        props['text'] ??
        props['content'] ??
        props['amount'] ??
        props['reading'];
    final format = looseStr(props['format']);
    final value = format == null && raw is num && raw.abs() >= 10000
        ? formatCompact(raw)
        : formatValue(raw, format);
    final delta = asNum(props['delta']);
    final trend = asList(props['trend']);
    final icon = iconFor(props['icon']);
    final status = looseStr(props['status']);
    final accent =
        p.parse(props['color']) ??
        (status != null ? p.status(status) : p.accent);
    final goodDown = props['goodDirection'] == 'down';
    final label = Text(
      asText(props['label'] ?? props['title'] ?? props['name']),
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: p.font(
        TextStyle(
          fontSize: compact ? 12 : 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
          color: p.textSecondary,
        ),
      ),
    );
    final iconBox = compact ? 28.0 : 36.0;
    // Inside a Row (unbounded width) a flexible label would throw: there the
    // tile takes its natural width.
    return LayoutBuilder(builder: (context, box) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Container(
                width: iconBox,
                height: iconBox,
                decoration: BoxDecoration(
                  color: p.tonal(accent, 1.3),
                  borderRadius: BorderRadius.circular(iconBox * 0.32),
                ),
                child: Icon(
                  icon,
                  size: iconBox * 0.55,
                  color: p.onTonal(accent),
                ),
              ),
              SizedBox(width: compact ? 8 : 10),
            ],
            if (box.maxWidth.isFinite) Expanded(child: label) else label,
          ],
        ),
        SizedBox(height: compact ? 4 : 8),
        // Big figures shrink to fit rather than lose digits.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: p.font(
              TextStyle(
                fontSize: hero
                    ? 52
                    : compact
                    ? 22
                    : 32,
                height: 1.05,
                letterSpacing: hero ? -1.2 : (compact ? -0.2 : -0.6),
                fontWeight: hero ? FontWeight.w700 : FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: p.textPrimary,
              ),
            ),
          ),
        ),
        if (delta != null ||
            props['deltaLabel'] != null ||
            props['caption'] != null)
          Padding(
            padding: EdgeInsets.only(top: compact ? 4 : 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (delta != null)
                  _DeltaChip(
                    delta: delta,
                    format: looseStr(props['deltaFormat']),
                    goodDown: goodDown,
                  ),
                if (props['deltaLabel'] != null || props['caption'] != null)
                  Text(
                    asText(props['deltaLabel'] ?? props['caption']),
                    overflow: TextOverflow.ellipsis,
                    style: p.font(TextStyle(fontSize: 12, color: p.textMuted)),
                  ),
              ],
            ),
          ),
        if (trend.length > 1)
          Padding(
            padding: EdgeInsets.only(top: compact ? 6 : 10),
            child: Sparkline(
              values: [
                for (final t in trend)
                  asNum(t is Map ? t['value'] : t)?.toDouble(),
              ],
              height: hero ? 56 : (compact ? 24 : 36),
              color: accent,
              area: true,
            ),
          ),
      ],
    ));
  }
}

/// A delta as a small tonal chip: arrow and signed value, green when it
/// moves the good way.
class _DeltaChip extends StatelessWidget {
  const _DeltaChip({required this.delta, this.format, this.goodDown = false});
  final num delta;
  final String? format;
  final bool goodDown;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final up = delta > 0, down = delta < 0;
    final good = goodDown ? down : up;
    final color = up || down
        ? (good ? VizPalette.good : VizPalette.critical)
        : p.textSecondary;
    final f = format ?? '+number';
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
      decoration: BoxDecoration(
        color: p.tonal(color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up
                ? Icons.arrow_upward_rounded
                : down
                ? Icons.arrow_downward_rounded
                : Icons.remove_rounded,
            size: 14,
            color: p.onTonal(color),
          ),
          const SizedBox(width: 2),
          Text(
            formatValue(delta, f.startsWith('+') ? f : '+$f'),
            style: p.font(
              TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: p.onTonal(color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Progress: a linear bar or a ring. A value ≤ 1 without `max` is a
/// fraction. The bar is the M3 Expressive one: rounded, a gap between the
/// active part and the track, a stop dot at the end, and with `wavy` an
/// animated wave on the active part.
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
    final color = p.parse(props['color'] ?? props['status']) ?? p.accent;
    final track = p.tonal(color, 1.5);
    final label = props['label'] == null ? null : asText(props['label']);
    final showValue = asBool(props['showValue'], true) && v != null;
    final wavy = asBool(props['wavy']) || props['variant'] == 'wavy';
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
      final size = asSize(props['size'], 56);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: size,
                  height: size,
                  child: CircularProgressIndicator(
                    value: t,
                    strokeWidth: math.max(4, size / 9),
                    color: color,
                    backgroundColor: track,
                    strokeCap: StrokeCap.round,
                  ),
                ),
                if (text != null)
                  Text(
                    text,
                    style: VizText.value(p).copyWith(
                      fontSize: math.max(10, size / 4.5),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(label, style: VizText.subtitle(p)),
            ),
        ],
      );
    }
    // In an unbounded row the bar takes a natural width rather than throwing.
    return LayoutBuilder(builder: (context, box) => SizedBox(
      width: box.maxWidth.isFinite ? null : 160,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null || text != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                if (label != null)
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: p.font(
                        TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                  ),
                if (text != null)
                  Text(
                    text,
                    style: VizText.value(
                      p,
                    ).copyWith(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
        ExpressiveBar(
          value: t,
          color: color,
          track: track,
          thickness: asSize(props['thickness'], wavy ? 6 : 8).clamp(1, 48),
          wavy: wavy,
        ),
      ],
    )));
  }
}

/// The M3 Expressive linear progress bar: rounded ends, a gap between the
/// active part and the track, a stop dot at the track's end; [wavy] draws
/// the active part as a travelling wave. A null [value] sweeps
/// (indeterminate).
class ExpressiveBar extends StatefulWidget {
  const ExpressiveBar({
    super.key,
    required this.value,
    required this.color,
    required this.track,
    this.thickness = 8,
    this.wavy = false,
  });

  final double? value;
  final Color color;
  final Color track;
  final double thickness;
  final bool wavy;

  @override
  State<ExpressiveBar> createState() => _ExpressiveBarState();
}

class _ExpressiveBarState extends State<ExpressiveBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  bool get _moving => widget.wavy || widget.value == null;

  @override
  void initState() {
    super.initState();
    if (_moving) _phase.repeat();
  }

  @override
  void didUpdateWidget(ExpressiveBar old) {
    super.didUpdateWidget(old);
    if (_moving && !_phase.isAnimating) _phase.repeat();
    if (!_moving && _phase.isAnimating) _phase.stop();
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = widget.wavy ? widget.thickness * 2.4 : widget.thickness;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: widget.value ?? 0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => SizedBox(
        height: height,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _BarPainter(
              value: widget.value == null ? null : t,
              phase: _phase,
              color: widget.color,
              track: widget.track,
              thickness: widget.thickness,
              wavy: widget.wavy,
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.value,
    required this.phase,
    required this.color,
    required this.track,
    required this.thickness,
    required this.wavy,
  }) : super(repaint: phase);

  final double? value;
  final Animation<double> phase;
  final Color color;
  final Color track;
  final double thickness;
  final bool wavy;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final cy = size.height / 2;
    final half = thickness / 2;
    final gap = thickness * 0.75;
    final stroke = Paint()
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    double start = 0, end;
    if (value == null) {
      // Indeterminate: a segment sweeping across.
      final x = phase.value * 1.6 - 0.3;
      start = (x * w).clamp(0, w);
      end = ((x + 0.35) * w).clamp(0, w);
    } else {
      end = value! * w;
    }
    final activeFrom = start + half, activeTo = end - half;
    // Track: everything not active, apart by the gap.
    void line(double a, double b, Color c) {
      if (b - a < 0.5) return;
      canvas.drawLine(Offset(a, cy), Offset(b, cy), stroke..color = c);
    }

    if (value == null) {
      line(half, start - gap - half, track);
      line(end + gap + half, w - half, track);
    } else {
      line(math.max(half, end + gap + half), w - half, track);
      // The stop dot marks where the track ends.
      if (value! < 0.98) {
        canvas.drawCircle(
          Offset(w - half, cy),
          thickness * 0.22,
          Paint()..color = color,
        );
      }
    }
    if (activeTo <= activeFrom) {
      if (end - start > 0) {
        canvas.drawCircle(
          Offset((start + end) / 2, cy),
          half,
          Paint()..color = color,
        );
      }
      return;
    }
    if (!wavy) {
      line(activeFrom, activeTo, color);
      return;
    }
    final amp = thickness * 0.55;
    const wave = 28.0;
    final shift = phase.value * wave;
    final path = Path();
    for (var x = activeFrom; x <= activeTo; x += 1) {
      // The wave flattens into its ends.
      final fade = math.min(1.0, math.min(x - activeFrom, activeTo - x) / wave);
      final y = cy + math.sin((x - shift) / wave * 2 * math.pi) * amp * fade;
      x == activeFrom ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, stroke..color = color);
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.value != value ||
      old.color != color ||
      old.track != track ||
      old.wavy != wavy ||
      old.thickness != thickness;
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
    final size = asSize(props['size'], 20).clamp(8, 96).toDouble();
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
            color: p.parse(asText(v).toLowerCase()) ?? p.accent);
      if (v is List) {
        return Text(v.map((x) => formatValue(x, format)).join(', '),
            style: style);
      }
      return Text(formatValue(v, format), style: style);
    }

    // A facts card is one KeyValue per row: {label, value} on the node
    // itself, not a list under items.
    var raw = props['items'] ??
        props['fields'] ??
        props['pairs'] ??
        props['entries'] ??
        props['facts'] ??
        props['metrics'] ??
        props['rows'] ??
        props['data'];
    if (raw == null) {
      final label = props['label'] ?? props['title'] ?? props['name'];
      final value = props['value'] ??
          props['text'] ??
          props['content'] ??
          props['subtitle'] ??
          props['amount'];
      if (label != null || value != null) {
        raw = [
          {'label': label ?? '', 'value': value ?? ''}
        ];
      }
    }
    for (final pair in recordPairs(
      raw,
      labels: props['labels'] is Map ? asMap(props['labels']) : null,
      formats: props['formats'] is Map ? asMap(props['formats']) : null,
    )) {
      items.add((pair.label, valueOf(pair.value, pair.format, pair.type)));
    }
    if (items.isEmpty) return const SizedBox.shrink();
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
    final timeFormat = looseStr(props['timeFormat']);
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
                        color: i == 0 ? Colors.transparent : p.grid,
                      ),
                      _dot(rows[i], p),
                      Expanded(
                        child: Container(
                          width: 2,
                          color: i == rows.length - 1
                              ? Colors.transparent
                              : p.grid,
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
    final status = looseStr(row['status']);
    final color =
        p.parse(row['color']) ?? (status != null ? p.status(status) : p.accent);
    final icon = iconFor(row['icon']);
    if (icon != null) {
      return Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: p.tonal(color, 1.8),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 14, color: p.onTonal(color)),
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

/// A highlighted message: info, good, warning or critical, with its icon
/// on a tonal container (no side stripe).
class Callout extends StatelessWidget {
  const Callout({super.key, required this.props, this.children = const []});
  final Map<String, dynamic> props;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final severity = '${props['severity'] ?? props['status'] ?? 'info'}';
    final color =
        p.parse(props['color']) ??
        (severity == 'info' ? p.accent : p.status(severity));
    final icon =
        iconFor(props['icon']) ??
        switch (severity) {
          'good' || 'success' => Icons.check_circle_rounded,
          'warning' => Icons.warning_rounded,
          'critical' || 'error' || 'serious' => Icons.error_rounded,
          _ => Icons.info_rounded,
        };
    final ink = p.onTonal(color);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
      decoration: BoxDecoration(
        color: p.tonal(color),
        borderRadius: AppShape.borderRadius(context, 20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: p.tonal(color, 2.4),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (props['title'] != null &&
                      asText(props['title']).isNotEmpty)
                    Text(
                      asText(props['title']),
                      style: p.font(
                        TextStyle(
                          fontSize: 15,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                  if (props['text'] != null)
                    Padding(
                      padding: EdgeInsets.only(
                        top: props['title'] != null ? 4 : 0,
                      ),
                      child: Text(
                        asText(props['text']),
                        style: p.font(
                          TextStyle(
                            fontSize: 13.5,
                            height: 1.4,
                            color: p.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  if (children.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ...children,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
