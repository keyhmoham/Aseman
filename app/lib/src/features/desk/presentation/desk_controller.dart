import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../data/desk_api.dart';
import '../domain/desk_models.dart';

/// The desk of the room on screen: what the node keeps (windows, pins) kept
/// in step by polling, changed optimistically by the person using it, plus
/// what is only this screen's (the tool shown alone, the pinned desk, a
/// maximized window).
class DeskController extends ChangeNotifier {
  DeskController(this.api, {this.pollEvery = const Duration(seconds: 3)});

  final DeskApi api;
  final Duration pollEvery;

  String _space = '';
  String _room = 'home';
  DeskState _state = DeskState.empty;
  bool _loaded = false;
  Object? error;

  /// The tool whose windows are gathered alone (the others hidden), if any.
  String? _focusTool;

  /// The pinned desk is open over the windows.
  bool _pinnedOpen = false;

  /// A window filling the visible desk for now.
  String? _maximized;

  int _pending = 0;
  int _interacting = 0;
  Timer? _poll;
  Timer? _viewportTimer;
  Size _reported = Size.zero;
  bool _disposed = false;

  DeskState get state => _state;
  bool get loaded => _loaded;
  String get spaceId => _space;
  String get room => _room;
  String? get focusTool =>
      _state.windows.any((w) => w.tool == _focusTool) ? _focusTool : null;
  bool get pinnedOpen => _pinnedOpen;
  String? get maximized =>
      _state.windows.any((w) => w.id == _maximized) ? _maximized : null;

  /// Shows the desk of [room] (a room id, or `home`) in [space].
  void attach(String space, String room) {
    room = room.isEmpty ? 'home' : room;
    if (space == _space && room == _room) return;
    _space = space;
    _room = room;
    _state = DeskState.empty;
    _loaded = false;
    _focusTool = null;
    _pinnedOpen = false;
    _maximized = null;
    _reported = Size.zero;
    _poll?.cancel();
    _notify();
    if (space.isEmpty) return;
    unawaited(refresh(force: true));
    _poll = Timer.periodic(pollEvery, (_) => refresh());
  }

  /// Reads the desk again (what agents and other people changed). Skipped
  /// while this screen is changing it.
  Future<void> refresh({bool force = false}) async {
    if (_space.isEmpty || (!force && (_pending > 0 || _interacting > 0))) {
      return;
    }
    final space = _space, room = _room;
    try {
      final next = await api.get(space, room);
      if (space != _space || room != _room) return;
      if (_pending > 0 || (!force && _interacting > 0)) return;
      final changed = !_loaded || next.version != _state.version;
      _loaded = true;
      error = null;
      if (changed) {
        _state = next;
        _notify();
      }
    } catch (e) {
      if (!_loaded) {
        _loaded = true;
        error = e;
        _notify();
      }
    }
  }

  Future<List<String>> _send(List<Map<String, dynamic>> ops,
      {DeskState? optimistic}) async {
    if (_space.isEmpty) return const [];
    if (optimistic != null) {
      _state = optimistic;
      _notify();
    }
    final space = _space, room = _room;
    _pending++;
    try {
      final (next, ids) = await api.update(space, room, ops);
      if (space == _space && room == _room && _pending == 1) {
        _state = next;
        error = null;
      }
      return ids;
    } catch (e) {
      error = e;
      _pending--;
      await refresh(force: true);
      _pending++;
      return const [];
    } finally {
      _pending--;
      _notify();
    }
  }

  /// A drag or resize is in progress: polls do not move things under the
  /// pointer.
  void beginInteraction() => _interacting++;
  void endInteraction() =>
      _interacting = _interacting > 0 ? _interacting - 1 : 0;

  int get _topZ => _state.windows.fold(0, (z, w) => w.z > z ? w.z : z);

  Future<String?> open(String tool,
      {String kind = '',
      Map<String, dynamic> widget = const {},
      String request = '',
      Map<String, dynamic> template = const {},
      String title = '',
      String microtool = '',
      Map<String, dynamic> args = const {},
      Rect? rect,
      Size? size,
      DeskCompact? compact}) async {
    final ids = await _send([
      DeskOps.open(tool,
          compact: compact,
          kind: kind,
          widget: widget,
          request: request,
          template: template,
          title: title,
          microtool: microtool,
          args: args,
          rect: rect,
          size: size)
    ]);
    _focusTool = null;
    return ids.isEmpty ? null : ids.first;
  }

  /// Opens a web page of the space (a preview gateway path,
  /// /v1/proxy/<id>/…) as a card window; [tool] is the tool it is a
  /// frontend of, if any.
  Future<String?> openPage(String page,
          {String tool = '', String title = '', Size? size}) =>
      open(tool,
          kind: webKind,
          args: {'page': page},
          title: title,
          size: size ?? const Size(720, 600));

  /// Opens a file of the space's workspace (`/workspace/…`) as a card
  /// window, shown with the app's file viewer.
  Future<String?> openFile(String path, {String title = '', Size? size}) =>
      open(fileTool,
          kind: fileKind,
          args: {'path': path},
          title: title.isEmpty ? path.split('/').last : title,
          size: size ?? const Size(680, 620));

  /// Opens the project's computer, its desktop live, as a card window (the
  /// one already open is brought to the front).
  Future<String?> openComputer({Size? size}) => open(computerTool,
      kind: computerKind,
      title: 'Computer',
      size: size ?? const Size(960, 660));

  Future<String?> openPin(DeskPin pin) => open(pin.tool,
      kind: pin.kind,
      widget: pin.widget,
      request: pin.request,
      template: pin.template,
      title: pin.title,
      microtool: pin.microtool,
      args: pin.args,
      size: pin.size,
      compact: pin.compact);

  Future<void> move(String id, Rect rect) => _send([DeskOps.move(id, rect)],
      optimistic: _state.copyWith(windows: [
        for (final w in _state.windows) w.id == id ? w.copyWith(rect: rect) : w
      ]));

  /// Moves window [id] on the phone board to index [order] (and gives it
  /// [shape] / [size]), at once here and then on the node.
  Future<void> arrange(String id, {int? order, String? shape, String? size}) {
    final board = _state.boardOrder;
    final w = board.where((x) => x.id == id).firstOrNull;
    if (w == null) return Future.value();
    final at = (order ?? board.indexOf(w)).clamp(0, board.length - 1);
    final next = [...board]
      ..remove(w)
      ..insert(at, w);
    final arranged = {
      for (var i = 0; i < next.length; i++)
        next[i].id: (next[i].compact ?? const DeskCompact()).copyWith(
            order: i,
            shape: next[i].id == id ? shape : null,
            size: next[i].id == id ? size : null),
    };
    return _send([DeskOps.arrange(id, order: at, shape: shape, size: size)],
        optimistic: _state.copyWith(windows: [
          for (final x in _state.windows) x.copyWith(compact: arranged[x.id])
        ]));
  }

  /// Brings a window to the front.
  Future<void> raise(String id) async {
    final top = _topZ;
    final w = _state.windows.where((w) => w.id == id).firstOrNull;
    if (w == null ||
        (w.z == top && _state.windows.where((x) => x.z == top).length == 1)) {
      return;
    }
    await _send([DeskOps.focus(id)],
        optimistic: _state.copyWith(windows: [
          for (final x in _state.windows)
            x.id == id ? x.copyWith(z: top + 1) : x
        ]));
  }

  /// Designs a designed window again (after it failed, or to start over).
  Future<void> redesign(String id) => _send([DeskOps.redesign(id)]);

  Future<void> close(String id) {
    if (_maximized == id) _maximized = null;
    return _send([DeskOps.close(id)],
        optimistic: _state.copyWith(
            windows: _state.windows.where((w) => w.id != id).toList()));
  }

  /// Closes every window of [tool] (the dock's close).
  Future<void> closeTool(String tool) {
    if (_focusTool == tool) _focusTool = null;
    return _send([DeskOps.closeTool(tool)],
        optimistic: _state.copyWith(
            windows: _state.windows.where((w) => w.tool != tool).toList()));
  }

  /// The pin keeping [w] (a composed widget is kept by its title).
  bool _pins(DeskPin p, DeskWindow w) => w.isComposed
      ? p.isComposed && p.title.toLowerCase() == w.title.toLowerCase()
      : !p.isComposed &&
          p.tool == w.tool &&
          p.microtool == w.microtool &&
          mapEquals(p.args, w.args);

  bool isPinned(DeskWindow w) => _state.pins.any((p) => _pins(p, w));

  Future<void> togglePin(DeskWindow w) {
    final pin = _state.pins.where((p) => _pins(p, w));
    if (pin.isNotEmpty) return unpin(pin.first.id);
    return _send([DeskOps.pin(w.id)]);
  }

  Future<void> unpin(String pinId) => _send([DeskOps.unpin(pinId)],
      optimistic: _state.copyWith(
          pins: _state.pins.where((p) => p.id != pinId).toList()));

  /// Shows only [tool]'s windows, gathered; the same tool again (or null)
  /// shows every window where it was.
  void focusOn(String? tool) {
    _focusTool = tool == null || tool == _focusTool ? null : tool;
    _pinnedOpen = false;
    _maximized = null;
    _notify();
  }

  void setPinnedOpen(bool open) {
    _pinnedOpen = open;
    _notify();
  }

  void toggleMaximized(String id) {
    _maximized = _maximized == id ? null : id;
    _notify();
  }

  /// The size of the desk on this screen, for agents to place windows in
  /// (sent when it settles).
  void reportViewport(Size size) {
    if (_space.isEmpty || size.width < 200 || size.height < 200) return;
    if ((size.width - _reported.width).abs() < 8 &&
        (size.height - _reported.height).abs() < 8) {
      return;
    }
    _viewportTimer?.cancel();
    _viewportTimer = Timer(const Duration(milliseconds: 700), () {
      _reported = size;
      unawaited(api.update(_space, _room, [DeskOps.viewport(size)]).then((_) {},
          onError: (_) {}));
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _viewportTimer?.cancel();
    super.dispose();
  }
}

/// The desk of the room on screen, for widgets around it (the chat opens
/// pages agents share on it).
class DeskScope extends InheritedWidget {
  const DeskScope({super.key, required this.controller, required super.child});

  final DeskController controller;

  static DeskController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeskScope>()?.controller;

  @override
  bool updateShouldNotify(DeskScope old) => old.controller != controller;
}
