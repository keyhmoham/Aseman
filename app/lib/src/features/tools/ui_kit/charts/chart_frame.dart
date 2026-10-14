/// The chrome every chart shares: title and subtitle, the legend, the hover
/// tooltip.
library;

import 'package:flutter/material.dart';

import '../palette.dart';

/// One entry of a legend or a tooltip.
class LegendItem {
  const LegendItem(this.label, this.color, {this.line = false, this.value});
  final String label;
  final Color color;

  /// Drawn as a short line key (line charts) rather than a square.
  final bool line;

  /// A formatted value (tooltips).
  final String? value;
}

class ChartFrame extends StatelessWidget {
  const ChartFrame({
    super.key,
    this.title,
    this.subtitle,
    this.legend = const [],
    required this.child,
  });

  final String? title;
  final String? subtitle;
  final List<LegendItem> legend;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null && title!.isNotEmpty)
          Text(title!, style: VizText.title(p)),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle!, style: VizText.subtitle(p)),
          ),
        if (legend.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Legend(items: legend),
          ),
        if ((title ?? '').isNotEmpty ||
            (subtitle ?? '').isNotEmpty ||
            legend.isNotEmpty)
          const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class Legend extends StatelessWidget {
  const Legend({super.key, required this.items});
  final List<LegendItem> items;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final item in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Swatch(color: item.color, line: item.line),
              const SizedBox(width: 6),
              Text(item.label, style: VizText.label(p).copyWith(fontSize: 12)),
              if (item.value != null) ...[
                const SizedBox(width: 6),
                Text(item.value!, style: VizText.value(p)),
              ],
            ],
          ),
      ],
    );
  }
}

class Swatch extends StatelessWidget {
  const Swatch({super.key, required this.color, this.line = false});
  final Color color;
  final bool line;

  @override
  Widget build(BuildContext context) => Container(
        width: line ? 14 : 10,
        height: line ? 3 : 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(line ? 2 : 3),
        ),
      );
}

/// A tooltip card: a header, then one row per item.
class ChartTooltip extends StatelessWidget {
  const ChartTooltip({super.key, this.header, required this.items});
  final String? header;
  final List<LegendItem> items;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    return IgnorePointer(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: p.dark ? const Color(0xFF262624) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.grid),
          boxShadow: const [
            BoxShadow(
                color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 4))
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (header != null && header!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(header!,
                    style: VizText.label(p)
                        .copyWith(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Swatch(color: item.color, line: item.line),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(item.label,
                          overflow: TextOverflow.ellipsis,
                          style: VizText.label(p).copyWith(fontSize: 12)),
                    ),
                    const SizedBox(width: 12),
                    Text(item.value ?? '', style: VizText.value(p)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Places a tooltip next to [anchor], flipped and clamped to stay inside.
class TooltipLayout extends SingleChildLayoutDelegate {
  TooltipLayout(this.anchor);
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = anchor.dx + 14;
    if (x + child.width > size.width) x = anchor.dx - 14 - child.width;
    var y = anchor.dy - child.height / 2;
    x = x.clamp(0, (size.width - child.width).clamp(0, double.infinity));
    y = y.clamp(0, (size.height - child.height).clamp(0, double.infinity));
    return Offset(x.toDouble(), y.toDouble());
  }

  @override
  bool shouldRelayout(TooltipLayout old) => old.anchor != anchor;
}

/// Measures [text] in [style].
Size measureText(String text, TextStyle style) {
  final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1)
    ..layout();
  return tp.size;
}

/// Paints [text] with its top-left at [at] (or aligned by [align]: -1 left,
/// 0 center, 1 right of [at].dx; [valign] likewise for y).
void paintText(Canvas canvas, String text, Offset at, TextStyle style,
    {double align = -1, double valign = -1, double? maxWidth}) {
  final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…')
    ..layout(maxWidth: maxWidth ?? double.infinity);
  final dx = at.dx - (align + 1) / 2 * tp.width;
  final dy = at.dy - (valign + 1) / 2 * tp.height;
  tp.paint(canvas, Offset(dx, dy));
}

/// A rect with only the corners at the data end rounded (4px): the end away
/// from the baseline.
RRect barRect(Rect r, {required bool vertical, required bool positive}) {
  const radius = Radius.circular(4);
  final rad = Radius.circular(
      [radius.x, r.width / 2, r.height / 2].reduce((a, b) => a < b ? a : b));
  if (vertical) {
    return positive
        ? RRect.fromRectAndCorners(r, topLeft: rad, topRight: rad)
        : RRect.fromRectAndCorners(r, bottomLeft: rad, bottomRight: rad);
  }
  return positive
      ? RRect.fromRectAndCorners(r, topRight: rad, bottomRight: rad)
      : RRect.fromRectAndCorners(r, topLeft: rad, bottomLeft: rad);
}

/// An empty-state box for a chart without data.
class NoData extends StatelessWidget {
  const NoData({super.key, this.height = 120, this.text = 'No data'});
  final double height;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    return SizedBox(
      height: height,
      child: Center(child: Text(text, style: VizText.subtitle(p))),
    );
  }
}
