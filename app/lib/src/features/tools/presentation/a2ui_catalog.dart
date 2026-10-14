/// Tradera's A2UI catalog: the basic catalog, plus
///
/// * data views — Chart (line, area, bar, scatter, bubble, candlestick,
///   histogram, pie, donut, radar, heatmap, treemap), Sparkline, Gauge,
///   Heatmap, Treemap, Graph, Table, Stat, KeyValue, Timeline, TreeView,
///   JsonView, CodeBlock, Progress, Badge, Rating, Callout, Avatar;
/// * layout — Grid, Wrap, Stack, Box, Center, Spacer, AspectRatio, Scroll,
///   Section, Expandable;
/// * Switch, and `Elpian`: any node of the Elpian engine (every Flutter
///   widget and HTML element it renders), for what no component covers;
/// * ToolFrontend: a tool's own frontend embedded in the surface.
///
/// Data props take literals, `{"path"}` bindings or function calls, at any
/// depth. Interactive views (Chart, Heatmap, Treemap, Graph, Table,
/// Timeline, TreeView) take `selection` — a binding the tapped row is
/// written to (master–detail without a round trip) — and `action`, fired
/// with the tapped item's scope, so its context resolves relative paths
/// against that row.
library;

import '../../../elpian/elpian.dart';
import '../ui_kit/kit.dart' show chartTypes, VizPalette;

const PropSpec _any = PropSpec('any');
const PropSpec _children = PropSpec('ChildList');
const PropSpec _child = PropSpec('ComponentId');

ComponentSpec _spec(List<String> props,
        {List<String> required = const [],
        Map<String, PropSpec> special = const {}}) =>
    ComponentSpec({
      for (final p in props) p: _any,
      ...special,
    }, required);

const List<String> _interactive = ['action', 'selection'];
const List<String> _framed = ['title', 'subtitle'];

/// The components Tradera adds to the basic catalog, by name.
final Map<String, ComponentSpec> traderaComponents = {
  'Chart': _spec([
    ..._framed, ..._interactive, 'data', 'x', 'y', 'series', 'stacked', //
    'horizontal', 'smooth', 'points', 'zero', 'valueLabels', 'legend',
    'xFormat', 'yFormat', 'format', 'xLabel', 'yLabel', 'min', 'max', 'height',
    'size', 'open', 'high', 'low', 'close', 'label', 'value', 'bins', 'field',
    'centerLabel', 'centerCaption', 'colorBy', 'colorFormat', 'group', 'rows',
    'columns', 'values', 'diverging', 'showValues', 'cellHeight', 'valueLabel',
  ], special: {
    'type': const PropSpec('string',
        enumValues: [...chartTypes, 'heatmap', 'treemap'],
        defaultValue: 'line'),
  }),
  'Sparkline': _spec(
      ['values', 'data', 'field', 'color', 'height', 'width', 'type', 'area']),
  'Gauge': _spec(
      ['value', 'min', 'max', 'label', 'format', 'thresholds', 'color', 'size'],
      required: ['value']),
  'Heatmap': _spec([
    ..._framed, ..._interactive, 'data', 'x', 'y', 'value', 'rows', //
    'columns', 'values', 'format', 'xFormat', 'yFormat', 'diverging',
    'showValues', 'cellHeight', 'valueLabel',
  ]),
  'Treemap': _spec([
    ..._framed, ..._interactive, 'data', 'label', 'value', 'group', //
    'colorBy', 'format', 'colorFormat', 'height', 'valueLabel', 'colorLabel',
  ], required: [
    'data'
  ]),
  'Graph': _spec([
    ..._framed, ..._interactive, 'nodes', 'edges', 'layout', 'directed', //
    'size', 'height',
  ], required: [
    'nodes'
  ]),
  'Table': _spec([
    'title', ..._interactive, 'data', 'columns', 'sortable', 'search', //
    'searchHint', 'pageSize', 'striped', 'dense', 'maxHeight', 'sortBy',
    'sortDirection', 'emptyText',
  ], required: [
    'data'
  ]),
  'Stat': _spec([
    'label', 'value', 'format', 'delta', 'deltaFormat', 'deltaLabel', //
    'goodDirection', 'trend', 'icon', 'caption', 'size', 'status', 'color',
  ], required: [
    'label',
    'value'
  ]),
  'KeyValue':
      _spec(['items', 'data', 'labels', 'formats', 'columns', 'layout']),
  'Timeline': _spec([
    ..._interactive, 'data', 'titleField', 'descriptionField', 'timeField', //
    'timeFormat',
  ], required: [
    'data'
  ]),
  'TreeView': _spec([
    ..._interactive, 'data', 'labelField', 'childrenField', 'expanded', //
    'format',
  ], required: [
    'data'
  ]),
  'JsonView': _spec(['value', 'expanded'], required: ['value']),
  'CodeBlock': _spec(['code', 'language', 'lineNumbers', 'maxHeight'],
      required: ['code']),
  'Progress': _spec([
    'value', 'max', 'variant', 'label', 'showValue', 'color', 'status', //
    'format', 'size', 'thickness',
  ]),
  'Badge':
      _spec(['text', 'color', 'status', 'variant', 'icon'], required: ['text']),
  'Rating': _spec(['value', 'max', 'size', 'color', 'showValue', 'editable'],
      required: ['value']),
  'Callout': _spec(['title', 'text', 'severity', 'icon'],
      special: {'children': _children}),
  'Avatar': _spec(['name', 'url', 'size', 'color']),
  // Layout.
  'Grid': _spec(['columns', 'minColumnWidth', 'maxColumns', 'gap', 'runGap'],
      special: {'children': _children}, required: ['children']),
  'Wrap': _spec(['spacing', 'runSpacing'],
      special: {'children': _children}, required: ['children']),
  'Stack': _spec(['alignment', 'height'],
      special: {'children': _children}, required: ['children']),
  'Box': _spec([
    'padding', 'margin', 'width', 'height', 'minHeight', 'maxWidth', //
    'color', 'gradient', 'borderRadius', 'borderColor', 'borderWidth',
    'alignment', 'elevation',
  ], special: {
    'child': _child
  }),
  'Center': _spec([], special: {'child': _child}, required: ['child']),
  'Spacer': _spec(['size']),
  'AspectRatio': _spec(['ratio'],
      special: {'child': _child}, required: ['child', 'ratio']),
  'Scroll': _spec(['direction', 'maxHeight'],
      special: {'child': _child, 'children': _children}),
  'Section': _spec(['title', 'subtitle', 'icon', 'trailing', 'gap'],
      special: {'children': _children}, required: ['title', 'children']),
  'Expandable': _spec(['title', 'subtitle', 'expanded'],
      special: {'children': _children}, required: ['title', 'children']),
  // Inputs and escape hatches.
  'Switch': _spec(['label'],
      special: {'value': const PropSpec('DynamicBoolean')},
      required: ['value']),
  'Elpian': _spec(['node'], required: ['node']),
  'ToolFrontend': const ComponentSpec({
    'tool': PropSpec('string'),
    'height': PropSpec('number'),
    // The result to open it on (frontend_show): a microtool and its args.
    'microtool': PropSpec('string'),
    'args': PropSpec('any'),
    // Filled in by the node when an agent composes the widget.
    'frontend': PropSpec('string'),
    'name': PropSpec('string'),
  }, [
    'tool'
  ]),
};

/// Tradera's A2UI catalog (the basic catalog's id: surfaces created for the
/// basic catalog get these components too).
final A2UICatalog traderaCatalog = A2UICatalog(
  id: basicCatalog.id,
  aliases: basicCatalog.aliases,
  components: {...basicCatalog.components, ...traderaComponents},
  functions: basicCatalog.functions,
  implementations: basicCatalog.implementations,
);

/// The Elpian node type a `ToolFrontend` component lowers to.
const String toolFrontendNodeType = 'TraderaToolFrontend';

/// Lowerings of Tradera's components (ToolFrontend excepted: its host
/// lowers it).
Map<String, A2UICustomLowering> traderaLowerings() => {
      'Chart': _kit('Chart', listField: 'data'),
      'Sparkline': _kit('Sparkline'),
      'Gauge': _kit('Gauge'),
      'Heatmap': _kit('Heatmap', listField: 'data'),
      'Treemap': _kit('Treemap', listField: 'data'),
      'Graph': _kit('Graph', listField: 'nodes'),
      'Table': _kit('DataGrid', listField: 'data'),
      'Stat': _kit('Stat'),
      'KeyValue': _kit('KeyValue'),
      'Timeline': _kit('Timeline', listField: 'data'),
      'TreeView': _kit('TreeView'),
      'JsonView': _kit('JsonView'),
      'CodeBlock': _kit('CodeBlock'),
      'Progress': _kit('Progress'),
      'Badge': _kit('Tag'),
      'Avatar': _kit('Avatar'),
      'Rating': _rating,
      'Callout': _container('Callout'),
      'Grid': _container('ResponsiveGrid'),
      'Section': _container('Section'),
      'Expandable': _container('Expandable'),
      'Scroll': _container('Scroll'),
      'Wrap': _wrap,
      'Stack': _stack,
      'Box': _box,
      'Center': (c, key, ctx) => _node('Center', key, const {},
          [if (c['child'] is String) ctx.child(c['child'] as String)]),
      'Spacer': (c, key, ctx) {
        final size = ctx.number(c['size']) ?? 16;
        return _node('SizedBox', key, {
          'style': {'width': size, 'height': size}
        });
      },
      'AspectRatio': (c, key, ctx) => _node(
          'AspectRatio',
          key,
          {'aspectRatio': (ctx.number(c['ratio']) ?? 1).toDouble()},
          [if (c['child'] is String) ctx.child(c['child'] as String)]),
      'Switch': _switch,
      'Elpian': _elpian,
    };

const Set<String> _own = {
  'id', 'component', 'weight', 'accessibility', 'action', 'selection', //
  'children', 'child',
};

LoweredNode _node(String type, String key, Map<String, dynamic> props,
        [List<LoweredNode> children = const [],
        Map<String, dynamic>? events]) =>
    {
      'type': type,
      'key': key,
      'props': props,
      'children': children,
      if (events != null && events.isNotEmpty) 'events': events,
    };

/// The component's own props, every binding and call in them evaluated.
Map<String, dynamic> _props(Map<String, dynamic> c, A2UICustomContext ctx) => {
      for (final e in c.entries)
        if (!_own.contains(e.key)) e.key: ctx.resolve(e.value),
    };

/// A data view: props resolved; a tap writes `selection` and fires `action`
/// in the tapped item's scope (`listField` names the prop holding the items).
A2UICustomLowering _kit(String type, {String? listField}) => (c, key, ctx) {
      final events = <String, dynamic>{};
      if (c['action'] != null || c['selection'] != null) {
        events['select'] = (ElpianEvent e) {
          e.stopPropagation();
          final detail = Map<String, dynamic>.of(e.data);
          final selected = detail['row'] ?? detail['node'] ?? detail;
          if (c['selection'] != null) ctx.write(c['selection'], selected);
          if (c['action'] != null) {
            final index = detail['index'];
            final scope = listField != null && index is int
                ? ctx.itemScope(c[listField], index)
                : null;
            ctx.action(c['action'], scope: scope);
          }
        };
      }
      return _node(type, key, _leaf(_props(c, ctx)), const [], events);
    };

/// Kit views carry the leaf margin basic components have.
Map<String, dynamic> _leaf(Map<String, dynamic> props) => {
      ...props,
      'style': {'margin': 4},
    };

/// A view with children (ids or a template).
A2UICustomLowering _container(String type) => (c, key, ctx) => _node(
        type,
        key,
        type == 'Callout' || type == 'Expandable'
            ? _leaf(_props(c, ctx))
            : _props(c, ctx),
        [
          if (c['child'] is String) ctx.child(c['child'] as String),
          if (c['children'] != null) ...ctx.children(c['children']),
        ]);

LoweredNode _rating(Map<String, dynamic> c, String key, A2UICustomContext ctx) {
  final editable =
      ctx.boolean(c['editable']) && ctx.bindingPath(c['value']) != null;
  return _node('Rating', key, _leaf(_props(c, ctx)), const [], {
    if (editable)
      'change': (ElpianEvent e) {
        e.stopPropagation();
        ctx.write(c['value'], e.data['value']);
      },
  });
}

LoweredNode _wrap(Map<String, dynamic> c, String key, A2UICustomContext ctx) =>
    _node(
        'Wrap',
        key,
        {
          'style': {
            'gap': ctx.number(c['spacing']) ?? 8,
            'rowGap':
                ctx.number(c['runSpacing']) ?? ctx.number(c['spacing']) ?? 8,
          }
        },
        ctx.children(c['children']));

LoweredNode _stack(Map<String, dynamic> c, String key, A2UICustomContext ctx) {
  final height = ctx.number(c['height']);
  return _node(
      'Stack',
      key,
      {
        'style': {
          'alignment': ctx.string(c['alignment']).isEmpty
              ? 'center'
              : ctx.string(c['alignment']),
          if (height != null) 'height': height,
        }
      },
      ctx.children(c['children']));
}

LoweredNode _box(Map<String, dynamic> c, String key, A2UICustomContext ctx) {
  final style = <String, dynamic>{};
  for (final k in [
    'padding',
    'margin',
    'width',
    'height',
    'minHeight',
    'maxWidth',
    'borderRadius'
  ]) {
    final v = ctx.resolve(c[k]);
    if (v is num || v is String) style[k] = v;
  }
  final color = _color(ctx.resolve(c['color']), ctx.palette);
  if (color != null) style['backgroundColor'] = color;
  final gradient = ctx.resolve(c['gradient']);
  if (gradient is List && gradient.length >= 2) {
    style['gradient'] = {
      'type': 'linear',
      'colors': [
        for (final g in gradient) _color(g, ctx.palette) ?? '#00000000'
      ],
      'begin': 'topLeft',
      'end': 'bottomRight',
    };
  }
  final border = _color(ctx.resolve(c['borderColor']), ctx.palette);
  if (border != null) {
    style['border'] = '${ctx.number(c['borderWidth']) ?? 1}px solid $border';
  }
  final alignment = ctx.resolve(c['alignment']);
  if (alignment is String) style['alignment'] = alignment;
  final elevation = ctx.number(c['elevation']);
  if (elevation != null && elevation > 0) {
    style['boxShadow'] = [
      {
        'color': '#33000000',
        'offset': {'x': 0, 'y': elevation},
        'blurRadius': elevation * 3,
      }
    ];
  }
  return _node('Container', key, {'style': style},
      [if (c['child'] is String) ctx.child(c['child'] as String)]);
}

/// A color spec as hex: `#hex`, a categorical hue or slot (`blue`,
/// `series-2`), a status (`good`…), or a surface token.
String? _color(Object? spec, A2UIPalette palette) {
  if (spec is! String || spec.isEmpty) return null;
  if (spec.startsWith('#')) return spec;
  String hex(int argb) =>
      '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  final tokens = {
    'surface': palette.surface,
    'surfaceVariant': palette.surfaceContainer,
    'surfaceHigh': palette.surfaceContainerHigh,
    'primary': palette.primary,
    'primaryContainer': palette.primaryContainer,
    'outline': palette.outlineVariant,
    'good': hex(VizPalette.good.toARGB32()),
    'warning': hex(VizPalette.warning.toARGB32()),
    'serious': hex(VizPalette.serious.toARGB32()),
    'critical': hex(VizPalette.critical.toARGB32()),
  };
  if (tokens.containsKey(spec)) return tokens[spec];
  const hues = [
    'blue',
    'orange',
    'aqua',
    'yellow',
    'magenta',
    'green',
    'violet',
    'red'
  ];
  final slot = hues.indexOf(spec) >= 0
      ? hues.indexOf(spec)
      : (int.tryParse(spec.replaceFirst('series-', '')) ?? 0) - 1;
  final colors = VizPalette.categoricalOf(palette.dark);
  return slot >= 0 && slot < colors.length
      ? hex(colors[slot].toARGB32())
      : null;
}

LoweredNode _switch(Map<String, dynamic> c, String key, A2UICustomContext ctx) {
  final on = ctx.boolean(c['value']);
  final label = ctx.string(c['label']);
  return _node('Row', key, {
    'style': {'alignItems': 'center', 'margin': 4}
  }, [
    if (label.isNotEmpty)
      _node('Expanded', '$key/label', const {}, [
        _node('Text', '$key/text', {
          'text': label,
          'style': {'fontSize': 16, 'color': ctx.palette.onSurface}
        })
      ]),
    _node('Switch', '$key/switch', {
      'value': on
    }, const [], {
      'change': (ElpianEvent e) {
        e.stopPropagation();
        ctx.write(c['value'], eventValue(e) == true);
      },
    }),
  ]);
}

/// `Elpian`: a raw Elpian node tree. Bindings and calls anywhere in props
/// are evaluated; `{"slot": "<component id>"}` in a children list embeds an
/// A2UI component; an event whose value is an A2UI action
/// (`{"event": {...}}` / `{"functionCall": {...}}`) fires it.
LoweredNode _elpian(Map<String, dynamic> c, String key, A2UICustomContext ctx) {
  var n = 0;
  LoweredNode raw(Object? node) {
    final m = node is Map ? node : const <String, dynamic>{};
    if (m['slot'] is String) return ctx.child(m['slot'] as String);
    final events = <String, dynamic>{};
    final declared = m['events'];
    if (declared is Map) {
      declared.forEach((name, action) {
        if (action is Map &&
            (action.containsKey('event') ||
                action.containsKey('functionCall'))) {
          events['$name'] = (ElpianEvent e) {
            e.stopPropagation();
            ctx.action(action);
          };
        }
      });
    }
    final props = ctx.resolve(m['props']);
    return _node(
      '${m['type'] ?? 'Container'}',
      m['key'] is String ? '$key/${m['key']}' : '$key/${n++}',
      props is Map<String, dynamic> ? props : <String, dynamic>{},
      [
        for (final child
            in m['children'] is List ? m['children'] as List : const [])
          raw(child)
      ],
      events,
    );
  }

  return raw(c['node']);
}
