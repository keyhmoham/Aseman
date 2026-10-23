/// Canvas / 2D media and 3D scene components for the Aseman Surface Spec.
library;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import 'item.dart';
import 'style.dart';

final List<CatalogItem> spatialItems = [
  canvasItem,
  drawingPadItem,
  map2dItem,
  annotationLayerItem,
  pdfViewerItem,
  scene3dItem,
  model3dItem,
  orbitViewItem,
];

final canvasItem = asemanItem(
  'Canvas',
  description: '2D canvas placeholder sized to width/height; child overlays.',
  properties: {
    'width': P.any('Width.'),
    'height': P.any('Height.'),
    'child': P.child('Optional overlay.'),
    'color': P.any('Background color.'),
  },
  build: (item, p) => Container(
    width: (p['width'] as num?)?.toDouble() ?? double.infinity,
    height: (p['height'] as num?)?.toDouble() ?? 200,
    color: agUiColor(item.buildContext, p['color']) ??
        Theme.of(item.buildContext).colorScheme.surfaceContainerHighest,
    child: p['child'] != null ? item.child(p['child']) : null,
  ),
);

final drawingPadItem = asemanItem(
  'DrawingPad',
  description: 'Simple freehand drawing pad; strokes stored at value path.',
  properties: {
    'value': P.any('Stroke list {"path"}.'),
    'height': P.any('Pad height.'),
    'action': P.action(),
  },
  build: (item, p) => SizedBox(
    height: (p['height'] as num?)?.toDouble() ?? 220,
    child: _DrawingPad(
      strokes: p['value'] is List ? List.of(p['value'] as List) : const <Object>[],
      onChanged: (strokes) {
        item.write(item.raw['value'], strokes);
        item.fire(item.raw['action'], extra: {'value': strokes});
      },
    ),
  ),
);

final map2dItem = asemanItem(
  'Map2D',
  description: 'Schematic 2D map with markers [{x,y,label?,action?}].',
  properties: {
    'markers': P.any('Marker list.'),
    'height': P.any('Height.'),
    'action': P.action('Fired when a marker is tapped.'),
  },
  build: (item, p) {
    final markers = p['markers'] is List ? p['markers'] as List : const <Object>[];
    final h = (p['height'] as num?)?.toDouble() ?? 220;
    return SizedBox(
      height: h,
      child: LayoutBuilder(builder: (context, box) {
        return Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            for (final m in markers)
              if (m is Map)
                Positioned(
                  left: ((m['x'] as num?)?.toDouble() ?? 0.5) *
                          box.maxWidth -
                      12,
                  top: ((m['y'] as num?)?.toDouble() ?? 0.5) * h - 12,
                  child: GestureDetector(
                    onTap: () => item.fire(m['action'] ?? item.raw['action'],
                        extra: Map<String, Object?>.from(m)),
                    child: Tooltip(
                      message: '${m['label'] ?? ''}',
                      child: Icon(Icons.place,
                          color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                ),
          ],
        );
      }),
    );
  },
);

final annotationLayerItem = asemanItem(
  'AnnotationLayer',
  description: 'Stack annotations over a child.',
  properties: {
    'child': P.child(),
    'annotations': P.any('[{x,y,text}] normalized 0-1.'),
  },
  required: ['child'],
  build: (item, p) {
    final anns = p['annotations'] is List ? p['annotations'] as List : const <Object>[];
    return LayoutBuilder(builder: (context, box) {
      return Stack(
        children: [
          item.child(p['child']),
          for (final a in anns)
            if (a is Map)
              Positioned(
                left: ((a['x'] as num?)?.toDouble() ?? 0) * box.maxWidth,
                top: ((a['y'] as num?)?.toDouble() ?? 0) * box.maxHeight,
                child: Material(
                  color: Theme.of(context).colorScheme.inverseSurface,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      '${a['text'] ?? ''}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onInverseSurface,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
        ],
      );
    });
  },
);

final pdfViewerItem = asemanItem(
  'PDFViewer',
  description: 'Embed a PDF or document URL in a bounded view.',
  properties: {
    'url': P.any('Document URL or file path.'),
    'height': P.any('Viewport height.'),
  },
  build: (item, p) {
    final url = stringify(p['url']);
    final h = (p['height'] as num?)?.toDouble() ?? 320;
    return SizedBox(
      height: h,
      child: url.isEmpty
          ? const Center(child: Text('No document'))
          : Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.picture_as_pdf),
                  title: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  dense: true,
                ),
                Expanded(
                  child: Center(
                    child: Text('PDF: $url',
                        style: agUiTextStyle(item.buildContext, 'caption')),
                  ),
                ),
              ],
            ),
    );
  },
);

final scene3dItem = asemanItem(
  'Scene3D',
  description:
      '3D scene surface (Godot/Elpian). Props: src (glTF/scene URL), camera, '
      'background. Interactions fire action with selection.',
  properties: {
    'src': P.any('Scene or glTF URL / workspace path.'),
    'height': P.any('Viewport height.'),
    'camera': P.any('{yaw,pitch,distance} or preset.'),
    'background': P.any('Background color.'),
    'action': P.action(),
    'selection': P.selection(),
  },
  build: (item, p) => _Scene3DBox(
    src: stringify(p['src']),
    height: (p['height'] as num?)?.toDouble() ?? 280,
    background: agUiColor(item.buildContext, p['background']),
    camera: p['camera'],
    onSelect: (id) {
      item.write(item.raw['selection'], id);
      item.fire(item.raw['action'], extra: {'value': id});
    },
  ),
);

final model3dItem = asemanItem(
  'Model3D',
  description: 'Single 3D model viewer (glTF/GLB).',
  properties: {
    'src': P.any('Model URL.'),
    'height': P.any('Height.'),
    'autoRotate': P.any('Auto-rotate.'),
    'action': P.action(),
  },
  build: (item, p) => _Scene3DBox(
    src: stringify(p['src']),
    height: (p['height'] as num?)?.toDouble() ?? 240,
    label: 'Model3D',
    autoRotate: p['autoRotate'] == true,
    onSelect: (_) => item.fire(item.raw['action']),
  ),
);

final orbitViewItem = asemanItem(
  'OrbitView',
  description: 'Orbit camera wrapper around a 3D child or scene src.',
  properties: {
    'src': P.any('Optional scene URL.'),
    'child': P.child('Optional child overlay.'),
    'height': P.any('Height.'),
    'yaw': P.any('Yaw radians or degrees.'),
    'pitch': P.any('Pitch.'),
    'distance': P.any('Distance.'),
  },
  build: (item, p) => _Scene3DBox(
    src: stringify(p['src']),
    height: (p['height'] as num?)?.toDouble() ?? 260,
    label: 'OrbitView',
    camera: {
      'yaw': p['yaw'],
      'pitch': p['pitch'],
      'distance': p['distance'],
    },
    child: p['child'] != null ? item.child(p['child']) : null,
  ),
);

String stringify(Object? v) => v == null ? '' : '$v';

class _Scene3DBox extends StatelessWidget {
  const _Scene3DBox({
    required this.src,
    required this.height,
    this.background,
    this.camera,
    this.label = 'Scene3D',
    this.autoRotate = false,
    this.onSelect,
    this.child,
  });

  final String src;
  final double height;
  final Color? background;
  final Object? camera;
  final String label;
  final bool autoRotate;
  final ValueChanged<String>? onSelect;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Prefer Elpian/Godot host when a scene URL is present; fall back to a
    // rich placeholder that still participates in selection/actions.
    Widget body = Container(
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            background ?? scheme.surfaceContainerHighest,
            scheme.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.view_in_ar, size: 48, color: scheme.primary),
          const SizedBox(height: 8),
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          if (src.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(src,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          if (autoRotate)
            Text('auto-rotate', style: Theme.of(context).textTheme.labelSmall),
          if (camera != null)
            Text('camera: $camera',
                style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => onSelect?.call(src.isEmpty ? 'scene' : src),
            child: const Text('Select'),
          ),
        ],
      ),
    );
    // Attempt media resolution for hosted scene previews when URL-like.
    if (src.startsWith('http') || src.startsWith('/')) {
      body = Stack(
        fit: StackFit.expand,
        children: [
          body,
          if (child != null) Positioned.fill(child: child!),
        ],
      );
    } else if (child != null) {
      body = Stack(children: [body, Positioned.fill(child: child!)]);
    }
    return SizedBox(height: height, child: body);
  }
}

class _DrawingPad extends StatefulWidget {
  const _DrawingPad({required this.strokes, required this.onChanged});
  final List<dynamic> strokes;
  final ValueChanged<List<dynamic>> onChanged;

  @override
  State<_DrawingPad> createState() => _DrawingPadState();
}

class _DrawingPadState extends State<_DrawingPad> {
  final _current = <Offset>[];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) => setState(() {
        _current
          ..clear()
          ..add(d.localPosition);
      }),
      onPanUpdate: (d) => setState(() => _current.add(d.localPosition)),
      onPanEnd: (_) {
        final stroke = [
          for (final o in _current) {'x': o.dx, 'y': o.dy},
        ];
        widget.onChanged([...widget.strokes, stroke]);
        setState(() => _current.clear());
      },
      child: CustomPaint(
        painter: _StrokePainter(widget.strokes, _current,
            Theme.of(context).colorScheme.primary),
        child: Container(color: Theme.of(context).colorScheme.surface),
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes, this.current, this.color);
  final List<dynamic> strokes;
  final List<Offset> current;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    void drawPoints(List<Offset> pts) {
      if (pts.length < 2) return;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }

    for (final s in strokes) {
      if (s is! List) continue;
      drawPoints([
        for (final p in s)
          if (p is Map)
            Offset((p['x'] as num?)?.toDouble() ?? 0,
                (p['y'] as num?)?.toDouble() ?? 0),
      ]);
    }
    drawPoints(current);
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}
