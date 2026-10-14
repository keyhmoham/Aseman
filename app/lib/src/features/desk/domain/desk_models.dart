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

class DeskWindow {
  const DeskWindow({
    required this.id,
    required this.tool,
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

  /// The tool's bot id.
  final String tool;
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
  final String name;
  final String title;
  final String frontend;
  final String microtool;
  final Map<String, dynamic> args;
  final Size size;

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
