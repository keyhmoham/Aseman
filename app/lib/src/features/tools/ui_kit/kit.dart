/// Aseman's UI kit for tool frontends: charts, graphs, tables and data
/// views, and the layout pieces the Flutter widget set lacks as single
/// nodes. Each is an Elpian node type, so
///
/// * a **static** frontend (an Elpian VM or QuickJS program) renders them by
///   returning nodes like `{"type": "Chart", "props": {...}}`, next to every
///   Flutter and HTML node the engine already has; taps arrive as the node's
///   `select` (or `change`) event, its data the tapped row or point.
///
/// Props for each type are documented in `README.md` next to this file.
library;

import 'package:flutter/material.dart';

import '../../../elpian/core/elpian_engine.dart';
import '../../../elpian/core/node_events.dart';
import '../../../elpian/css/css_properties.dart';
import '../../../elpian/models/elpian_node.dart';
import 'app_widgets.dart';
import 'charts/cartesian_chart.dart';
import 'charts/distribution_charts.dart';
import 'charts/flow_charts.dart';
import 'charts/matrix_charts.dart';
import 'charts/network_graph.dart';
import 'charts/polar_charts.dart';
import 'charts/viz_canvas.dart';
import 'data_grid.dart';
import 'data_widgets.dart';
import 'layout.dart';
import 'palette.dart';
import 'structured_views.dart';
import 'tables.dart';
import 'text_views.dart';
import 'values.dart';

export 'app_widgets.dart';
export 'charts/cartesian_chart.dart';
export 'charts/chart_frame.dart';
export 'charts/distribution_charts.dart';
export 'charts/flow_charts.dart';
export 'charts/matrix_charts.dart';
export 'charts/network_graph.dart';
export 'charts/polar_charts.dart';
export 'charts/viz_canvas.dart';
export 'data_grid.dart';
export 'data_widgets.dart';
export 'layout.dart';
export 'palette.dart';
export 'qr_encoder.dart';
export 'structured_views.dart';
export 'tables.dart';
export 'text_views.dart';
export 'values.dart';

/// The chart types of a `Chart` node.
const List<String> chartTypes = [
  'line', 'area', 'bar', 'scatter', 'bubble', 'candlestick', 'histogram', //
  'pie', 'donut', 'radar', 'heatmap', 'treemap', //
  'funnel', 'waterfall', 'sankey', 'gantt', 'boxplot', 'sunburst', 'bullet',
  'segmented', 'radialbar', 'calendar', 'wordcloud',
];

/// Builds the kit widget of a node: [props] as the node carries them,
/// [children] its rendered children, [emit] dispatches one of its events
/// (null when the node declares no handler for it).
typedef KitBuilder = Widget Function(
    Map<String, dynamic> props,
    List<Widget> children,
    void Function(String event, Map<String, dynamic> data)? Function(
            String event)
        handler);

Widget _chart(Map<String, dynamic> props, ChartSelect? onSelect) {
  return Builder(builder: (context) {
    final p = VizPalette.of(context);
    final type = '${props['type'] ?? 'line'}'.toLowerCase();
    switch (type) {
      case 'pie':
      case 'donut':
        return PieChart(props: props, onSelect: onSelect);
      case 'radar':
        return RadarChart(props: props);
      case 'heatmap':
        return Heatmap(props: props, onSelect: onSelect);
      case 'treemap':
        return Treemap(props: props, onSelect: onSelect);
      case 'funnel':
        return FunnelChart(props: props, onSelect: onSelect);
      case 'waterfall':
        return WaterfallChart(props: props, onSelect: onSelect);
      case 'sankey':
        return SankeyChart(props: props, onSelect: onSelect);
      case 'gantt':
        return GanttChart(props: props, onSelect: onSelect);
      case 'boxplot':
      case 'box':
        return BoxPlotChart(props: props, onSelect: onSelect);
      case 'sunburst':
        return SunburstChart(props: props, onSelect: onSelect);
      case 'bullet':
        return BulletChart(props: props);
      case 'segmented':
      case 'stackedbar':
        return SegmentedBar(props: props, onSelect: onSelect);
      case 'radialbar':
      case 'rings':
        return RadialBars(props: props);
      case 'calendar':
        return CalendarHeatmap(props: props, onSelect: onSelect);
      case 'wordcloud':
        return WordCloud(props: props, onSelect: onSelect);
      default:
        return CartesianChart(
            spec: ChartSpec.fromProps(props, p), onSelect: onSelect);
    }
  });
}

/// Every kit node type and its builder.
final Map<String, KitBuilder> kitBuilders = {
  'Chart': (props, _, on) => _chart(props, _select(on)),
  'Sparkline': (props, _, __) =>
      Builder(builder: (c) => Sparkline.fromProps(props, VizPalette.of(c))),
  'Gauge': (props, _, __) => Gauge(props: props),
  'Heatmap': (props, _, on) => Heatmap(props: props, onSelect: _select(on)),
  'Treemap': (props, _, on) => Treemap(props: props, onSelect: _select(on)),
  'Graph': (props, _, on) => NetworkGraph(props: props, onSelect: _select(on)),
  'DataGrid': (props, _, on) => DataGrid(props: props, onSelect: _select(on)),
  'Stat': (props, _, __) => StatTile(props: props),
  'KeyValue': (props, _, __) => KeyValueList(props: props),
  'Timeline': (props, _, on) =>
      TimelineView(props: props, onSelect: _select(on)),
  'TreeView': (props, _, on) => TreeView(props: props, onSelect: _select(on)),
  'JsonView': (props, _, __) => JsonView(
      value: props['value'] ?? props['data'],
      expanded: asInt(props['expanded'], 2)),
  'CodeBlock': (props, _, __) => CodeBlock(props: props),
  'Progress': (props, _, __) => ProgressView(props: props),
  'Tag': (props, _, __) =>
      Builder(builder: (c) => Pill.fromProps(props, VizPalette.of(c))),
  'Rating': (props, _, on) {
    final change = on('change');
    return RatingView(
        props: props,
        onChange:
            change == null ? null : (v) => change('change', {'value': v}));
  },
  'Callout': (props, children, _) => Callout(props: props, children: children),
  'Avatar': (props, _, __) =>
      Builder(builder: (c) => KitAvatar.fromProps(props, VizPalette.of(c))),
  'ResponsiveGrid': (props, children, _) =>
      ResponsiveGrid.fromProps(props, children),
  'Section': (props, children, _) =>
      KitSection(props: props, children: children),
  'Expandable': (props, children, _) =>
      Expandable(props: props, children: children),
  // Charts of flows, distributions and calendars.
  'Funnel': (props, _, on) => FunnelChart(props: props, onSelect: _select(on)),
  'Waterfall': (props, _, on) => WaterfallChart(props: props, onSelect: _select(on)),
  'Sankey': (props, _, on) => SankeyChart(props: props, onSelect: _select(on)),
  'Gantt': (props, _, on) => GanttChart(props: props, onSelect: _select(on)),
  'BoxPlot': (props, _, on) => BoxPlotChart(props: props, onSelect: _select(on)),
  'BulletChart': (props, _, __) => BulletChart(props: props),
  'SegmentedBar': (props, _, on) => SegmentedBar(props: props, onSelect: _select(on)),
  'RadialBars': (props, _, __) => RadialBars(props: props),
  'Sunburst': (props, _, on) => SunburstChart(props: props, onSelect: _select(on)),
  'CalendarHeatmap': (props, _, on) => CalendarHeatmap(props: props, onSelect: _select(on)),
  'WordCloud': (props, _, on) => WordCloud(props: props, onSelect: _select(on)),
  // Tables.
  'PivotTable': (props, _, on) => PivotTable(props: props, onSelect: _select(on)),
  'Leaderboard': (props, _, on) => Leaderboard(props: props, onSelect: _select(on)),
  // App widgets.
  'Tabs': (props, children, on) => KitTabs(props: props, on: on, children: children),
  'Calendar': (props, _, on) => KitCalendar(props: props, on: on),
  'Kanban': (props, _, on) => KitKanban(props: props, on: on),
  'Carousel': (props, children, on) => KitCarousel(props: props, on: on, children: children),
  'Stepper': (props, _, on) => KitStepper(props: props, on: on),
  'Chat': (props, _, on) => KitChat(props: props, on: on),
  'Countdown': (props, _, on) => KitCountdown(props: props, on: on),
  'Clock': (props, _, __) => KitClock(props: props),
  'EmptyState': (props, _, on) => KitEmptyState(props: props, on: on),
  'AvatarGroup': (props, _, __) => KitAvatarGroup(props: props),
  'Pagination': (props, _, on) => KitPagination(props: props, on: on),
  'Breadcrumbs': (props, _, on) => KitBreadcrumbs(props: props, on: on),
  // Text views.
  'Markdown': (props, _, on) => KitMarkdown(props: props, on: on),
  'LogView': (props, _, __) => KitLogView(props: props),
  'DiffView': (props, _, __) => KitDiffView(props: props),
  'QRCode': (props, _, __) => KitQrCode(props: props),
  'Scroll': (props, children, _) {
    final horizontal = props['direction'] == 'horizontal';
    final child = children.length == 1
        ? children.first
        : horizontal
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children);
    final maxHeight = asSizeOrNull(props['maxHeight']);
    Widget out = SingleChildScrollView(
        scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
        child: child);
    if (maxHeight != null && !horizontal) {
      out = ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight), child: out);
    }
    return out;
  },
};

ChartSelect? _select(
    void Function(String, Map<String, dynamic>)? Function(String) on) {
  final emit = on('select');
  return emit == null ? null : (detail) => emit('select', _plain(detail));
}

/// Event data in plain JSON (it crosses into the VM).
Map<String, dynamic> _plain(Map<String, dynamic> m) => {
      for (final e in m.entries)
        if (e.value == null ||
            e.value is num ||
            e.value is String ||
            e.value is bool ||
            e.value is Map ||
            e.value is List)
          e.key: e.value,
    };

/// The width a kit node takes where the layout gives none (default 360).
const Map<String, double> fallbackWidths = {
  'Sparkline': 120, 'Progress': 160, 'Gauge': 180, 'Stat': 200, 'Callout': 320,
  'Gantt': 520, 'PivotTable': 520, 'Kanban': 880, 'Markdown': 480, 'DiffView': 520, 'LogView': 520,
  'CalendarHeatmap': 440, 'Calendar': 340, 'Chat': 360, 'Tabs': 360,
};

const Set<String> _compact = {'Tag', 'Avatar', 'Rating', 'AvatarGroup', 'QRCode', 'Clock', 'Countdown', 'Pagination'};

/// The kit node types (for prompts and docs).
Iterable<String> get kitTypes => kitBuilders.keys;

/// Registers the kit's node types on [engine]. The kit's interactive
/// widgets recognise their own taps, so the engine does not wrap them in a
/// competing gesture detector.
void registerUiKit(ElpianEngine engine) {
  ElpianEngine.selfDispatchingTypes.addAll(kitBuilders.keys);
  kitBuilders.forEach((type, build) {
    engine.registerWidget(type, (ElpianNode node, List<Widget> children) {
      final events = NodeEvents(node);
      Widget out = build(
        Map<String, dynamic>.of(node.props),
        children,
        (event) => events.has(event)
            ? (String type, Map<String, dynamic> data) =>
                events.emit(type, data: data)
            : null,
      );
      // Compact views keep their own width inside stretching columns; the
      // rest take a natural width where the layout gives none (in a Row).
      if (_compact.contains(type)) {
        out =
            Align(alignment: Alignment.centerLeft, widthFactor: 1, child: out);
      } else {
        out = WidthFallback(width: fallbackWidths[type] ?? 360, child: out);
      }
      if (node.style != null) out = CSSProperties.applyStyle(out, node.style);
      return out;
    });
  });
}

/// An engine with the kit registered (what static tool frontends render with).
ElpianEngine kitEngine() {
  final engine = ElpianEngine();
  registerUiKit(engine);
  return engine;
}
