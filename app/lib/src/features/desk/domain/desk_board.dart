/// The free desk's whiteboard items as the node keeps them (spaces/desk_board.go):
/// note cards, shapes, free text, arrows and pen strokes, in the desk's
/// coordinate space beside the card windows. Coordinates are logical pixels
/// from the desk's origin and may be negative.
library;

import 'dart:ui';

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
double _num(Object? v, [double fallback = 0]) =>
    v is num ? v.toDouble() : fallback;

/// What an item is.
abstract final class DeskItemKind {
  static const note = 'note';
  static const shape = 'shape';
  static const text = 'text';
  static const arrow = 'arrow';
  static const stroke = 'stroke';
}

/// What the node and every client agree can be drawn.
abstract final class DeskBoardVocabulary {
  static const shapes = [
    'rect',
    'round',
    'ellipse',
    'diamond',
    'triangle',
    'hexagon',
  ];
  static const colors = [
    'yellow',
    'pink',
    'blue',
    'green',
    'purple',
    'orange',
    'red',
    'teal',
    'gray',
    'black',
    'white',
  ];
  static const heads = ['none', 'arrow', 'dot', 'bar'];
  static const dashes = ['solid', 'dashed', 'dotted'];
  static const paths = ['straight', 'curved', 'elbow'];
}

/// One end of an arrow: stuck to an item or a window (it then follows it),
/// or free at [point].
class DeskEnd {
  const DeskEnd({this.ref = '', this.point = Offset.zero});

  factory DeskEnd.fromJson(Object? j) {
    final m = _map(j);
    return DeskEnd(
      ref: '${m['ref'] ?? ''}',
      point: Offset(_num(m['x']), _num(m['y'])),
    );
  }

  final String ref;
  final Offset point;

  bool get stuck => ref.isNotEmpty;

  Map<String, dynamic> toJson() => stuck
      ? {'ref': ref}
      : {'x': point.dx.roundToDouble(), 'y': point.dy.roundToDouble()};

  @override
  bool operator ==(Object other) =>
      other is DeskEnd && other.ref == ref && other.point == point;

  @override
  int get hashCode => Object.hash(ref, point);
}

class DeskItem {
  const DeskItem({
    required this.id,
    required this.kind,
    this.rect = Rect.zero,
    this.z = 0,
    this.text = '',
    this.color = '',
    this.fill = '',
    this.shape = '',
    this.fontSize = 0,
    this.from,
    this.to,
    this.head = '',
    this.tail = '',
    this.dash = '',
    this.path = '',
    this.width = 0,
    this.points = const [],
    this.by = '',
  });

  factory DeskItem.fromJson(Map<String, dynamic> j) => DeskItem(
    id: '${j['id'] ?? ''}',
    kind: '${j['kind'] ?? ''}',
    rect: Rect.fromLTWH(
      _num(j['x']),
      _num(j['y']),
      _num(j['w']),
      _num(j['h']),
    ),
    z: (j['z'] as num?)?.toInt() ?? 0,
    text: '${j['text'] ?? ''}',
    color: '${j['color'] ?? ''}',
    fill: '${j['fill'] ?? ''}',
    shape: '${j['shape'] ?? ''}',
    fontSize: _num(j['font_size']),
    from: j['from'] is Map ? DeskEnd.fromJson(j['from']) : null,
    to: j['to'] is Map ? DeskEnd.fromJson(j['to']) : null,
    head: '${j['head'] ?? ''}',
    tail: '${j['tail'] ?? ''}',
    dash: '${j['dash'] ?? ''}',
    path: '${j['path'] ?? ''}',
    width: _num(j['width']),
    points: [
      for (final p in (j['points'] as List?) ?? const [])
        if (p is Map) Offset(_num(p['x']), _num(p['y'])),
    ],
    by: '${j['by'] ?? ''}',
  );

  final String id;
  final String kind;

  /// A note's, shape's or text's box (an arrow has none; a stroke's is the
  /// box around its points).
  final Rect rect;
  final int z;
  final String text;
  final String color;
  final String fill;
  final String shape;
  final double fontSize;
  final DeskEnd? from;
  final DeskEnd? to;
  final String head;
  final String tail;
  final String dash;
  final String path;
  final double width;
  final List<Offset> points;
  final String by;

  bool get isArrow => kind == DeskItemKind.arrow;
  bool get isStroke => kind == DeskItemKind.stroke;
  bool get isNote => kind == DeskItemKind.note;
  bool get isShape => kind == DeskItemKind.shape;
  bool get isText => kind == DeskItemKind.text;

  /// A thing with a box an arrow can stick to and people can type into.
  bool get isBox => isNote || isShape || isText;

  /// The words a box holds can be edited in place.
  bool get editable => isBox;

  /// Every field, for the node (a new item) and for undo (put it back).
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    if (!isArrow) ...{
      'x': rect.left.roundToDouble(),
      'y': rect.top.roundToDouble(),
    },
    if (isBox) ...{
      'w': rect.width.roundToDouble(),
      'h': rect.height.roundToDouble(),
    },
    if (text.isNotEmpty) 'text': text,
    if (color.isNotEmpty) 'color': color,
    if (fill.isNotEmpty) 'fill': fill,
    if (shape.isNotEmpty) 'shape': shape,
    if (fontSize > 0) 'font_size': fontSize,
    if (from != null) 'from': from!.toJson(),
    if (to != null) 'to': to!.toJson(),
    if (head.isNotEmpty) 'head': head,
    if (tail.isNotEmpty) 'tail': tail,
    if (dash.isNotEmpty) 'dash': dash,
    if (path.isNotEmpty) 'path': path,
    if (width > 0) 'width': width,
    if (points.isNotEmpty)
      'points': [
        for (final p in points)
          {'x': p.dx.roundToDouble(), 'y': p.dy.roundToDouble()},
      ],
  };

  /// An update that puts this item back as it is, fields it lacks cleared.
  Map<String, dynamic> toPatch() {
    final full = toJson()..remove('id')..remove('kind');
    for (final k in const [
      'text',
      'color',
      'fill',
      'shape',
      'font_size',
      'head',
      'tail',
      'dash',
      'path',
      'width',
    ]) {
      full.putIfAbsent(k, () => null);
    }
    return full;
  }

  DeskItem copyWith({
    Rect? rect,
    int? z,
    String? text,
    String? color,
    String? fill,
    String? shape,
    double? fontSize,
    DeskEnd? from,
    DeskEnd? to,
    String? head,
    String? tail,
    String? dash,
    String? path,
    double? width,
    List<Offset>? points,
  }) => DeskItem(
    id: id,
    kind: kind,
    rect: rect ?? this.rect,
    z: z ?? this.z,
    text: text ?? this.text,
    color: color ?? this.color,
    fill: fill ?? this.fill,
    shape: shape ?? this.shape,
    fontSize: fontSize ?? this.fontSize,
    from: from ?? this.from,
    to: to ?? this.to,
    head: head ?? this.head,
    tail: tail ?? this.tail,
    dash: dash ?? this.dash,
    path: path ?? this.path,
    width: width ?? this.width,
    points: points ?? this.points,
    by: by,
  );

  /// The stroke shifted by [d].
  DeskItem shifted(Offset d) {
    if (isArrow) {
      DeskEnd move(DeskEnd? e) => e == null || e.stuck
          ? (e ?? const DeskEnd())
          : DeskEnd(point: e.point + d);
      return copyWith(from: move(from), to: move(to));
    }
    if (isStroke) {
      return copyWith(
        rect: rect.shift(d),
        points: [for (final p in points) p + d],
      );
    }
    return copyWith(rect: rect.shift(d));
  }
}
