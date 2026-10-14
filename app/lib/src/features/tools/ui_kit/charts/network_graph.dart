/// A node-link graph: relations between entities (dependencies, flows,
/// org charts, knowledge graphs). Laid out by force simulation, on a circle,
/// or as layered tree; pans and zooms.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../palette.dart';
import '../values.dart';
import 'cartesian_chart.dart' show ChartSelect;
import 'chart_frame.dart';

class _GNode {
  _GNode(this.id, this.label, this.group, this.size, this.row);
  final String id;
  final String label;
  final String? group;
  final double size;
  final Map<String, dynamic> row;
  Offset pos = Offset.zero;
}

class _GEdge {
  _GEdge(this.from, this.to, this.label, this.weight);
  final int from;
  final int to;
  final String? label;
  final double weight;
}

class NetworkGraph extends StatefulWidget {
  const NetworkGraph({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final ChartSelect? onSelect;

  @override
  State<NetworkGraph> createState() => _NetworkGraphState();
}

class _NetworkGraphState extends State<NetworkGraph> {
  List<_GNode> _nodes = [];
  List<_GEdge> _edges = [];
  List<String> _groups = [];
  String? _selected;
  Object? _source;

  void _build() {
    final props = widget.props;
    // Laid out again only when the graph itself changes, not on every render.
    final signature = Object.hash(
        props['layout'],
        props['size'],
        Object.hashAll(asList(props['nodes'])
            .map((n) => asText(n is Map ? (n['id'] ?? n['label']) : n))),
        Object.hashAll(asList(props['edges'] ?? props['links']).map((e) =>
            e is Map
                ? '${e['from'] ?? e['source']}>${e['to'] ?? e['target']}'
                : e)));
    if (_source == signature && _nodes.isNotEmpty) return;
    _source = signature;
    final nodes = <_GNode>[];
    final index = <String, int>{};
    final groups = <String>[];
    final sizeField = props['size'] as String?;
    var maxSize = 0.0;
    for (final r in asRows(props['nodes'])) {
      final id = asText(r['id'] ?? r['name'] ?? r['label']);
      if (id.isEmpty || index.containsKey(id)) continue;
      final group = r['group'] == null ? null : asText(r['group']);
      if (group != null && !groups.contains(group)) groups.add(group);
      final size = sizeField == null
          ? 1.0
          : (asNum(field(r, sizeField)) ?? 1).toDouble();
      maxSize = math.max(maxSize, size);
      index[id] = nodes.length;
      nodes.add(
          _GNode(id, asText(r['label'] ?? r['name'] ?? id), group, size, r));
    }
    final edges = <_GEdge>[];
    for (final r in asRows(props['edges'] ?? props['links'])) {
      final a = asText(r['from'] ?? r['source']),
          b = asText(r['to'] ?? r['target']);
      // Edges may name nodes not listed: they are added.
      for (final id in [a, b]) {
        if (id.isNotEmpty && !index.containsKey(id)) {
          index[id] = nodes.length;
          nodes.add(_GNode(id, id, null, 1, {'id': id}));
        }
      }
      if (a.isEmpty || b.isEmpty) continue;
      edges.add(_GEdge(
          index[a]!,
          index[b]!,
          r['label'] == null ? null : asText(r['label']),
          (asNum(r['weight']) ?? 1).toDouble()));
    }
    _nodes = nodes;
    _edges = edges;
    _groups = groups;
    _layout('${props['layout'] ?? 'force'}');
  }

  void _layout(String layout) {
    final n = _nodes.length;
    if (n == 0) return;
    if (layout == 'circle') {
      for (var i = 0; i < n; i++) {
        final a = -math.pi / 2 + 2 * math.pi * i / n;
        _nodes[i].pos = Offset(math.cos(a), math.sin(a));
      }
      return;
    }
    if (layout == 'tree') {
      // Layers by breadth-first depth from the nodes nothing points to.
      final incoming = List<int>.filled(n, 0);
      final out = List.generate(n, (_) => <int>[]);
      for (final e in _edges) {
        incoming[e.to]++;
        out[e.from].add(e.to);
      }
      final depth = List<int>.filled(n, -1);
      final queue = <int>[
        for (var i = 0; i < n; i++)
          if (incoming[i] == 0) i
      ];
      if (queue.isEmpty) queue.add(0);
      for (final r in queue) {
        depth[r] = 0;
      }
      for (var q = 0; q < queue.length; q++) {
        for (final c in out[queue[q]]) {
          if (depth[c] < 0) {
            depth[c] = depth[queue[q]] + 1;
            queue.add(c);
          }
        }
      }
      for (var i = 0; i < n; i++) {
        if (depth[i] < 0) depth[i] = 0;
      }
      final layers = <int, List<int>>{};
      for (var i = 0; i < n; i++) {
        (layers[depth[i]] ??= []).add(i);
      }
      final maxDepth = layers.keys.reduce(math.max);
      layers.forEach((d, members) {
        for (var k = 0; k < members.length; k++) {
          _nodes[members[k]].pos = Offset(
              members.length == 1 ? 0 : -1 + 2 * k / (members.length - 1),
              maxDepth == 0 ? 0 : -1 + 2 * d / maxDepth);
        }
      });
      return;
    }
    // Force-directed (Fruchterman–Reingold), seeded so the same data always
    // lays out the same way.
    final rnd = math.Random(n * 7919 + _edges.length);
    for (final node in _nodes) {
      node.pos = Offset(rnd.nextDouble() * 2 - 1, rnd.nextDouble() * 2 - 1);
    }
    final k = math.sqrt(4 / n);
    var temp = 0.2;
    final iterations = n > 150 ? 120 : 260;
    for (var it = 0; it < iterations; it++) {
      final disp = List<Offset>.filled(n, Offset.zero);
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          var d = _nodes[i].pos - _nodes[j].pos;
          var dist = d.distance;
          if (dist < 1e-4) {
            d = Offset(rnd.nextDouble() - 0.5, rnd.nextDouble() - 0.5) * 0.01;
            dist = d.distance;
          }
          final f = d / dist * (k * k / dist);
          disp[i] += f;
          disp[j] -= f;
        }
      }
      for (final e in _edges) {
        if (e.from == e.to) continue;
        final d = _nodes[e.from].pos - _nodes[e.to].pos;
        final dist = math.max(1e-4, d.distance);
        final f = d / dist * (dist * dist / k);
        disp[e.from] -= f;
        disp[e.to] += f;
      }
      for (var i = 0; i < n; i++) {
        // A weak pull to the center keeps components together.
        final d = disp[i] - _nodes[i].pos * 0.05;
        final len = d.distance;
        if (len > 0) {
          _nodes[i].pos += d / len * math.min(len, temp);
        }
      }
      temp = math.max(0.005, temp * 0.97);
    }
    // Normalize to -1..1.
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final node in _nodes) {
      minX = math.min(minX, node.pos.dx);
      maxX = math.max(maxX, node.pos.dx);
      minY = math.min(minY, node.pos.dy);
      maxY = math.max(maxY, node.pos.dy);
    }
    final w = math.max(1e-6, maxX - minX), h = math.max(1e-6, maxY - minY);
    for (final node in _nodes) {
      node.pos = Offset(n == 1 ? 0 : (node.pos.dx - minX) / w * 2 - 1,
          n == 1 ? 0 : (node.pos.dy - minY) / h * 2 - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    _build();
    final p = VizPalette.of(context);
    final props = widget.props;
    final height = asDouble(props['height'], 320).clamp(140, 1000).toDouble();
    if (_nodes.isEmpty) {
      return ChartFrame(
          title: props['title'] as String?, child: NoData(height: height));
    }
    final directed = asBool(props['directed'], true);
    final maxSize = _nodes.map((n) => n.size).reduce(math.max);
    return ChartFrame(
      title: props['title'] as String?,
      subtitle: props['subtitle'] as String?,
      legend: _groups.length > 1
          ? [
              for (var i = 0; i < _groups.length; i++)
                LegendItem(_groups[i], p.series(i))
            ]
          : const [],
      child: SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LayoutBuilder(builder: (context, box) {
            final size = Size(box.maxWidth, height);
            Offset place(_GNode n) => Offset(
                size.width / 2 + n.pos.dx * (size.width / 2 - 48),
                size.height / 2 + n.pos.dy * (size.height / 2 - 32));
            double radius(_GNode n) =>
                6 + (maxSize <= 0 ? 0 : math.sqrt(n.size / maxSize) * 10);
            Color colorOf(_GNode n) =>
                p.parse(n.row['color']) ??
                (n.group == null
                    ? p.series(0)
                    : p.series(_groups.indexOf(n.group!)));
            return InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              boundaryMargin: const EdgeInsets.all(120),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) {
                  for (final n in _nodes.reversed) {
                    if ((place(n) - d.localPosition).distance <=
                        radius(n) + 6) {
                      setState(() => _selected = n.id);
                      widget.onSelect?.call({
                        'index': _nodes.indexOf(n),
                        'id': n.id,
                        'node': n.row,
                        'label': n.label
                      });
                      return;
                    }
                  }
                  setState(() => _selected = null);
                },
                child: CustomPaint(
                  size: size,
                  painter: _GraphPainter(
                    nodes: _nodes,
                    edges: _edges,
                    place: place,
                    radius: radius,
                    colorOf: colorOf,
                    directed: directed,
                    selected: _selected,
                    p: p,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.nodes,
    required this.edges,
    required this.place,
    required this.radius,
    required this.colorOf,
    required this.directed,
    required this.selected,
    required this.p,
  });
  final List<_GNode> nodes;
  final List<_GEdge> edges;
  final Offset Function(_GNode) place;
  final double Function(_GNode) radius;
  final Color Function(_GNode) colorOf;
  final bool directed;
  final String? selected;
  final VizPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final sel =
        selected == null ? -1 : nodes.indexWhere((n) => n.id == selected);
    final maxW =
        edges.isEmpty ? 1.0 : edges.map((e) => e.weight).reduce(math.max);
    for (final e in edges) {
      final a = place(nodes[e.from]), b = place(nodes[e.to]);
      final touches = sel >= 0 && (e.from == sel || e.to == sel);
      final color = touches ? p.textSecondary : p.axis;
      final paint = Paint()
        ..color = sel >= 0 && !touches ? color.withValues(alpha: 0.35) : color
        ..strokeWidth = 1 + (maxW <= 0 ? 0 : (e.weight / maxW) * 1.5)
        ..style = PaintingStyle.stroke;
      if (e.from == e.to) {
        canvas.drawCircle(a + Offset(0, -radius(nodes[e.from]) - 6), 6, paint);
        continue;
      }
      final d = b - a;
      final len = d.distance;
      if (len < 1) continue;
      final u = d / len;
      final start = a + u * radius(nodes[e.from]);
      final end = b - u * (radius(nodes[e.to]) + (directed ? 2 : 0));
      canvas.drawLine(start, end, paint);
      if (directed) {
        final normal = Offset(-u.dy, u.dx);
        final head = Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo((end - u * 8 + normal * 4).dx, (end - u * 8 + normal * 4).dy)
          ..lineTo((end - u * 8 - normal * 4).dx, (end - u * 8 - normal * 4).dy)
          ..close();
        canvas.drawPath(head, Paint()..color = paint.color);
      }
      if (e.label != null && e.label!.isNotEmpty && len > 60) {
        paintText(canvas, e.label!, (start + end) / 2,
            VizText.label(p).copyWith(fontSize: 10),
            align: 0, valign: 0, maxWidth: len - 20);
      }
    }
    final ring = Paint()
      ..color = p.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final label = VizText.label(p);
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final at = place(n);
      final r = radius(n);
      final dim = sel >= 0 &&
          i != sel &&
          !edges.any((e) =>
              (e.from == sel && e.to == i) || (e.to == sel && e.from == i));
      final color = colorOf(n);
      canvas.drawCircle(
          at, r, Paint()..color = dim ? color.withValues(alpha: 0.4) : color);
      canvas.drawCircle(at, r + 1, ring);
      if (i == sel) {
        canvas.drawCircle(
            at,
            r + 4,
            Paint()
              ..color = p.textPrimary
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
      paintText(canvas, n.label, at + Offset(0, r + 4),
          label.copyWith(color: dim ? p.textMuted : p.textPrimary),
          align: 0, maxWidth: 120);
    }
  }

  @override
  bool shouldRepaint(_GraphPainter old) => true;
}
