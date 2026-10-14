/// A room's desk as the node keeps it (spaces.desktop_get): tools' frontends
/// open as floating card windows, pinned shortcuts, and the size of the desk
/// as last shown. Coordinates are logical pixels from the desk's top-left.
library;

import 'dart:convert';
import 'dart:ui';

import '../../tools/domain/tool_models.dart';

/// Geometry every client and the node share (spaces/desktop.go).
abstract final class DeskGeometry {
  /// Windows keep this far from the desk's edges.
  static const double margin = 16;

  /// The bottom band the dock and the command bar take.
  static const double bottomReserve = 168;
  static const double minW = 240, minH = 180;
  static const double defaultW = 460, defaultH = 560;
}

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
double _num(Object? v, double fallback) => v is num ? v.toDouble() : fallback;

/// A2UI messages a composed window holds (`{title, messages}`), or none.
List<Map<String, dynamic>> surfaceOf(Map<String, dynamic> widget) => [
      for (final m in (widget['messages'] as List?) ?? const <dynamic>[])
        if (m is Map) m.cast<String, dynamic>(),
    ];

/// The kind of a window that holds a widget an agent composed (ui_compose)
/// rather than one tool's frontend; such windows share the dock entry
/// [composedTool].
const String composedKind = 'composed';

/// The frontend of a window whose interface was designed for one request.
const String designedFrontend = 'auto';
const String composedTool = 'widgets';

class DeskWindow {
  const DeskWindow({
    required this.id,
    required this.tool,
    this.kind = '',
    this.widget = const {},
    this.request = '',
    this.template = const {},
    this.status = '',
    this.name = '',
    this.title = '',
    this.frontend = '',
    this.microtool = '',
    this.args = const {},
    required this.rect,
    this.z = 0,
    this.openedBy = '',
  });

  factory DeskWindow.fromJson(Map<String, dynamic> j) => DeskWindow(
        id: '${j['id'] ?? ''}',
        tool: '${j['tool'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        widget: _map(j['widget']),
        request: '${j['request'] ?? ''}',
        template: _map(j['template']),
        status: '${j['status'] ?? ''}',
        name: '${j['name'] ?? ''}',
        title: '${j['title'] ?? ''}',
        frontend: '${j['frontend'] ?? ''}',
        microtool: '${j['microtool'] ?? ''}',
        args: _map(j['args']),
        rect: Rect.fromLTWH(
            _num(j['x'], 0),
            _num(j['y'], 0),
            _num(j['w'], DeskGeometry.defaultW),
            _num(j['h'], DeskGeometry.defaultH)),
        z: (j['z'] as num?)?.toInt() ?? 0,
        openedBy: '${j['opened_by'] ?? ''}',
      );

  final String id;

  /// The tool's bot id ([composedTool] for composed widgets).
  final String tool;

  /// Empty for a tool's frontend; [composedKind] for a composed widget.
  final String kind;

  /// A composed widget's `{title, messages}`.
  final Map<String, dynamic> widget;

  bool get isComposed => kind == composedKind;

  /// What the person asked for: an interface designed for it is shown
  /// (frontend `auto`), its [template] kept with the window.
  final String request;
  final Map<String, dynamic> template;

  /// designing, ready, or `failed: why`.
  final String status;

  bool get isDesigned => frontend == designedFrontend;
  final String name;
  final String title;

  /// static or generative.
  final String frontend;
  final String microtool;
  final Map<String, dynamic> args;
  final Rect rect;
  final int z;
  final String openedBy;

  String get label => title.isNotEmpty ? title : name;

  /// The result the window's frontend opens on, if any.
  ShownResult? get shown => microtool.isEmpty && args.isEmpty
      ? null
      : ShownResult(microtool: microtool, args: args);

  /// "city: New York · units: metric".
  String get argsSummary => args.entries
      .where((e) => e.value is! Map && e.value is! List)
      .map((e) => '${e.key}: ${e.value}')
      .join(' · ');

  DeskWindow copyWith({Rect? rect, int? z}) => DeskWindow(
        id: id,
        tool: tool,
        kind: kind,
        widget: widget,
        request: request,
        template: template,
        status: status,
        name: name,
        title: title,
        frontend: frontend,
        microtool: microtool,
        args: args,
        rect: rect ?? this.rect,
        z: z ?? this.z,
        openedBy: openedBy,
      );
}

class DeskPin {
  const DeskPin({
    required this.id,
    required this.tool,
    this.kind = '',
    this.widget = const {},
    this.request = '',
    this.template = const {},
    this.status = '',
    this.name = '',
    this.title = '',
    this.frontend = '',
    this.microtool = '',
    this.args = const {},
    this.size = const Size(DeskGeometry.defaultW, DeskGeometry.defaultH),
  });

  factory DeskPin.fromJson(Map<String, dynamic> j) => DeskPin(
        id: '${j['id'] ?? ''}',
        tool: '${j['tool'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        widget: _map(j['widget']),
        request: '${j['request'] ?? ''}',
        template: _map(j['template']),
        status: '${j['status'] ?? ''}',
        name: '${j['name'] ?? ''}',
        title: '${j['title'] ?? ''}',
        frontend: '${j['frontend'] ?? ''}',
        microtool: '${j['microtool'] ?? ''}',
        args: _map(j['args']),
        size: Size(_num(j['w'], DeskGeometry.defaultW),
            _num(j['h'], DeskGeometry.defaultH)),
      );

  final String id;
  final String tool;
  final String kind;
  final Map<String, dynamic> widget;
  final String name;
  final String title;
  final String frontend;
  final String microtool;
  final Map<String, dynamic> args;
  final Size size;

  bool get isComposed => kind == composedKind;

  /// What the person asked for: an interface designed for it is shown
  /// (frontend `auto`), its [template] kept with the window.
  final String request;
  final Map<String, dynamic> template;

  /// designing, ready, or `failed: why`.
  final String status;

  bool get isDesigned => frontend == designedFrontend;

  String get label => title.isNotEmpty ? title : name;

  ShownResult? get shown => microtool.isEmpty && args.isEmpty
      ? null
      : ShownResult(microtool: microtool, args: args);

  String get argsSummary => args.entries
      .where((e) => e.value is! Map && e.value is! List)
      .map((e) => '${e.key}: ${e.value}')
      .join(' · ');
}

class DeskState {
  const DeskState({
    this.version = 0,
    this.viewport = Size.zero,
    this.windows = const [],
    this.pins = const [],
  });

  factory DeskState.fromJson(Map<String, dynamic> j) => DeskState(
        version: (j['version'] as num?)?.toInt() ?? 0,
        viewport: Size(_num(_map(j['viewport'])['w'], 0),
            _num(_map(j['viewport'])['h'], 0)),
        windows: [
          for (final w in (j['windows'] as List?) ?? const [])
            if (w is Map) DeskWindow.fromJson(w.cast<String, dynamic>())
        ],
        pins: [
          for (final p in (j['pins'] as List?) ?? const [])
            if (p is Map) DeskPin.fromJson(p.cast<String, dynamic>())
        ],
      );

  static const empty = DeskState();

  final int version;
  final Size viewport;
  final List<DeskWindow> windows;
  final List<DeskPin> pins;

  /// The tools with open windows, in the order their first window opened,
  /// with how many each has.
  List<(String tool, String name, int count)> get openTools {
    final order = <String>[];
    final names = <String, String>{};
    final counts = <String, int>{};
    for (final w in windows) {
      if (!counts.containsKey(w.tool)) order.add(w.tool);
      names[w.tool] = w.name;
      counts[w.tool] = (counts[w.tool] ?? 0) + 1;
    }
    return [for (final t in order) (t, names[t] ?? '', counts[t]!)];
  }

  DeskState copyWith({List<DeskWindow>? windows, List<DeskPin>? pins}) =>
      DeskState(
          version: version,
          viewport: viewport,
          windows: windows ?? this.windows,
          pins: pins ?? this.pins);
}

/// [surfaceOf], the same list for the same content: what renders a composed
/// window reloads only when its widget really changed, not on every poll.
abstract final class ComposedSurfaces {
  static final Expando<String> _signatures = Expando();
  static final Map<String, List<Map<String, dynamic>>> _cache = {};

  static List<Map<String, dynamic>> of(Map<String, dynamic> widget) {
    final signature = _signatures[widget] ??= jsonEncode(widget);
    final cached = _cache[signature];
    if (cached != null) return cached;
    if (_cache.length > 64) _cache.remove(_cache.keys.first);
    return _cache[signature] = surfaceOf(widget);
  }
}
