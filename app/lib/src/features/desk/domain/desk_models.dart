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

/// AG-UI messages a composed window holds (`{title, messages}`), or none.
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

/// The frontend of a window that shows its result with the tool's own app
/// (MCP Apps).
const String appFrontend = 'app';
const String composedTool = 'widgets';

/// The kind of a window that shows a web page served from the space's
/// sandbox through a preview gateway (an agent's interactive frontend for a
/// tool, a site it built); its args hold `{"page": "/v1/proxy/<id>/…"}`.
/// Pages of no tool share the dock entry [webTool].
const String webKind = 'web';
const String webTool = 'pages';

/// The kind of a window that shows a file of the space's workspace with the
/// app's own viewer; its args hold `{"path": "/workspace/…"}`. Every file
/// window shares the dock entry [fileTool].
const String fileKind = 'file';
const String fileTool = 'files';

/// The kind of a window that shows the project's computer: its desktop,
/// live and driven in the window. It has no args (the app asks for the
/// desktop when it shows one); there is one at most, under [computerTool].
const String computerKind = 'computer';
const String computerTool = 'computer';

/// How a window sits on the phone board (the desk as compact widgets).
/// Empty [shape] / [size] take the frontend's hint, else a medium card.
class DeskCompact {
  const DeskCompact({this.order = 0, this.shape = '', this.size = ''});

  factory DeskCompact.fromJson(Object? j) {
    final m = _map(j);
    return DeskCompact(
      order: (m['order'] as num?)?.toInt() ?? 0,
      shape: '${m['shape'] ?? ''}',
      size: '${m['size'] ?? ''}',
    );
  }

  static const shapes = ['card', 'squircle', 'pill', 'circle', 'leaf'];
  static const sizes = ['small', 'medium', 'large'];

  final int order;
  final String shape;
  final String size;

  bool get isEmpty => shape.isEmpty && size.isEmpty;

  DeskCompact copyWith({int? order, String? shape, String? size}) =>
      DeskCompact(
          order: order ?? this.order,
          shape: shape ?? this.shape,
          size: size ?? this.size);

  Map<String, dynamic> toJson() => {
        'order': order,
        if (shape.isNotEmpty) 'shape': shape,
        if (size.isNotEmpty) 'size': size,
      };
}

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
    this.compact,
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
        compact:
            j['compact'] is Map ? DeskCompact.fromJson(j['compact']) : null,
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

  /// Shown with the tool's own app (MCP Apps).
  bool get isApp => frontend == appFrontend;

  /// A web page (a preview of the space) rather than a tool's own frontend.
  bool get isWeb => kind == webKind;

  /// The gateway path a web page window shows.
  String get page => isWeb ? '${args['page'] ?? ''}' : '';

  /// A workspace file rather than a tool's own frontend.
  bool get isFile => kind == fileKind;

  /// The workspace path a file window shows.
  String get filePath => isFile ? '${args['path'] ?? ''}' : '';

  /// The stored file a file window shows (one shared in a chat or a post),
  /// or '' for a workspace file.
  String get fileId => isFile ? '${args['file_id'] ?? ''}' : '';

  /// The project's computer rather than a tool's own frontend.
  bool get isComputer => kind == computerKind;
  final String name;
  final String title;

  /// static or generative.
  final String frontend;
  final String microtool;
  final Map<String, dynamic> args;
  final Rect rect;
  final int z;

  /// Its place and look on the phone board (null: not arranged yet).
  final DeskCompact? compact;
  final String openedBy;

  String get label => title.isNotEmpty ? title : name;

  /// The result the window's frontend opens on, if any.
  ShownResult? get shown => microtool.isEmpty && args.isEmpty
      ? null
      : ShownResult(microtool: microtool, args: args);

  /// "city: New York · units: metric" (nothing for a web page or a file).
  String get argsSummary => isWeb || isFile
      ? ''
      : args.entries
      .where((e) => e.value is! Map && e.value is! List)
      .map((e) => '${e.key}: ${e.value}')
      .join(' · ');

  DeskWindow copyWith({Rect? rect, int? z, DeskCompact? compact}) =>
      DeskWindow(
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
        compact: compact ?? this.compact,
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
    this.compact,
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
        compact:
            j['compact'] is Map ? DeskCompact.fromJson(j['compact']) : null,
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

  /// The look its widget had on the phone board.
  final DeskCompact? compact;

  bool get isComposed => kind == composedKind;

  /// What the person asked for: an interface designed for it is shown
  /// (frontend `auto`), its [template] kept with the window.
  final String request;
  final Map<String, dynamic> template;

  /// designing, ready, or `failed: why`.
  final String status;

  bool get isDesigned => frontend == designedFrontend;

  /// Shown with the tool's own app (MCP Apps).
  bool get isApp => frontend == appFrontend;

  /// A web page (a preview of the space).
  bool get isWeb => kind == webKind;
  String get page => isWeb ? '${args['page'] ?? ''}' : '';

  /// A workspace file.
  bool get isFile => kind == fileKind;
  String get filePath => isFile ? '${args['path'] ?? ''}' : '';
  String get fileId => isFile ? '${args['file_id'] ?? ''}' : '';

  /// The project's computer.
  bool get isComputer => kind == computerKind;

  String get label => title.isNotEmpty ? title : name;

  ShownResult? get shown => microtool.isEmpty && args.isEmpty
      ? null
      : ShownResult(microtool: microtool, args: args);

  String get argsSummary => isWeb || isFile
      ? ''
      : args.entries
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

  /// The windows in phone-board order (unarranged ones last, as opened).
  List<DeskWindow> get boardOrder {
    final indexed = [for (var i = 0; i < windows.length; i++) (i, windows[i])];
    indexed.sort((a, b) {
      final oa = a.$2.compact?.order ?? 1 << 30;
      final ob = b.$2.compact?.order ?? 1 << 30;
      return oa != ob ? oa.compareTo(ob) : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
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
