import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../app_dependencies.dart';
import '../data/plugins_api.dart';

/// How a gadget is shown on its surface.
enum PluginGadgetMode {
  /// Chip in the surface dock; tap to expand.
  docked,

  /// Expanded floating window on the surface.
  open,

  /// Hidden until the person opens it from the dock / launcher.
  hidden,
}

/// In-memory layout of one floating gadget on the current screen.
class PluginGadgetState {
  const PluginGadgetState({
    this.mode = PluginGadgetMode.docked,
    this.offset = Offset.zero,
    this.size = const Size(320, 420),
  });

  final PluginGadgetMode mode;
  final Offset offset;
  final Size size;

  PluginGadgetState copyWith({
    PluginGadgetMode? mode,
    Offset? offset,
    Size? size,
  }) =>
      PluginGadgetState(
        mode: mode ?? this.mode,
        offset: offset ?? this.offset,
        size: size ?? this.size,
      );
}

/// Loads Creator plugins and keeps each gadget's open/docked layout for the
/// signed-in person. Account plugins are universal; space plugins are filtered
/// by [spaceId] and [PluginPlacement].
class PluginGadgetsController extends ChangeNotifier {
  PluginGadgetsController(this.dependencies);

  final AppDependencies dependencies;

  late final PluginsApi _api = PluginsApi.of(dependencies.service);

  List<PluginInfo> _plugins = const [];
  final Map<String, PluginGadgetState> _layout = {};
  Object? error;
  bool loading = false;
  String _spaceId = '';
  Timer? _poll;
  int _epoch = 0;

  List<PluginInfo> get plugins => _plugins;
  String get spaceId => _spaceId;

  /// Account-scoped plugins: universal floating gadgets.
  List<PluginInfo> get universal =>
      [for (final p in _plugins) if (p.appWide && !p.removed) p];

  /// Every live plugin the person can manage here: their account's universal
  /// plugins first, then the attached space's (any placement).
  List<PluginInfo> get manageable => [
        ...universal,
        for (final p in _plugins)
          if (!p.appWide && !p.removed && p.spaceId == _spaceId) p
      ];

  /// Space-scoped plugins for the attached space and [placement].
  List<PluginInfo> forPlacement(PluginPlacement placement) => [
        for (final p in _plugins)
          if (!p.appWide &&
              !p.removed &&
              p.spaceId == _spaceId &&
              p.placement == placement)
            p
      ];

  PluginGadgetState layoutOf(String pluginId) =>
      _layout[pluginId] ?? const PluginGadgetState();

  /// Start (or retarget) loading. Empty [spaceId] loads only account plugins.
  void attach({String spaceId = ''}) {
    final changed = spaceId != _spaceId;
    _spaceId = spaceId;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 12), (_) => refresh());
    if (changed || _plugins.isEmpty) {
      unawaited(refresh(force: true));
    }
  }

  Future<void> refresh({bool force = false}) async {
    final account = dependencies.sessionController.session?.accountId ?? '';
    if (account.isEmpty) {
      if (_plugins.isNotEmpty) {
        _plugins = const [];
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
      if (epoch != _epoch) return;
      error = null;
      _plugins = list;
      // Drop layout for plugins that disappeared; keep positions for the rest.
      _layout.removeWhere(
          (id, _) => !list.any((p) => p.id == id && !p.removed));
      for (final p in list.where((p) => !p.removed)) {
        _layout.putIfAbsent(
          p.id,
          () => PluginGadgetState(
            mode: PluginGadgetMode.docked,
            size: _defaultSize(p),
          ),
        );
      }
    } catch (e) {
      if (epoch != _epoch) return;
      error = e;
    } finally {
      if (epoch == _epoch) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Size _defaultSize(PluginInfo p) => switch (p.placement) {
        PluginPlacement.page => const Size(420, 560),
        PluginPlacement.desk => const Size(360, 480),
        PluginPlacement.rail => const Size(260, 340),
        PluginPlacement.chat => const Size(300, 400),
      };

  void setMode(String pluginId, PluginGadgetMode mode) {
    final cur = layoutOf(pluginId);
    if (cur.mode == mode) return;
    _layout[pluginId] = cur.copyWith(mode: mode);
    notifyListeners();
  }

  void open(String pluginId) => setMode(pluginId, PluginGadgetMode.open);

  void dock(String pluginId) => setMode(pluginId, PluginGadgetMode.docked);

  void hide(String pluginId) => setMode(pluginId, PluginGadgetMode.hidden);

  void toggle(String pluginId) {
    final mode = layoutOf(pluginId).mode;
    setMode(
      pluginId,
      mode == PluginGadgetMode.open
          ? PluginGadgetMode.docked
          : PluginGadgetMode.open,
    );
  }

  void move(String pluginId, Offset offset) {
    _layout[pluginId] = layoutOf(pluginId).copyWith(offset: offset);
    notifyListeners();
  }

  void resize(String pluginId, Size size) {
    _layout[pluginId] = layoutOf(pluginId).copyWith(
      size: Size(
        size.width.clamp(200, 720),
        size.height.clamp(160, 900),
      ),
    );
    notifyListeners();
  }

  Future<void> remove(String pluginId) async {
    await _api.remove(pluginId);
    await refresh(force: true);
  }

  Future<void> restore(String pluginId) async {
    await _api.restore(pluginId);
    await refresh(force: true);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

/// Inherited access to the app's [PluginGadgetsController].
class PluginGadgetsScope extends InheritedNotifier<PluginGadgetsController> {
  const PluginGadgetsScope({
    super.key,
    required PluginGadgetsController controller,
    required super.child,
  }) : super(notifier: controller);

  static PluginGadgetsController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PluginGadgetsScope>()
      ?.notifier;

  static PluginGadgetsController of(BuildContext context) {
    final c = maybeOf(context);
    assert(c != null, 'PluginGadgetsScope missing');
    return c!;
  }
}
