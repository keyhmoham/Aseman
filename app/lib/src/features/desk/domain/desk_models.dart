/// A room's desk as the node keeps it (spaces.desktop_get): tools' frontends
/// open as floating card windows, pinned shortcuts, and the size of the desk
/// as last shown. Coordinates are logical pixels from the desk's top-left.
library;

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

/// The frontend of a window that shows its result with the tool's own app
/// (MCP Apps).
const String appFrontend = 'app';

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

/// The kind of a window that shows an AG-UI generative surface (complex
/// non-interactive data viz). Args hold `{"surface": {…}}`.
const String aguiKind = 'agui';
const String aguiTool = 'agui';

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

  /// The tool's bot id.
  final String tool;

  /// Empty for a tool's frontend; [webKind], [fileKind], [computerKind], or
  /// [aguiKind] for desk card kinds.
  final String kind;

  /// Shown with the tool's own app (MCP Apps).
  bool get isApp => frontend == appFrontend;

  /// A web page (a preview of the space) rather than a tool's own frontend.
  bool get isWeb => kind == webKind;

  /// The gateway path a web page window shows.
  String get page => isWeb ? '${args['page'] ?? ''}' : '';

  /// An inline HTML report (`desk_show` ui web). Empty for a served page.
  String get reportHtml => isWeb ? '${args['html'] ?? ''}' : '';

  /// An inline Elpian report (`desk_show` ui elpian). Empty for a served app.
  String get reportProgram => isWeb ? '${args['program'] ?? ''}' : '';

  /// The source is in the window, not a preview the computer is serving.
  bool get isElpianReport => isWeb && reportProgram.trim().isNotEmpty;
  bool get isHtmlReport =>
      isWeb && !isElpianReport && reportHtml.trim().isNotEmpty;

  /// An Elpian app's program in its app (`elpian/app.js`): the window runs
  /// it natively rather than showing a web page ('' for a web page).
  String get elpian => isWeb ? '${args['elpian'] ?? ''}' : '';

  /// The Elpian program its phone widget runs: a web app's own widget
  /// program, else an Elpian app's program ('' for a plain web page).
  String get widget {
    if (!isWeb) return '';
    final own = '${args['widget'] ?? ''}';
    return own.isNotEmpty ? own : elpian;
  }

  /// A workspace file rather than a tool's own frontend.
  bool get isFile => kind == fileKind;

  /// The workspace path a file window shows.
  String get filePath => isFile ? '${args['path'] ?? ''}' : '';

  /// The stored file a file window shows (one shared in a chat or a post),
  /// or '' for a workspace file.
  String get fileId => isFile ? '${args['file_id'] ?? ''}' : '';

  /// The project's computer rather than a tool's own frontend.
  bool get isComputer => kind == computerKind;

  /// An AG-UI generative surface window.
  bool get isAgui => kind == aguiKind || frontend == aguiKind;

  /// The AG-UI surface payload (null when not an AG-UI window).
  Map<String, dynamic>? get aguiSurface {
    if (!isAgui) return null;
    final s = args['surface'];
    if (s is Map<String, dynamic>) return s;
    if (s is Map) return Map<String, dynamic>.from(s);
    final root = args['root'];
    if (root is Map) {
      return {
        'layout': 'desk',
        'title': title,
        'root': Map<String, dynamic>.from(root),
      };
    }
    return null;
  }
  final String name;
  final String title;

  /// static, app, web, …
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

  /// "city: New York · units: metric" (nothing for web, file, or AG-UI).
  String get argsSummary => isWeb || isFile || isAgui
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
  final String name;
  final String title;
  final String frontend;
  final String microtool;
  final Map<String, dynamic> args;
  final Size size;

  /// The look its widget had on the phone board.
  final DeskCompact? compact;

  /// Shown with the tool's own app (MCP Apps).
  bool get isApp => frontend == appFrontend;

  /// A web page (a preview of the space).
  bool get isWeb => kind == webKind;
  String get page => isWeb ? '${args['page'] ?? ''}' : '';
  String get reportHtml => isWeb ? '${args['html'] ?? ''}' : '';
  String get reportProgram => isWeb ? '${args['program'] ?? ''}' : '';
  bool get isElpianReport => isWeb && reportProgram.trim().isNotEmpty;
  bool get isHtmlReport =>
      isWeb && !isElpianReport && reportHtml.trim().isNotEmpty;
  String get elpian => isWeb ? '${args['elpian'] ?? ''}' : '';

  /// A workspace file.
  bool get isFile => kind == fileKind;
  String get filePath => isFile ? '${args['path'] ?? ''}' : '';
  String get fileId => isFile ? '${args['file_id'] ?? ''}' : '';

  /// The project's computer.
  bool get isComputer => kind == computerKind;

  /// An AG-UI generative surface pin.
  bool get isAgui => kind == aguiKind || frontend == aguiKind;

  String get label => title.isNotEmpty ? title : name;

  ShownResult? get shown => microtool.isEmpty && args.isEmpty
      ? null
      : ShownResult(microtool: microtool, args: args);

  String get argsSummary => isWeb || isFile || isAgui
      ? ''
      : args.entries
          .where((e) => e.value is! Map && e.value is! List)
          .map((e) => '${e.key}: ${e.value}')
          .join(' · ');

  /// A window opened from this shortcut, for a surface that shows the pin.
  DeskWindow asWindow({required String id, Rect? rect}) => DeskWindow(
        id: id,
        tool: tool,
        kind: kind,
        name: name,
        title: title,
        frontend: frontend,
        microtool: microtool,
        args: args,
        rect: rect ?? Rect.fromLTWH(0, 0, size.width, size.height),
        compact: compact,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'tool': tool,
        'kind': kind,
        'name': name,
        'title': title,
        'frontend': frontend,
        'microtool': microtool,
        if (args.isNotEmpty) 'args': args,
        'w': size.width,
        'h': size.height,
        if (compact != null) 'compact': compact!.toJson(),
      };
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
