/// Tradera's components (what the catalog adds to the basic one before this
/// release): the UI kit's data views, layout, Switch, the `Elpian` escape
/// hatch and `ToolFrontend`.
///
/// Interactive views (Chart, Heatmap, Treemap, Graph, Table, Timeline,
/// TreeView) take `selection` — a binding the tapped item is written to
/// (master–detail without a round trip) — and `action`, fired in the tapped
/// item's data scope, so its context resolves relative paths against the
/// row.
library;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../elpian/core/elpian_engine.dart';
import '../../elpian/core/event_system.dart';
import '../../elpian/models/elpian_node.dart';
import '../../features/tools/ui_kit/kit.dart';
import '../runtime/dynamic_values.dart';
import '../runtime/format.dart';
import '../runtime/host.dart';
import 'item.dart';
import 'style.dart';

const _framed = {
  'title': 'A title above the view.',
  'subtitle': 'A caption under the title.',
};

Map<String, Schema> _props(Map<String, String> props) => {
      for (final e in props.entries) e.key: P.any(e.value),
    };

/// Tap handling of a kit view: writes `selection`, fires `action` in the
/// tapped item's scope ([listField]: the prop holding the items).
KitHandler _taps(GenUiItem item, {String? listField}) {
  final action = item.raw['action'];
  final selection = item.raw['selection'];
  return (event) {
    if (event != 'select' || (action == null && selection == null)) {
      return null;
    }
    return (type, detail) {
      final selected = detail['row'] ?? detail['node'] ?? detail;
      if (selection != null) item.write(selection, selected);
      if (action != null) {
        final index = detail['index'];
        final scope = listField != null && index is int
            ? item.itemScope(item.raw[listField], index)
            : null;
        item.fire(action, scope: scope);
      }
    };
  };
}

/// What a kit builder's `handler` argument is.
typedef KitHandler = void Function(String, Map<String, dynamic>)? Function(
    String event);

KitHandler _none = (_) => null;

CatalogItem _kit(
  String name,
  String description, {
  String? kitType,
  Map<String, String> props = const {},
  List<String> required = const [],
  bool interactive = false,
  String? listField,
  bool compact = false,
}) =>
    traderaItem(
      name,
      description: description,
      properties: {
        ..._props(props),
        if (interactive) ...{
          'selection': P.selection(),
          'action': P.action('Fired when an item is tapped, in its scope.'),
        },
      },
      required: required,
      build: (item, p) {
        final build = kitBuilders[kitType ?? name]!;
        Widget out = build(p, const [],
            interactive ? _taps(item, listField: listField) : _none);
        if (compact) {
          out = Align(
              alignment: Alignment.centerLeft, widthFactor: 1, child: out);
        }
        return out;
      },
    );

/// A kit view with children.
CatalogItem _container(
  String name,
  String description, {
  String? kitType,
  Map<String, String> props = const {},
  List<String> required = const ['children'],
}) =>
    traderaItem(
      name,
      description: description,
      properties: {..._props(props), 'children': P.children()},
      required: required,
      build: (item, p) => item.children(
        item.raw['children'] ?? [if (item.raw['child'] is String) item.raw['child']],
        (children) => kitBuilders[kitType ?? name]!(p, children, _none),
      ),
    );

final chartItem = _kit(
  'Chart',
  'A chart: line, area, bar, scatter, bubble, candlestick, histogram, pie, '
      'donut, radar, heatmap or treemap.',
  props: {
    ..._framed,
    'type': 'line|area|bar|scatter|bubble|candlestick|histogram|pie|donut|'
        'radar|heatmap|treemap',
    'data': 'The rows (a {"path"} binding or literal list).',
    'x': 'The category / time field.',
    'y': 'One value field.',
    'series': 'Value series: field names or {field, label?, color?}.',
    'stacked': 'Stack bars / areas.',
    'horizontal': 'Horizontal bars.',
    'smooth': 'Smooth lines.',
    'points': 'Show points on lines.',
    'zero': 'Start the value axis at zero.',
    'valueLabels': 'Label every value.',
    'legend': 'Show the legend.',
    'xFormat': 'Format of x values.',
    'yFormat': 'Format of y values.',
    'format': 'Format of values.',
    'xLabel': 'The x axis title.',
    'yLabel': 'The y axis title.',
    'min': 'Value axis minimum.',
    'max': 'Value axis maximum.',
    'height': 'Height in pixels (220–320).',
    'size': 'Bubble size field.',
    'open': 'Candlestick open field.',
    'high': 'Candlestick high field.',
    'low': 'Candlestick low field.',
    'close': 'Candlestick close field.',
    'label': 'Pie / treemap label field.',
    'value': 'Pie / treemap / heatmap value field.',
    'bins': 'Histogram bin count.',
    'field': 'Histogram value field.',
    'centerLabel': 'Donut center text.',
    'centerCaption': 'Donut center caption.',
    'colorBy': 'Treemap color field (signed).',
    'colorFormat': 'Treemap color value format.',
    'group': 'Treemap group field.',
    'rows': 'Heatmap row labels.',
    'columns': 'Heatmap column labels.',
    'values': 'Heatmap value matrix.',
    'diverging': 'Heatmap diverging colors.',
    'showValues': 'Heatmap: print values.',
    'cellHeight': 'Heatmap cell height.',
    'valueLabel': 'The value\'s name in tooltips.',
  },
  interactive: true,
  listField: 'data',
);

final sparklineItem = _kit('Sparkline', 'A small inline trend line.', props: {
  'values': 'The numbers.',
  'data': 'Rows (with "field").',
  'field': 'The value field of the rows.',
  'color': 'A series color.',
  'height': 'Height in pixels.',
  'width': 'Width in pixels.',
  'type': 'line or bar.',
  'area': 'Fill under the line.',
});

final gaugeItem = _kit('Gauge', 'A dial for a value against a range.',
    props: {
      'value': 'The value.',
      'min': 'The low end (default 0).',
      'max': 'The high end (default 100).',
      'label': 'What it measures.',
      'format': 'Value format.',
      'thresholds': '[{value, status}] bands.',
      'color': 'A color.',
      'size': 'Diameter in pixels.',
    },
    required: ['value']);

final heatmapItem = _kit('Heatmap', 'A matrix of colored cells.',
    props: {
      ..._framed,
      'data': 'Rows of {x, y, value} (or use rows/columns/values).',
      'x': 'The column field.',
      'y': 'The row field.',
      'value': 'The value field.',
      'rows': 'Row labels.',
      'columns': 'Column labels.',
      'values': 'A matrix [[…]].',
      'format': 'Value format.',
      'xFormat': 'Column label format.',
      'yFormat': 'Row label format.',
      'diverging': 'Diverging colors around 0.',
      'showValues': 'Print values in cells.',
      'cellHeight': 'Cell height.',
      'valueLabel': 'The value\'s name in tooltips.',
    },
    interactive: true,
    listField: 'data');

final treemapItem = _kit('Treemap', 'Nested rectangles sized by value.',
    props: {
      ..._framed,
      'data': 'The rows.',
      'label': 'The label field.',
      'value': 'The size field.',
      'group': 'A grouping field.',
      'colorBy': 'A signed field coloring the cells.',
      'format': 'Value format.',
      'colorFormat': 'colorBy format.',
      'height': 'Height in pixels.',
      'valueLabel': 'The value\'s name in tooltips.',
      'colorLabel': 'colorBy\'s name in tooltips.',
    },
    required: ['data'],
    interactive: true,
    listField: 'data');

final graphItem = _kit('Graph', 'A network of nodes and edges.',
    props: {
      ..._framed,
      'nodes': '[{id, label?, group?}].',
      'edges': '[{from, to, label?}].',
      'layout': 'force, circle or tree.',
      'directed': 'Draw arrows.',
      'size': 'Node size.',
      'height': 'Height in pixels.',
    },
    required: ['nodes'],
    interactive: true,
    listField: 'nodes');

final tableItem = _kit(
    'Table',
    'A sortable, searchable table of records — the best view for lists.',
    kitType: 'DataGrid',
    props: {
      'title': 'A title above the table.',
      'data': 'The rows.',
      'columns': '[{field, label?, type?: text|number|trend|badge|progress|'
          'sparkline|image|avatar|boolean|link, format?, align?}].',
      'sortable': 'Allow sorting (default true).',
      'search': 'Show a search field.',
      'searchHint': 'The search field hint.',
      'pageSize': 'Rows per page.',
      'striped': 'Alternate row shading.',
      'dense': 'Compact rows.',
      'maxHeight': 'Scroll beyond this height.',
      'sortBy': 'The initial sort field.',
      'sortDirection': 'asc or desc.',
      'emptyText': 'Shown when there are no rows.',
    },
    required: ['data'],
    interactive: true,
    listField: 'data');

final statItem = _kit('Stat', 'A KPI tile: label, value, delta, trend.',
    props: {
      'label': 'What it measures.',
      'value': 'The value.',
      'format': 'Value format.',
      'delta': 'The change.',
      'deltaFormat': 'Change format (e.g. +percent:1).',
      'deltaLabel': 'The period ("vs last week").',
      'goodDirection': 'up or down.',
      'trend': 'Numbers for a sparkline.',
      'icon': 'An icon name.',
      'caption': 'A caption.',
      'size': 'small, medium or large.',
      'status': 'A status color.',
      'color': 'An accent color.',
    },
    required: ['label', 'value']);

final keyValueItem = _kit('KeyValue', 'Labelled values.', props: {
  'items': '[{label, value, format?, type?}].',
  'data': 'An object (its fields become items).',
  'labels': 'Labels by field.',
  'formats': 'Formats by field.',
  'columns': 'Number of columns.',
  'layout': 'list or grid.',
});

final timelineItem = _kit('Timeline', 'Events in time order.',
    props: {
      'data': 'Rows of {title, description?, time, status?, icon?}.',
      'titleField': 'The title field.',
      'descriptionField': 'The description field.',
      'timeField': 'The time field.',
      'timeFormat': 'Time format.',
    },
    required: ['data'],
    interactive: true,
    listField: 'data');

final treeViewItem = _kit('TreeView', 'A collapsible tree.',
    props: {
      'data': '{label, children: [...]}.',
      'labelField': 'The label field.',
      'childrenField': 'The children field.',
      'expanded': 'Levels open at first.',
      'format': 'Value format.',
    },
    required: ['data'],
    interactive: true);

final jsonViewItem = _kit('JsonView', 'A collapsible JSON value.',
    props: {'value': 'The value.', 'expanded': 'Levels open at first.'},
    required: ['value']);

final codeBlockItem = _kit('CodeBlock', 'Monospaced code.',
    props: {
      'code': 'The code.',
      'language': 'Its language.',
      'lineNumbers': 'Number the lines.',
      'maxHeight': 'Scroll beyond this height.',
    },
    required: ['code']);

final progressItem = _kit('Progress', 'A progress bar or ring.', props: {
  'value': 'Progress (0–1, or of max).',
  'max': 'The total.',
  'variant': 'linear or circular.',
  'label': 'What progresses.',
  'showValue': 'Print the value.',
  'color': 'A color.',
  'status': 'A status color.',
  'format': 'Value format.',
  'size': 'Ring size.',
  'thickness': 'Stroke width.',
});

final badgeItem = _kit('Badge', 'A pill label: state, tag, status.',
    kitType: 'Tag',
    props: {
      'text': 'The text.',
      'color': 'A series color or #hex.',
      'status': 'good, warning, serious or critical.',
      'variant': 'tonal, filled or outline.',
      'icon': 'An icon name.',
    },
    required: ['text'],
    compact: true);

final avatarItem = _kit('Avatar', 'A person or entity: image or initials.',
    props: {
      'name': 'The name.',
      'url': 'An image.',
      'size': 'Diameter.',
      'color': 'A color.'
    },
    compact: true);

final ratingItem = traderaItem(
  'Rating',
  description: 'Stars for a score; editable when bound.',
  properties: _props({
    'value': 'The score.',
    'max': 'Stars (default 5).',
    'size': 'Star size.',
    'color': 'A color.',
    'showValue': 'Print the score.',
    'editable': 'Let the person set it (needs a binding).',
  }),
  required: ['value'],
  build: (item, p) {
    final editable = toBool(p['editable']) && isBinding(item.raw['value']);
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: kitBuilders['Rating']!(p, const [], (event) {
        if (!editable || event != 'change') return null;
        return (_, d) => item.write(item.raw['value'], d['value']);
      }),
    );
  },
);

final calloutItem = _container('Callout', 'A highlighted message.',
    props: {
      'title': 'The title.',
      'text': 'The message.',
      'severity': 'info, good, warning or critical.',
      'icon': 'An icon name.',
    },
    required: const []);

final gridItem = _container(
    'Grid',
    'Responsive equal columns: as many as fit at minColumnWidth (dashboards, '
        'tiles, forms).',
    kitType: 'ResponsiveGrid',
    props: {
      'columns': 'A fixed column count.',
      'minColumnWidth': 'The narrowest column (default 220).',
      'maxColumns': 'At most this many columns.',
      'gap': 'Space between cells.',
      'runGap': 'Space between rows.',
    });

final sectionItem = _container('Section', 'A titled block of content.',
    props: {
      'title': 'The title.',
      'subtitle': 'A caption.',
      'icon': 'An icon name.',
      'trailing': 'Text at the end of the header.',
      'gap': 'Space between children.',
    },
    required: const ['title', 'children']);

final expandableItem = _container('Expandable', 'A collapsible panel.',
    props: {
      'title': 'The title.',
      'subtitle': 'A caption.',
      'expanded': 'Open at first.',
    },
    required: const ['title', 'children']);

final scrollItem = _container('Scroll', 'Scrolls its content.',
    props: {
      'direction': 'vertical or horizontal.',
      'maxHeight': 'Scroll beyond this height.',
    },
    required: const []);

final wrapItem = traderaItem(
  'Wrap',
  description: 'Children in a row that wraps (buttons, chips, filters).',
  properties: {
    ..._props({
      'spacing': 'Space between children.',
      'runSpacing': 'Space between rows.',
      'alignment': 'start, center, end or spaceBetween.',
    }),
    'children': P.children(),
  },
  required: ['children'],
  build: (item, p) => item.children(
    item.raw['children'],
    (children) => Wrap(
      spacing: toNum(p['spacing'])?.toDouble() ?? 8,
      runSpacing: toNum(p['runSpacing'])?.toDouble() ??
          toNum(p['spacing'])?.toDouble() ??
          8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: switch (p['alignment']) {
        'center' => WrapAlignment.center,
        'end' => WrapAlignment.end,
        'spaceBetween' => WrapAlignment.spaceBetween,
        _ => WrapAlignment.start,
      },
      children: children,
    ),
  ),
);

Alignment _alignment(Object? spec, [Alignment fallback = Alignment.center]) =>
    switch ('$spec'.replaceAll(RegExp(r'[\s_-]'), '').toLowerCase()) {
      'topleft' || 'topstart' => Alignment.topLeft,
      'topcenter' || 'top' => Alignment.topCenter,
      'topright' || 'topend' => Alignment.topRight,
      'centerleft' || 'left' || 'start' || 'centerstart' => Alignment.centerLeft,
      'center' => Alignment.center,
      'centerright' || 'right' || 'end' || 'centerend' => Alignment.centerRight,
      'bottomleft' || 'bottomstart' => Alignment.bottomLeft,
      'bottomcenter' || 'bottom' => Alignment.bottomCenter,
      'bottomright' || 'bottomend' => Alignment.bottomRight,
      _ => fallback,
    };

final stackItem = traderaItem(
  'Stack',
  description: 'Children layered on top of each other.',
  properties: {
    ..._props({
      'alignment': 'center, topLeft, bottomRight…',
      'height': 'Height in pixels.',
    }),
    'children': P.children(),
  },
  required: ['children'],
  build: (item, p) => item.children(item.raw['children'], (children) {
    final height = toNum(p['height'])?.toDouble();
    final stack =
        Stack(alignment: _alignment(p['alignment']), children: children);
    return height == null ? stack : SizedBox(height: height, child: stack);
  }),
);

/// Padding / margin: a number, "v h" / "t r b l" text, or {top, right…}.
EdgeInsets? genUiInsets(Object? v) {
  if (v is num) return EdgeInsets.all(v.toDouble());
  if (v is String) {
    final parts = v
        .trim()
        .split(RegExp(r'[\s,]+'))
        .map((s) => double.tryParse(s.replaceAll('px', '')))
        .whereType<double>()
        .toList();
    return switch (parts.length) {
      1 => EdgeInsets.all(parts[0]),
      2 => EdgeInsets.symmetric(vertical: parts[0], horizontal: parts[1]),
      3 => EdgeInsets.fromLTRB(parts[1], parts[0], parts[1], parts[2]),
      4 => EdgeInsets.fromLTRB(parts[3], parts[0], parts[1], parts[2]),
      _ => null,
    };
  }
  if (v is Map) {
    double d(Object? x) => toNum(x)?.toDouble() ?? 0;
    final h = d(v['horizontal']), vv = d(v['vertical']);
    return EdgeInsets.fromLTRB(
        d(v['left'] ?? v['start']) + h,
        d(v['top']) + vv,
        d(v['right'] ?? v['end']) + h,
        d(v['bottom']) + vv);
  }
  return null;
}

final boxItem = traderaItem(
  'Box',
  description: 'A decorated box around one child.',
  properties: {
    ..._props({
      'padding': 'Inner space.',
      'margin': 'Outer space.',
      'width': 'Width.',
      'height': 'Height.',
      'minHeight': 'Minimum height.',
      'maxWidth': 'Maximum width.',
      'color': 'Background: a token, series color or #hex.',
      'gradient': 'Background colors [a, b, …].',
      'borderRadius': 'Corner radius.',
      'borderColor': 'Border color.',
      'borderWidth': 'Border width.',
      'alignment': 'Where the child sits.',
      'elevation': 'Shadow depth.',
    }),
    'child': P.child(),
  },
  build: (item, p) => Builder(builder: (context) {
    double? n(String k) => toNum(p[k])?.toDouble();
    final gradient = p['gradient'];
    final colors = gradient is List && gradient.length >= 2
        ? [
            for (final g in gradient)
              genUiColor(context, g) ?? Colors.transparent
          ]
        : null;
    final border = genUiColor(context, p['borderColor']);
    final elevation = n('elevation') ?? 0;
    Widget out = Container(
      padding: genUiInsets(p['padding']),
      margin: genUiInsets(p['margin']),
      width: n('width'),
      height: n('height'),
      alignment: p['alignment'] == null ? null : _alignment(p['alignment']),
      constraints: BoxConstraints(
          minHeight: n('minHeight') ?? 0,
          maxWidth: n('maxWidth') ?? double.infinity),
      decoration: BoxDecoration(
        color: colors == null ? genUiColor(context, p['color']) : null,
        gradient: colors == null
            ? null
            : LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
        borderRadius: n('borderRadius') == null
            ? null
            : BorderRadius.circular(n('borderRadius')!),
        border: border == null
            ? null
            : Border.all(color: border, width: n('borderWidth') ?? 1),
        boxShadow: elevation > 0
            ? [
                BoxShadow(
                    color: Colors.black.withValues(alpha: .2),
                    offset: Offset(0, elevation),
                    blurRadius: elevation * 3)
              ]
            : null,
      ),
      child: item.raw['child'] is String ? item.child(item.raw['child']) : null,
    );
    if (n('maxWidth') != null) {
      out = Align(alignment: Alignment.topLeft, widthFactor: 1, child: out);
    }
    return out;
  }),
);

final centerItem = traderaItem(
  'Center',
  description: 'Centers its child.',
  properties: {'child': P.child()},
  required: ['child'],
  build: (item, p) => Center(child: item.child(item.raw['child'])),
);

final spacerItem = traderaItem(
  'Spacer',
  description: 'Empty space.',
  properties: _props({'size': 'Pixels (default 16).'}),
  build: (item, p) {
    final size = toNum(p['size'])?.toDouble() ?? 16;
    return SizedBox(width: size, height: size);
  },
);

final aspectRatioItem = traderaItem(
  'AspectRatio',
  description: 'Sizes its child to a width / height ratio.',
  properties: {..._props({'ratio': 'Width ÷ height.'}), 'child': P.child()},
  required: ['child', 'ratio'],
  build: (item, p) => AspectRatio(
      aspectRatio: (toNum(p['ratio']) ?? 1).toDouble().clamp(0.05, 20),
      child: item.child(item.raw['child'])),
);

final switchItem = traderaItem(
  'Switch',
  description: 'An on/off switch with a label, bound to a boolean.',
  properties: {
    ..._props({'label': 'The label.'}),
    'value': P.any('A {"path"} binding to a boolean.'),
  },
  required: ['value'],
  raw: {'value'},
  build: (item, p) => _GenUiSwitch(item: item, label: stringifyValue(p['label'])),
);

class _GenUiSwitch extends StatefulWidget {
  const _GenUiSwitch({required this.item, required this.label});
  final GenUiItem item;
  final String label;

  @override
  State<_GenUiSwitch> createState() => _GenUiSwitchState();
}

class _GenUiSwitchState extends State<_GenUiSwitch> {
  bool? _local;

  @override
  Widget build(BuildContext context) {
    final binding = widget.item.raw['value'];
    return Resolved(
      context: widget.item.dataContext,
      value: binding,
      builder: (context, v) {
        final on = isBinding(binding) ? toBool(v) : (_local ?? toBool(v));
        void set(bool value) {
          if (isBinding(binding)) {
            widget.item.write(binding, value);
          } else {
            setState(() => _local = value);
          }
        }

        final toggle = Switch(value: on, onChanged: set);
        if (widget.label.isEmpty) {
          return Align(
              alignment: Alignment.centerLeft, widthFactor: 1, child: toggle);
        }
        return InkWell(
          borderRadius: BorderRadius.circular(AppShape.control),
          onTap: () => set(!on),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(
                  child: Text(widget.label,
                      style: genUiTextStyle(context, 'body'))),
              toggle,
            ]),
          ),
        );
      },
    );
  }
}

final toolFrontendItem = traderaItem(
  'ToolFrontend',
  description: 'A tool\'s own frontend embedded in the surface.',
  properties: {
    'tool': S.string(description: 'The tool (bot) id.'),
    'height': S.number(description: 'Height in pixels (default 320).'),
    'microtool':
        S.string(description: 'The result to open it on: a microtool…'),
    'args': S.any(description: '…and its arguments.'),
    'frontend': S.string(description: 'Filled in by the node.'),
    'name': S.string(description: 'Filled in by the node.'),
  },
  required: ['tool'],
  build: (item, p) => Builder(builder: (context) {
    final height = toNum(p['height'])?.toDouble() ?? 320;
    final host = GenUiHost.maybeOf(context);
    return host?.toolFrontend
            ?.call(context, stringifyValue(p['tool']), height, p) ??
        SizedBox(height: height);
  }),
);

final elpianItem = traderaItem(
  'Elpian',
  description: 'Any node of the Elpian engine (every Flutter widget and HTML '
      'element it renders) for what no component covers: {type, props: '
      '{style}, children: [nodes or {"slot": componentId}], events: {click: '
      'action}}.',
  properties: {'node': P.any('The node tree.')},
  required: ['node'],
  raw: {'node'},
  build: (item, p) => _ElpianNodeView(item: item, node: item.raw['node']),
);

class _ElpianNodeView extends StatefulWidget {
  const _ElpianNodeView({required this.item, required this.node});
  final GenUiItem item;
  final Object? node;

  @override
  State<_ElpianNodeView> createState() => _ElpianNodeViewState();
}

class _ElpianNodeViewState extends State<_ElpianNodeView> {
  ElpianEngine? _engine;
  Object? _services;

  static const _slotType = 'GenUiSlot';

  ElpianEngine _engineFor(BuildContext context) {
    final services = GenUiHost.maybeOf(context)?.elpianServices;
    if (_engine == null || !identical(services, _services)) {
      _services = services;
      final engine = ElpianEngine(services: services);
      registerUiKit(engine);
      engine.registerWidget(
          _slotType,
          (ElpianNode node, List<Widget> children) =>
              widget.item.child(node.props['slot']));
      _engine = engine;
    }
    return _engine!;
  }

  @override
  Widget build(BuildContext context) {
    // Every node's props, in tree order, resolved together.
    final props = <Object?>[];
    void collect(Object? node) {
      if (node is! Map || node['slot'] is String) return;
      props.add(node['props']);
      final children = node['children'];
      if (children is List) children.forEach(collect);
    }

    collect(widget.node);
    final engine = _engineFor(context);
    return Resolved(
      context: widget.item.dataContext,
      value: props,
      builder: (context, resolved) {
        final values = resolved is List ? resolved : const <Object?>[];
        var i = 0;
        var n = 0;
        Map<String, dynamic> lower(Object? node) {
          final m = node is Map ? node : const <String, dynamic>{};
          if (m['slot'] is String) {
            return {
              'type': _slotType,
              'key': 'slot:${m['slot']}',
              'props': {'slot': m['slot']},
            };
          }
          final p = i < values.length ? values[i++] : null;
          final events = <String, dynamic>{};
          final declared = m['events'];
          if (declared is Map) {
            declared.forEach((name, action) {
              if (action is Map &&
                  (action.containsKey('event') ||
                      action.containsKey('functionCall'))) {
                events['$name'] = (ElpianEvent e) {
                  e.stopPropagation();
                  widget.item.fire(action);
                };
              }
            });
          }
          return {
            'type': '${m['type'] ?? 'Container'}',
            'key': m['key'] is String ? '${m['key']}' : 'n${n++}',
            'props': p is Map ? p.cast<String, dynamic>() : <String, dynamic>{},
            'children': [
              for (final c in m['children'] is List
                  ? m['children'] as List
                  : const <Object?>[])
                lower(c),
            ],
            if (events.isNotEmpty) 'events': events,
          };
        }

        return engine.renderFromJson(lower(widget.node));
      },
    );
  }
}

/// Tradera's components.
final List<CatalogItem> traderaItems = [
  chartItem, sparklineItem, gaugeItem, heatmapItem, treemapItem, graphItem, //
  tableItem, statItem, keyValueItem, timelineItem, treeViewItem, jsonViewItem,
  codeBlockItem, progressItem, badgeItem, ratingItem, calloutItem, avatarItem,
  gridItem, wrapItem, stackItem, boxItem, centerItem, spacerItem,
  aspectRatioItem, scrollItem, sectionItem, expandableItem, switchItem,
  elpianItem, toolFrontendItem,
];
