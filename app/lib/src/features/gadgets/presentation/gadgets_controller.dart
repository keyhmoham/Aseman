import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../app_dependencies.dart';
import '../data/gadgets_api.dart';

/// How a gadget is shown on its surface.
enum GadgetMode {
  /// Minimised: off screen, listed in the gadgets manager to bring back.
  docked,

  /// Expanded floating window on the surface.
  open,
}

/// In-memory layout of one floating gadget on the current screen.
class GadgetState {
  const GadgetState({
    this.mode = GadgetMode.docked,
    this.offset = Offset.zero,
    this.size = const Size(200, 240),
  });

  final GadgetMode mode;
  final Offset offset;
  final Size size;

  GadgetState copyWith({
    GadgetMode? mode,
    Offset? offset,
    Size? size,
  }) =>
      GadgetState(
        mode: mode ?? this.mode,
        offset: offset ?? this.offset,
        size: size ?? this.size,
      );
}

/// Loads App UI gadgets and keeps each gadget's open/docked layout for the
/// signed-in person. Account gadgets are universal; space gadgets are filtered
/// by [spaceId] and [GadgetPlacement].
class GadgetsController extends ChangeNotifier {
  GadgetsController(this.dependencies);

  final AppDependencies dependencies;

  late final GadgetsApi _api = GadgetsApi.of(dependencies.service);

  List<GadgetInfo> _gadgets = const [];
  final Map<String, GadgetState> _layout = {};
  Object? error;
  bool loading = false;
  String _spaceId = '';
  Timer? _poll;
  int _epoch = 0;
  bool _disposed = false;

  /// The on-screen surfaces showing a space's gadgets, oldest first: the
  /// newest decides the space (a direct chat floating over a workspace),
  /// and when it goes the one under it takes the controller back.
  final List<GadgetsLease> _leases = [];

  List<GadgetInfo> get gadgets => _gadgets;
  String get spaceId => _spaceId;

  /// Account-scoped gadgets: universal floating gadgets.
  List<GadgetInfo> get universal =>
      [for (final p in _gadgets) if (p.appWide && !p.removed) p];

  /// Every live gadget the person can manage here: their account's universal
  /// gadgets first, then the attached space's (any placement).
  List<GadgetInfo> get manageable => [
        ...universal,
        for (final p in _gadgets)
          if (!p.appWide && !p.removed && p.spaceId == _spaceId) p
      ];

  /// Space-scoped floaters for the attached workspace: every non-page gadget
  /// of the space. They share one layer over left panel, chat and desk —
  /// [GadgetPlacement] only hints default size, not which panel hosts them.
  List<GadgetInfo> get spaceFloaters => [
        for (final p in _gadgets)
          if (!p.appWide &&
              !p.removed &&
              p.spaceId == _spaceId &&
              p.placement != GadgetPlacement.page)
            p
      ];

  /// Space-scoped gadgets for the attached space and [placement].
  List<GadgetInfo> forPlacement(GadgetPlacement placement) => [
        for (final p in _gadgets)
          if (!p.appWide &&
              !p.removed &&
              p.spaceId == _spaceId &&
              p.placement == placement)
            p
      ];

  GadgetState layoutOf(String gadgetId) =>
      _layout[gadgetId] ?? const GadgetState();

  /// Claims the controller for [spaceId] while a surface showing that
  /// space's gadgets is on screen. Surfaces take a lease when they mount and
  /// [GadgetsLease.release] it when they go — never from `build`, where two
  /// surfaces of different spaces would retarget each other every frame.
  GadgetsLease lease(String spaceId) {
    final lease = GadgetsLease._(this, spaceId);
    _leases.add(lease);
    attach(spaceId: spaceId);
    return lease;
  }

  void _release(GadgetsLease lease) {
    final wasCurrent = _leases.isNotEmpty && identical(_leases.last, lease);
    _leases.remove(lease);
    if (_disposed || !wasCurrent) return;
    attach(spaceId: _leases.isEmpty ? '' : _leases.last.spaceId);
  }

  /// Start (or retarget) loading. Empty [spaceId] loads only account gadgets.
  void attach({String spaceId = ''}) {
    if (_disposed) return;
    final changed = spaceId != _spaceId;
    _spaceId = spaceId;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 12), (_) => refresh());
    if (changed || _gadgets.isEmpty) {
      unawaited(refresh(force: true));
    }
  }

  Future<void> refresh({bool force = false}) async {
    final account = dependencies.sessionController.session?.accountId ?? '';
    if (account.isEmpty) {
      if (_gadgets.isNotEmpty) {
        _gadgets = const [];
        _layout.clear();
        notifyListeners();
      }
      return;
    }
    final epoch = ++_epoch;
    if (force) {
      loading = true;
      notifyListeners();
    }
    try {
      final list = await _api.list(spaceId: _spaceId);
      if (_disposed || epoch != _epoch) return;
      error = null;
      _gadgets = list;
      // Drop layout for gadgets that disappeared; keep positions for the rest.
      _layout.removeWhere(
          (id, _) => !list.any((p) => p.id == id && !p.removed));
      for (final p in list.where((p) => !p.removed)) {
        _layout.putIfAbsent(
          p.id,
          () => GadgetState(
            mode: GadgetMode.docked,
            size: _defaultSize(p),
          ),
        );
      }
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      error = e;
    } finally {
      if (!_disposed && epoch == _epoch) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Size _defaultSize(GadgetInfo p) => switch (p.placement) {
        // Compact like mobile home-screen widgets — not desk windows.
        GadgetPlacement.page => const Size(320, 420),
        GadgetPlacement.desk => const Size(220, 260),
        GadgetPlacement.rail => const Size(160, 200),
        GadgetPlacement.chat => const Size(180, 220),
      };

  void setMode(String gadgetId, GadgetMode mode) {
    final cur = layoutOf(gadgetId);
    if (cur.mode == mode) return;
    _layout[gadgetId] = cur.copyWith(mode: mode);
    notifyListeners();
  }

  void open(String gadgetId) => setMode(gadgetId, GadgetMode.open);

  void dock(String gadgetId) => setMode(gadgetId, GadgetMode.docked);

  void toggle(String gadgetId) {
    final mode = layoutOf(gadgetId).mode;
    setMode(
      gadgetId,
      mode == GadgetMode.open
          ? GadgetMode.docked
          : GadgetMode.open,
    );
  }

  void move(String gadgetId, Offset offset) {
    _layout[gadgetId] = layoutOf(gadgetId).copyWith(offset: offset);
    notifyListeners();
  }

  void resize(String gadgetId, Size size) {
    _layout[gadgetId] = layoutOf(gadgetId).copyWith(
      size: Size(
        size.width.clamp(200, 720),
        size.height.clamp(160, 900),
      ),
    );
    notifyListeners();
  }

  Future<void> remove(String gadgetId) async {
    await _api.remove(gadgetId);
    await refresh(force: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _leases.clear();
    super.dispose();
  }
}

/// A surface's claim on the [GadgetsController] for its space
/// ([GadgetsController.lease]).
class GadgetsLease {
  GadgetsLease._(this._controller, this.spaceId);

  final GadgetsController _controller;
  final String spaceId;
  bool _released = false;

  /// Gives the controller back to the surface under this one (once).
  void release() {
    if (_released) return;
    _released = true;
    _controller._release(this);
  }
}

/// Inherited access to the app's [GadgetsController].
class GadgetsScope extends InheritedNotifier<GadgetsController> {
  const GadgetsScope({
    super.key,
    required GadgetsController controller,
    required super.child,
  }) : super(notifier: controller);

  static GadgetsController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<GadgetsScope>()
      ?.notifier;

  static GadgetsController of(BuildContext context) {
    final c = maybeOf(context);
    assert(c != null, 'GadgetsScope missing');
    return c!;
  }
}
