/// App layout: generated surfaces are application screens, not web pages.
/// A surface laid out as an app (createSurface's theme `{"layout": "app"}`)
/// is given its window's height ([GenUiFrame]); its root Column's body takes
/// the rest of it ("weight") and scrolls inside itself, and so do the panes
/// of a Split and the tabs of a Tabs.
library;

import 'package:flutter/material.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../shared/widgets/segmented_tab_bar.dart';
import '../runtime/format.dart';
import 'item.dart';
import 'style.dart';

/// [child] as a region of a screen: given a height, it scrolls inside it;
/// without one (a surface laid out as a page) it is shown as it is.
Widget regionScroll(BoxConstraints constraints, Widget child) =>
    constraints.hasBoundedHeight
    ? SingleChildScrollView(primary: false, child: child)
    : child;

final splitItem = asemanItem(
  'Split',
  description:
      'Panes side by side, each scrolling by itself, when the '
      'window is wide enough; switchable tabs on a phone (master/detail, a '
      'list and its details, a form and its preview).',
  properties: {
    'panes': S.list(
      description: 'The panes: [{title, child, weight?}].',
      items: S.object(additionalProperties: true),
    ),
    'minPaneWidth': P.any(
      'The narrowest a pane is shown side by side '
      '(default 320); narrower windows show the panes as tabs.',
    ),
    'gap': P.any('Space between panes (default 16).'),
  },
  required: ['panes'],
  build: (item, p) => _GenUiSplit(
    item: item,
    panes: p['panes'],
    minPaneWidth: toNum(p['minPaneWidth'])?.toDouble() ?? 320,
    gap: toNum(p['gap'])?.toDouble() ?? 16,
  ),
);

class _GenUiSplit extends StatefulWidget {
  const _GenUiSplit({
    required this.item,
    required this.panes,
    required this.minPaneWidth,
    required this.gap,
  });
  final GenUiItem item;
  final Object? panes;
  final double minPaneWidth;
  final double gap;

  @override
  State<_GenUiSplit> createState() => _GenUiSplitState();
}

class _GenUiSplitState extends State<_GenUiSplit> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final panes = [
      for (final pane in widget.panes is List ? widget.panes as List : const [])
        if (pane is Map) pane,
    ];
    if (panes.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.hasBoundedHeight;
        final n = panes.length;
        final wide =
            !constraints.hasBoundedWidth ||
            constraints.maxWidth >=
                n * widget.minPaneWidth + (n - 1) * widget.gap;
        Widget pane(int i) => KeyedSubtree(
          key: ValueKey('pane$i'),
          child: regionScroll(
            constraints,
            widget.item.child(panes[i]['child']),
          ),
        );
        if (wide) {
          final divider = Theme.of(context).dividerColor;
          return Row(
            crossAxisAlignment: bounded
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < n; i++) ...[
                if (i > 0)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: widget.gap / 2),
                    child: bounded
                        ? VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: divider,
                          )
                        : const SizedBox.shrink(),
                  ),
                Expanded(
                  flex: (toNum(panes[i]['weight'])?.round() ?? 1).clamp(
                    1,
                    1000,
                  ),
                  child: pane(i),
                ),
              ],
            ],
          );
        }
        // A phone: one pane at a time, chosen with tabs.
        final index = _index.clamp(0, n - 1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
          spacing: genUiGap,
          children: [
            SegmentedTabBar(
              labels: [
                for (var i = 0; i < n; i++)
                  stringifyValue(panes[i]['title']).isEmpty
                      ? 'Pane ${i + 1}'
                      : stringifyValue(panes[i]['title']),
              ],
              alignment: Alignment.centerLeft,
              selectedIndex: index,
              onTap: (i) => setState(() => _index = i),
            ),
            if (bounded) Expanded(child: pane(index)) else pane(index),
          ],
        );
      },
    );
  }
}
