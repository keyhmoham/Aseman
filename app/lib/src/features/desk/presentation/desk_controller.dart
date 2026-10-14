import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

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
      {String title = '',
      String microtool = '',
      Map<String, dynamic> args = const {},
      Rect? rect,
      Size? size}) async {
    final ids = await _send([
      DeskOps.open(tool,
          title: title,
          microtool: microtool,
          args: args,
          rect: rect,
          size: size)
    ]);
    _focusTool = null;
    return ids.isEmpty ? null : ids.first;
  }

  Future<String?> openPin(DeskPin pin) => open(pin.tool,
      title: pin.title,
      microtool: pin.microtool,
      args: pin.args,
      size: pin.size);

  Future<void> move(String id, Rect rect) => _send([DeskOps.move(id, rect)],
      optimistic: _state.copyWith(windows: [
        for (final w in _state.windows) w.id == id ? w.copyWith(rect: rect) : w
      ]));

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

  bool isPinned(DeskWindow w) => _state.pins.any((p) =>
      p.tool == w.tool &&
      p.microtool == w.microtool &&
      mapEquals(p.args, w.args));

  Future<void> togglePin(DeskWindow w) {
    final pin = _state.pins.where((p) =>
        p.tool == w.tool &&
        p.microtool == w.microtool &&
        mapEquals(p.args, w.args));
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
