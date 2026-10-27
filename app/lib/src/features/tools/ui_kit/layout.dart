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
        gap: asSize(props['gap'], 12),
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
/// An icon sits in a tonal rounded square; the title takes the emphasized
/// title style.
class KitSection extends StatelessWidget {
  const KitSection({super.key, required this.props, required this.children});
  final Map<String, dynamic> props;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final icon = iconFor(props['icon']);
    final hasTitle = asText(props['title']).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasTitle || icon != null)
          Row(children: [
            if (icon != null) ...[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: p.scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon,
                    size: 20, color: p.scheme.onSecondaryContainer),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(asText(props['title']),
                      style: p.font(TextStyle(
                          fontSize: 18,
                          height: 1.25,
                          letterSpacing: -0.1,
                          fontWeight: FontWeight.w700,
                          color: p.textPrimary))),
                  if (props['subtitle'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(asText(props['subtitle']),
                          style: VizText.subtitle(p).copyWith(fontSize: 13)),
                    ),
                ],
              ),
            ),
            if (props['trailing'] != null)
              Text(asText(props['trailing']),
                  style: VizText.subtitle(p)
                      .copyWith(fontWeight: FontWeight.w600)),
          ]),
        SizedBox(height: asSize(props['gap'], 12)),
        ...children,
      ],
    );
  }
}

/// A panel whose content shows when its header is tapped: a tonal
/// container whose corners and height spring open.
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
    final icon = iconFor(widget.props['icon']);
    final radius = BorderRadius.circular(_open ? 24 : 20);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubicEmphasized,
      decoration: BoxDecoration(
        color: _open
            ? p.scheme.surfaceContainerHigh
            : p.scheme.surfaceContainerLow,
        borderRadius: radius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: p.scheme.primary),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(asText(widget.props['title']),
                          style: p.font(TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: p.textPrimary))),
                      if (widget.props['subtitle'] != null)
                        Text(asText(widget.props['subtitle']),
                            style: VizText.subtitle(p)),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOutCubicEmphasized,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _open
                          ? p.scheme.secondaryContainer
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.expand_more_rounded,
                        color: p.textSecondary),
                  ),
                ),
              ]),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInOutCubicEmphasized,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: widget.children,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
