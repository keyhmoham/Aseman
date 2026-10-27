/// The interactive canvas the newer charts share: it sizes itself (falling
/// back to a natural width when the layout gives none, so a chart in a Row
/// never throws), tracks the hovered mark, shows the tooltip and reports taps
/// as `select`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'cartesian_chart.dart' show ChartSelect;
import 'chart_frame.dart';

/// What sits under the pointer: the mark's [index] (for hover painting),
/// its tooltip, and the `select` event's data.
class VizHit {
  const VizHit(this.index,
      {this.header, this.items = const [], this.detail = const {}});
  final int index;
  final String? header;
  final List<LegendItem> items;
  final Map<String, dynamic> detail;
}

/// [box]'s width, or [fallback] when it is unbounded.
double widthIn(BoxConstraints box, [double fallback = 320]) =>
    box.maxWidth.isFinite ? box.maxWidth : fallback;

class VizCanvas extends StatefulWidget {
  const VizCanvas({
    super.key,
    required this.height,
    required this.painter,
    this.hitTest,
    this.onSelect,
    this.fallbackWidth = 320,
  });

  final double height;

  /// The painter for a [size], with the hovered mark's index (or null).
  final CustomPainter Function(Size size, int? hover) painter;
  final VizHit? Function(Offset position, Size size)? hitTest;
  final ChartSelect? onSelect;
  final double fallbackWidth;

  @override
  State<VizCanvas> createState() => _VizCanvasState();
}

class _VizCanvasState extends State<VizCanvas> {
  VizHit? _hit;
  Offset? _pointer;

  void _move(Offset pos, Size size) {
    final hit = widget.hitTest?.call(pos, size);
    if (hit == null && _hit == null) return;
    setState(() {
      _pointer = pos;
      _hit = hit;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = Size(widthIn(box, widget.fallbackWidth), widget.height);
      final hit = _hit;
      Widget canvas = CustomPaint(
          size: size, painter: widget.painter(size, hit?.index));
      if (widget.hitTest == null) return SizedBox.fromSize(size: size, child: canvas);
      return SizedBox.fromSize(
        size: size,
        child: MouseRegion(
          onHover: (e) => _move(e.localPosition, size),
          onExit: (_) => setState(() => _hit = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              _move(d.localPosition, size);
              final h = widget.hitTest!(d.localPosition, size);
              if (h != null && widget.onSelect != null) {
                widget.onSelect!({'index': h.index, ...h.detail});
              }
            },
            child: Stack(children: [
              Positioned.fill(child: canvas),
              if (hit != null && _pointer != null && (hit.header != null || hit.items.isNotEmpty))
                Positioned.fill(
                  child: CustomSingleChildLayout(
                    delegate: TooltipLayout(_pointer!),
                    child: ChartTooltip(header: hit.header, items: hit.items),
                  ),
                ),
            ]),
          ),
        ),
      );
    });
  }
}

/// A time value: an ISO date/time, epoch milliseconds, or a plain number.
DateTime? asTime(Object? v) {
  if (v is DateTime) return v;
  if (v is num) return v > 1e11 ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
  if (v is String) return DateTime.tryParse(v.trim());
  return null;
}

/// A yyyy-MM-dd key of [d].
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const List<String> monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];

/// Gives its child [width] when the incoming width is unbounded (directly
/// in a Row, in a horizontal scroll) and is transparent otherwise, so a kit
/// node there draws at a natural width instead of throwing. Intrinsic sizes
/// pass straight through.
class WidthFallback extends SingleChildRenderObjectWidget {
  const WidthFallback({super.key, required this.width, super.child});
  final double width;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderWidthFallback(width);

  @override
  void updateRenderObject(BuildContext context, _RenderWidthFallback renderObject) => renderObject.width = width;
}

class _RenderWidthFallback extends RenderProxyBox {
  _RenderWidthFallback(this._width);
  double _width;
  set width(double v) {
    if (v == _width) return;
    _width = v;
    markNeedsLayout();
  }

  BoxConstraints _fix(BoxConstraints c) =>
      c.hasBoundedWidth ? c : c.copyWith(minWidth: c.minWidth.clamp(0, _width), maxWidth: _width);

  @override
  void performLayout() {
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child!.layout(_fix(constraints), parentUsesSize: true);
    size = constraints.constrain(child!.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      child == null ? constraints.smallest : constraints.constrain(child!.getDryLayout(_fix(constraints)));
}
