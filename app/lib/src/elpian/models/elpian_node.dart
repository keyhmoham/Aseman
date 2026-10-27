import 'css_style.dart';

class ElpianNode {
  final String type;
  final Map<String, dynamic> props;
  final List<ElpianNode> children;
  final CSSStyle? style;
  final String? key;
  final Map<String, dynamic>? events;

  const ElpianNode({
    required this.type,
    this.props = const {},
    this.children = const [],
    this.style,
    this.key,
    this.events,
  });

  /// A node from its JSON form, read leniently: view trees come from
  /// generated programs, and one odd entry must not take the screen down.
  /// `null` / `false` / `true` children are skipped (JS `cond && node`,
  /// `cond ? node : null`, `undefined` in arrays), nested arrays flatten,
  /// strings and numbers become Text nodes, maps with non-string keys are
  /// keyed by their string form, and non-object props/events are ignored.
  factory ElpianNode.fromJson(Map<String, dynamic> json) {
    final rawProps = json['props'];
    final props = rawProps is Map ? stringKeyed(rawProps) : <String, dynamic>{};
    // Include top-level style in props so the engine can parse it
    if (json['style'] != null && !props.containsKey('style')) {
      props['style'] = json['style'];
    }
    final type = json['type'];
    final key = json['key'];
    final events = json['events'];
    return ElpianNode(
      type: type is String && type.isNotEmpty ? type : 'Unknown',
      props: props,
      children: childrenOf(json['children']),
      key: key == null ? null : (key is String ? key : '$key'),
      events: events is Map ? stringKeyed(events) : null,
    );
  }

  /// [m] with string keys (a map decoded elsewhere may be `Map<dynamic,
  /// dynamic>`).
  static Map<String, dynamic> stringKeyed(Map<dynamic, dynamic> m) =>
      m is Map<String, dynamic> ? Map<String, dynamic>.of(m) : {for (final e in m.entries) '${e.key}': e.value};

  /// The nodes of a `children` value (see [ElpianNode.fromJson]).
  static List<ElpianNode> childrenOf(Object? raw) {
    final out = <ElpianNode>[];
    void add(Object? c) {
      if (c == null || c is bool) return;
      if (c is List) {
        for (final x in c) {
          add(x);
        }
      } else if (c is Map) {
        out.add(ElpianNode.fromJson(stringKeyed(c)));
      } else if (c is String || c is num) {
        out.add(ElpianNode(type: 'Text', props: {'text': '$c'}));
      }
    }

    add(raw);
    return out;
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'props': props,
      'children': children.map((child) => child.toJson()).toList(),
      if (key != null) 'key': key,
      if (events != null) 'events': events,
    };
  }

  ElpianNode copyWith({
    String? type,
    Map<String, dynamic>? props,
    List<ElpianNode>? children,
    CSSStyle? style,
    String? key,
    Map<String, dynamic>? events,
  }) {
    return ElpianNode(
      type: type ?? this.type,
      props: props ?? this.props,
      children: children ?? this.children,
      style: style ?? this.style,
      key: key ?? this.key,
      events: events ?? this.events,
    );
  }
}
