/// Layout widgets the Flutter set lacks as single nodes: a responsive grid,
/// a titled section, an expandable panel.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'palette.dart';
import 'values.dart';

/// Children in equal-width columns: as many as fit at [minColumnWidth]
/// (capped by [maxColumns]), or exactly [columns].
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.columns,
    this.minColumnWidth = 220,
    this.maxColumns = 6,
    this.gap = 12,
    this.runGap,
  });

  factory ResponsiveGrid.fromProps(
          Map<String, dynamic> props, List<Widget> children) =>
      ResponsiveGrid(
        columns: asNum(props['columns'])?.toInt(),
        minColumnWidth: asDouble(props['minColumnWidth'], 220),
        maxColumns: asInt(props['maxColumns'], 6),
        gap: asDouble(props['gap'], 12),
        runGap: asNum(props['runGap'])?.toDouble(),
        children: children,
      );

  final List<Widget> children;
  final int? columns;
  final double minColumnWidth;
  final int maxColumns;
  final double gap;
  final double? runGap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth.isFinite ? box.maxWidth : 800.0;
      final fit = math.max(1, ((width + gap) / (minColumnWidth + gap)).floor());
      // Never more columns than children: two tiles share the row.
      final cols = (columns ??
              math.min(math.min(fit, maxColumns), math.max(1, children.length)))
          .clamp(1, 12);
      final w = (width - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: runGap ?? gap,
        children: [
          for (final c in children) SizedBox(width: math.max(0, w), child: c),
        ],
      );
    });
  }
}

/// A titled block of content, with an optional subtitle and trailing text.
class KitSection extends StatelessWidget {
  const KitSection({super.key, required this.props, required this.children});
  final Map<String, dynamic> props;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final icon = iconFor(props['icon']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: p.textSecondary),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(asText(props['title']),
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary)),
                if (props['subtitle'] != null)
                  Text(asText(props['subtitle']), style: VizText.subtitle(p)),
              ],
            ),
          ),
          if (props['trailing'] != null)
            Text(asText(props['trailing']), style: VizText.subtitle(p)),
        ]),
        SizedBox(height: asDouble(props['gap'], 10)),
        ...children,
      ],
    );
  }
}

/// A panel whose content shows when its header is tapped.
class Expandable extends StatefulWidget {
  const Expandable({super.key, required this.props, required this.children});
  final Map<String, dynamic> props;
  final List<Widget> children;

  @override
  State<Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<Expandable> {
  late bool _open = asBool(widget.props['expanded']);

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: p.grid),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(asText(widget.props['title']),
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: p.textPrimary)),
                      if (widget.props['subtitle'] != null)
                        Text(asText(widget.props['subtitle']),
                            style: VizText.subtitle(p)),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.expand_more, color: p.textSecondary),
                ),
              ]),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: widget.children,
              ),
            ),
        ],
      ),
    );
  }
}
