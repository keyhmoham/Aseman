import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import '../../../core/theme/app_shape.dart';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../data/models/space.dart';
import '../../../elpian/core/media.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../desk/data/desk_api.dart';
import '../../desk/domain/desk_models.dart';
import '../../desk/presentation/card_window.dart';
import '../../desk/presentation/compact_desk.dart';
import '../../desk/presentation/frontend_presentation.dart';
import '../../desk/presentation/tool_avatar.dart';
import '../../home/presentation/desk_surface_entry.dart';
import '../../tools/runtime/tool_media.dart';

/// A pinned window from one room, as the feed's toolbox lists it.
class FeedPinSource {
  const FeedPinSource({
    required this.spaceId,
    required this.spaceName,
    required this.roomId,
    required this.roomName,
    required this.pin,
  });

  final String spaceId;
  final String spaceName;
  final String roomId;
  final String roomName;
  final DeskPin pin;

  String get key => '$spaceId/$roomId/${pin.id}';
  String get label => pin.label.isEmpty ? 'Window' : pin.label;
}

/// One pinned window the person placed on the feed's center desk.
class FeedPlacement {
  const FeedPlacement({
    required this.id,
    required this.spaceId,
    required this.spaceName,
    required this.roomId,
    required this.roomName,
    required this.pin,
    required this.rect,
    this.z = 0,
    this.widgetMode = false,
    this.minimized = false,
  });

  final String id;
  final String spaceId;
  final String spaceName;
  final String roomId;
  final String roomName;
  final DeskPin pin;
  final Rect rect;
  final int z;

  /// Compact widget, rather than a card window. Phones always draw the
  /// widget; this is what a wide screen restores.
  final bool widgetMode;
  final bool minimized;

  String get sourceKey => '$spaceId/$roomId/${pin.id}';
  String get label => pin.label.isEmpty ? 'Window' : pin.label;
  DeskWindow get window => pin.asWindow(id: id, rect: rect);

  static FeedPlacement? tryParse(Map<String, dynamic> json) {
    final raw = json['pin'];
    final id = '${json['id'] ?? ''}';
    if (raw is! Map || id.isEmpty) return null;
    return FeedPlacement(
      id: id,
      spaceId: '${json['spaceId'] ?? ''}',
      spaceName: '${json['spaceName'] ?? ''}',
      roomId: '${json['roomId'] ?? 'home'}',
      roomName: '${json['roomName'] ?? ''}',
      pin: DeskPin.fromJson(raw.cast<String, dynamic>()),
      rect: Rect.fromLTWH(
        (json['x'] as num?)?.toDouble() ?? 24,
        (json['y'] as num?)?.toDouble() ?? 24,
        (json['w'] as num?)?.toDouble() ?? DeskGeometry.defaultW,
        (json['h'] as num?)?.toDouble() ?? DeskGeometry.defaultH,
      ),
      z: (json['z'] as num?)?.toInt() ?? 0,
      widgetMode: json['widget'] == true,
      minimized: json['minimized'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'spaceId': spaceId,
    'spaceName': spaceName,
    'roomId': roomId,
    'roomName': roomName,
    'pin': pin.toJson(),
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'z': z,
    'widget': widgetMode,
    'minimized': minimized,
  };

  FeedPlacement copyWith({
    String? spaceName,
    String? roomName,
    DeskPin? pin,
    Rect? rect,
    int? z,
    bool? widgetMode,
    bool? minimized,
  }) => FeedPlacement(
    id: id,
    spaceId: spaceId,
    spaceName: spaceName ?? this.spaceName,
    roomId: roomId,
    roomName: roomName ?? this.roomName,
    pin: pin ?? this.pin,
    rect: rect ?? this.rect,
    z: z ?? this.z,
    widgetMode: widgetMode ?? this.widgetMode,
    minimized: minimized ?? this.minimized,
  );
}

/// How big a pin's compact widget is on the free desk.
Size feedWidgetSize(DeskPin pin) {
  final shape = pin.compact?.shape ?? '';
  final size = pin.compact?.size ?? '';
  if (shape == 'circle' || size == 'small') return const Size(168, 168);
  if (size == 'large') return const Size(320, 280);
  return const Size(280, 180);
}

/// Placements on the feed desk, and the catalog of pins behind the toolbox.
class FeedCanvasController extends ChangeNotifier {
  FeedCanvasController({required this.dependencies}) {
    unawaited(_restore());
  }

  final AppDependencies dependencies;

  List<FeedPlacement> placements = const [];
  List<Workspace> spaces = const [];
  List<FeedPinSource> pins = const [];
  bool toolboxOpen = false;
  bool pinsLoading = false;
  String? error;

  /// The window filling the desk right now (wide screens only).
  String? maximized;

  bool _disposed = false;
  int _seq = 0;
  int _catalogGen = 0;
  bool _saveQueued = false;
  int _revision = 0;

  /// Where the desk lives on the signed-in account (`users.metadata_patch`).
  static const deskPath = 'profile/feed_desk';

  String get _prefsKey {
    final id = dependencies.sessionController.session?.accountId ?? '';
    return 'aseman.feed.canvas.$id';
  }

  int get _topZ => placements.fold(0, (top, p) => math.max(top, p.z));

  String? get frontId {
    FeedPlacement? front;
    for (final p in placements) {
      if (p.minimized) continue;
      if (front == null || p.z >= front.z) front = p;
    }
    return front?.id;
  }

  bool isPlaced(FeedPinSource source) =>
      placements.any((p) => p.sourceKey == source.key);

  void setToolboxOpen(bool open) {
    if (toolboxOpen == open) {
      if (open) unawaited(refreshCatalog());
      return;
    }
    toolboxOpen = open;
    _notify();
    if (open) unawaited(refreshCatalog());
  }

  /// Every space, then the pinned windows of its hall and its rooms.
  Future<void> refreshCatalog() async {
    final gen = ++_catalogGen;
    pinsLoading = true;
    error = null;
    _notify();
    try {
      final listed = await dependencies.service.fetchSpaces();
      if (gen != _catalogGen || _disposed) return;
      spaces = listed;
      _notify();
      final found = await Future.wait(listed.map(_pinsOf));
      if (gen != _catalogGen || _disposed) return;
      pins = [for (final list in found) ...list];
      _adoptPins();
    } catch (_) {
      if (gen != _catalogGen || _disposed) return;
      error = 'Could not load spaces';
    } finally {
      if (gen == _catalogGen && !_disposed) {
        pinsLoading = false;
        _notify();
      }
    }
  }

  Future<List<FeedPinSource>> _pinsOf(Workspace space) async {
    final rooms = <(String, String)>[('home', 'Hall room')];
    try {
      final listed = await dependencies.service.fetchRoomsForSpace(space.id);
      for (final room in listed) {
        if (room.id.isEmpty) continue;
        rooms.add((room.id, room.name.isEmpty ? 'Room' : room.name));
      }
    } catch (_) {}
    final api = DeskApi.of(dependencies.service);
    final out = <FeedPinSource>[];
    await Future.wait(
      rooms.map((room) async {
        try {
          final desk = await api.get(
            space.id,
            room.$1,
            timeout: const Duration(milliseconds: 1200),
          );
          for (final pin in desk.pins) {
            if (pin.id.isEmpty) continue;
            out.add(
              FeedPinSource(
                spaceId: space.id,
                spaceName: space.name,
                roomId: room.$1,
                roomName: room.$2,
                pin: pin,
              ),
            );
          }
        } catch (_) {}
      }),
    );
    return out;
  }

  void _adoptPins() {
    if (placements.isEmpty) return;
    final byKey = {for (final pin in pins) pin.key: pin};
    placements = [
      for (final placed in placements)
        if (byKey[placed.sourceKey] case final source?)
          placed.copyWith(
            pin: source.pin,
            spaceName: source.spaceName,
            roomName: source.roomName,
          )
        else
          placed,
    ];
    _scheduleSave();
  }

  /// Puts [source] on the desk. A second time brings the one already there
  /// back to the front. [asWidget] is the phone's default.
  void place(
    FeedPinSource source, {
    required Size canvas,
    required bool asWidget,
  }) {
    final existing = placements
        .where((p) => p.sourceKey == source.key)
        .firstOrNull;
    if (existing != null) {
      if (maximized != null && maximized != existing.id) maximized = null;
      _replace(
        existing.id,
        (p) => p.copyWith(
          minimized: false,
          z: _topZ + 1,
          pin: source.pin,
          spaceName: source.spaceName,
          roomName: source.roomName,
        ),
      );
      return;
    }
    final want = asWidget ? feedWidgetSize(source.pin) : source.pin.size;
    placements = [
      ...placements,
      FeedPlacement(
        id: 'feed-${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
        spaceId: source.spaceId,
        spaceName: source.spaceName,
        roomId: source.roomId,
        roomName: source.roomName,
        pin: source.pin,
        rect: _initialRect(canvas, want, placements.length, widget: asWidget),
        z: _topZ + 1,
        widgetMode: asWidget,
      ),
    ];
    _scheduleSave();
    _notify();
  }

  void remove(String id) {
    if (maximized == id) maximized = null;
    placements = placements.where((p) => p.id != id).toList();
    _scheduleSave();
    _notify();
  }

  void minimize(String id) {
    if (maximized == id) maximized = null;
    _replace(id, (p) => p.copyWith(minimized: true));
  }

  void raise(String id) =>
      _replace(id, (p) => p.copyWith(z: _topZ + 1, minimized: false));

  /// Brings a minimized window back, or minimizes the one already in front.
  void taskbarTap(String id) {
    final placed = placements.where((p) => p.id == id).firstOrNull;
    if (placed == null) return;
    if (placed.minimized || frontId != id) {
      if (maximized != null && maximized != id) maximized = null;
      _replace(id, (p) => p.copyWith(minimized: false, z: _topZ + 1));
    } else {
      minimize(id);
    }
  }

  void toggleWidgetMode(String id, {required Size canvas}) {
    final placed = placements.where((p) => p.id == id).firstOrNull;
    if (placed == null) return;
    if (maximized == id) maximized = null;
    final next = !placed.widgetMode;
    final size = _fit(
      next ? feedWidgetSize(placed.pin) : placed.pin.size,
      canvas,
      widget: next,
    );
    _replace(
      id,
      (p) => p.copyWith(
        widgetMode: next,
        minimized: false,
        z: _topZ + 1,
        rect: Rect.fromLTWH(p.rect.left, p.rect.top, size.width, size.height),
      ),
    );
  }

  void toggleMaximize(String id, {required Size canvas}) {
    final placed = placements.where((p) => p.id == id).firstOrNull;
    if (placed == null) return;
    if (maximized == id) {
      maximized = null;
      _notify();
      return;
    }
    maximized = id;
    if (placed.widgetMode) {
      final size = _fit(placed.pin.size, canvas, widget: false);
      _replace(
        id,
        (p) => p.copyWith(
          widgetMode: false,
          minimized: false,
          z: _topZ + 1,
          rect: Rect.fromLTWH(p.rect.left, p.rect.top, size.width, size.height),
        ),
      );
      return;
    }
    _replace(id, (p) => p.copyWith(minimized: false, z: _topZ + 1));
  }

  void move(String id, Rect rect) => _replace(
    id,
    (p) => p.copyWith(
      rect: Rect.fromLTWH(
        rect.left.roundToDouble(),
        rect.top.roundToDouble(),
        rect.width.roundToDouble(),
        rect.height.roundToDouble(),
      ),
    ),
  );

  void _replace(String id, FeedPlacement Function(FeedPlacement) update) {
    final index = placements.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final next = [...placements];
    next[index] = update(next[index]);
    placements = next;
    _scheduleSave();
    _notify();
  }

  Map<String, dynamic> get _payload => {
    'placements': [for (final p in placements) p.toJson()],
  };

  void _scheduleSave() {
    _revision++;
    if (_saveQueued || _disposed) return;
    _saveQueued = true;
    scheduleMicrotask(() {
      if (!_saveQueued) return;
      _saveQueued = false;
      unawaited(_save());
    });
  }

  /// The account's desk, or null when this account has never stored one.
  static List<FeedPlacement>? placementsFromTree(Map<String, dynamic> tree) {
    final profile = tree['profile'];
    if (profile is! Map || !profile.containsKey('feed_desk')) return null;
    final desk = profile['feed_desk'];
    final list = desk is Map ? desk['placements'] : null;
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map)
          if (FeedPlacement.tryParse(item.cast<String, dynamic>())
              case final placed?)
            placed,
    ];
  }

  Future<void> _restore() async {
    List<FeedPlacement>? remote;
    var serverOk = false;
    try {
      final tree = await dependencies.service.fetchMyMetadata();
      serverOk = true;
      remote = placementsFromTree(tree);
    } catch (_) {}
    if (_disposed || placements.isNotEmpty) return;
    if (serverOk && remote != null) {
      placements = remote;
      _notify();
      unawaited(_writeLocal(_revision));
      return;
    }
    final local = await _readLocal();
    if (_disposed || placements.isNotEmpty || local == null) return;
    placements = local;
    _notify();
    // This device had a desk before it was stored on the account.
    if (serverOk) _scheduleSave();
  }

  Future<List<FeedPlacement>?> _readLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw);
      final list = json is Map ? json['placements'] : null;
      if (list is! List) return null;
      return placementsFromTree({
        'profile': {
          'feed_desk': {'placements': list},
        },
      });
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLocal(int revision) async {
    final payload = _payload;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (revision != _revision) return;
      await prefs.setString(_prefsKey, jsonEncode(payload));
    } catch (_) {}
  }

  Future<void> _save() async {
    final revision = _revision;
    final payload = _payload;
    await _writeLocal(revision);
    if (revision != _revision) return;
    try {
      await dependencies.service.updateMetadata([
        {'op': 'set', 'path': deskPath, 'value': payload},
      ]);
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    final queued = _saveQueued;
    _saveQueued = false;
    if (queued) unawaited(_save());
    _disposed = true;
    super.dispose();
  }
}

Size _fit(Size want, Size canvas, {required bool widget}) {
  if (canvas.width < 32 || canvas.height < 32) return want;
  final maxW = math.max(widget ? 120.0 : 160.0, canvas.width - 24);
  final maxH = math.max(widget ? 100.0 : 140.0, canvas.height - 24);
  final minW = math.min(widget ? 140.0 : DeskGeometry.minW, maxW);
  final minH = math.min(widget ? 120.0 : DeskGeometry.minH, maxH);
  return Size(
    want.width.clamp(minW, maxW).toDouble(),
    want.height.clamp(minH, maxH).toDouble(),
  );
}

Rect _initialRect(Size canvas, Size want, int index, {required bool widget}) {
  final size = _fit(want, canvas, widget: widget);
  if (canvas.width < 32 || canvas.height < 32) {
    return Rect.fromLTWH(24, 24, size.width, size.height);
  }
  final left = (20.0 + (index % 5) * 26)
      .clamp(0.0, math.max(0.0, canvas.width - size.width))
      .toDouble();
  final top = (16.0 + (index % 5) * 22)
      .clamp(0.0, math.max(0.0, canvas.height - size.height))
      .toDouble();
  return Rect.fromLTWH(left, top, size.width, size.height);
}

Rect _clampRect(Rect rect, Size bounds) {
  if (bounds.isEmpty) return rect;
  final maxLeft = math.max(
    0.0,
    bounds.width - math.min(rect.width, bounds.width),
  );
  final maxTop = math.max(
    0.0,
    bounds.height - math.min(rect.height, bounds.height),
  );
  return Rect.fromLTWH(
    rect.left.clamp(0.0, maxLeft).toDouble(),
    rect.top.clamp(0.0, maxTop).toDouble(),
    rect.width,
    rect.height,
  );
}

/// The feed's center: pinned windows from every space, free on the desk,
/// with a taskbar whose left edge opens the toolbox.
class FeedCanvas extends StatefulWidget {
  const FeedCanvas({
    super.key,
    required this.controller,
    required this.dependencies,
    required this.onOpenSpace,
    this.mobile = false,
    this.bottomInset = 0,
  });

  final FeedCanvasController controller;
  final AppDependencies dependencies;
  final ValueChanged<String> onOpenSpace;

  /// Phones draw every placement as a compact widget. Tapping one opens
  /// its window in a sheet. Window mode, maximize and the swap stay off.
  final bool mobile;

  /// Space under the taskbar (the floating home nav on a phone).
  final double bottomInset;

  @override
  State<FeedCanvas> createState() => _FeedCanvasState();
}

class _FeedCanvasState extends State<FeedCanvas> {
  static const _barSlot = 76.0;

  /// Dim behind the toolbox. Lighter than [AppSurfaces.barrierOf(context)] so the desk
  /// still reads through the glass panel.
  static const _toolboxScrim = Color(0x47000000);

  final _search = TextEditingController();
  final _toolboxPortal = OverlayPortalController();
  final Map<String, Rect> _live = {};
  final Map<String, ElpianMediaResolver> _media = {};
  Size _area = Size.zero;

  ElpianMediaResolver _mediaOf(String spaceId) => _media.putIfAbsent(
    spaceId,
    () => ToolMedia.forSpace(widget.dependencies.service, spaceId).call,
  );

  FeedCanvasController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _search.addListener(_changed);
  }

  @override
  void didUpdateWidget(FeedCanvas old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _syncToolboxOverlay();
    setState(() {});
  }

  /// The desk is only the center column. The scrim has to live on the route
  /// overlay so it covers the rails, the app bar and the taskbar too.
  void _syncToolboxOverlay() {
    if (c.toolboxOpen) {
      if (!_toolboxPortal.isShowing) _toolboxPortal.show();
    } else if (_toolboxPortal.isShowing) {
      _toolboxPortal.hide();
    }
  }

  bool _asWidget(FeedPlacement placed) => widget.mobile || placed.widgetMode;

  Rect _shown(FeedPlacement placed) {
    final live = _live[placed.id];
    if (live != null) return live;
    if (c.maximized == placed.id && !widget.mobile) {
      return Rect.fromLTWH(
        8,
        8,
        math.max(120, _area.width - 16),
        math.max(120, _area.height - 16),
      );
    }
    if (_asWidget(placed)) {
      final size = _fit(feedWidgetSize(placed.pin), _area, widget: true);
      return Rect.fromLTWH(
        placed.rect.left,
        placed.rect.top,
        size.width,
        size.height,
      );
    }
    return placed.rect;
  }

  void _drag(FeedPlacement placed, Offset delta) {
    final current = _live[placed.id] ?? _shown(placed);
    setState(() {
      _live[placed.id] = _clampRect(current.shift(delta), _area);
    });
  }

  void _resize(FeedPlacement placed, Offset delta) {
    final current = _live[placed.id] ?? _shown(placed);
    final maxW = math.max(160.0, _area.width - current.left);
    final maxH = math.max(140.0, _area.height - current.top);
    setState(() {
      _live[placed.id] = Rect.fromLTWH(
        current.left,
        current.top,
        (current.width + delta.dx).clamp(
          math.min(DeskGeometry.minW, maxW),
          maxW,
        ),
        (current.height + delta.dy).clamp(
          math.min(DeskGeometry.minH, maxH),
          maxH,
        ),
      );
    });
  }

  void _commit(FeedPlacement placed) {
    final live = _live.remove(placed.id);
    if (live == null) return;
    final stored = _asWidget(placed) && !placed.widgetMode
        ? Rect.fromLTWH(
            live.left,
            live.top,
            placed.rect.width,
            placed.rect.height,
          )
        : live;
    c.move(placed.id, stored);
  }

  Future<void> _openSheet(FeedPlacement placed) {
    return showAppSheet<void>(
      context,
      ElpianMediaScope(
        resolver: _mediaOf(placed.spaceId),
        child: _FeedWindowSheet(
          placement: placed,
          onMinimize: () => c.minimize(placed.id),
          onRemove: () => c.remove(placed.id),
          child: _surface(placed, FrontendDisplay.sheet),
        ),
      ),
      heightFactor: .9,
    );
  }

  /// A sheet on phones, a floating panel on desktop.
  Future<void> _widgetActions(FeedPlacement placed) {
    return showAppPicker<void>(
      context: context,
      maxWidth: 360,
      isScrollControlled: true,
      builder: (_) => _WidgetActions(
        placement: placed,
        mobile: widget.mobile,
        onWindow: () => c.toggleWidgetMode(placed.id, canvas: _area),
        onMaximize: () => c.toggleMaximize(placed.id, canvas: _area),
        onMinimize: () => c.minimize(placed.id),
        onRemove: () => c.remove(placed.id),
      ),
    );
  }

  Widget _surface(FeedPlacement placed, FrontendDisplay display) {
    final compact = placed.pin.compact;
    final shape = compact != null && compact.shape.isNotEmpty
        ? compact.shape
        : 'card';
    final size = compact != null && compact.size.isNotEmpty
        ? compact.size
        : 'medium';
    return ElpianMediaScope(
      resolver: _mediaOf(placed.spaceId),
      child: FrontendPresentation(
        display: display,
        shape: shape,
        size: size,
        title: placed.label,
        accent: ToolAvatar.schemeFor(
          placed.pin.tool,
          Theme.of(context).brightness,
        ).primary,
        onExpand: () => widget.mobile
            ? _openSheet(placed)
            : c.toggleWidgetMode(placed.id, canvas: _area),
        child: DeskSurfaceContent(
          dependencies: widget.dependencies,
          spaceId: placed.spaceId,
          roomId: placed.roomId,
          window: placed.window,
        ),
      ),
    );
  }

  Widget _toolboxPanel() => _Toolbox(
    controller: c,
    search: _search,
    mobile: widget.mobile,
    onOpenSpace: (name) {
      c.setToolboxOpen(false);
      widget.onOpenSpace(name);
    },
    onPlace: (source) =>
        c.place(source, canvas: _area, asWidget: widget.mobile),
    onShow: (source) => c.place(source, canvas: _area, asWidget: widget.mobile),
  );

  Widget _toolboxOverlay(BuildContext context, OverlayChildLayoutInfo info) {
    final scheme = Theme.of(context).colorScheme;
    // Column-major translation: where the desk's top-left sits in the overlay.
    final storage = info.childPaintTransform.storage;
    final left = storage[12];
    final top = storage[13];
    final panelHeight = math.max(
      0.0,
      info.childSize.height - widget.bottomInset - _barSlot,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: ModalBarrier(
            color: _toolboxScrim,
            dismissible: true,
            onDismiss: () => c.setToolboxOpen(false),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: info.childSize.width,
          height: panelHeight,
          child: _toolboxPanel(),
        ),
        if (c.error != null && c.spaces.isEmpty)
          Positioned(
            left: left,
            top: top + 8,
            width: info.childSize.width,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Chip(
                  avatar: Icon(
                    Icons.cloud_off_rounded,
                    size: 16,
                    color: scheme.error,
                  ),
                  label: Text(c.error!),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final placed in c.placements)
        if (!placed.minimized) placed,
    ]..sort((a, b) => a.z.compareTo(b.z));
    final windowsBottom = widget.bottomInset + _barSlot;
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _toolboxPortal,
      overlayChildBuilder: _toolboxOverlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            bottom: windowsBottom,
            child: LayoutBuilder(
              builder: (context, box) {
                _area = Size(box.maxWidth, box.maxHeight);
                return ClipRect(
                  child: Stack(
                    children: [
                      if (c.placements.isEmpty)
                        _EmptyDesk(onOpen: () => c.setToolboxOpen(true)),
                      for (final placed in visible)
                        if (widget.mobile ||
                            (_asWidget(placed) && c.maximized != placed.id))
                          _widget(placed)
                        else
                          _window(placed),
                    ],
                  ),
                );
              },
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: widget.bottomInset + 8,
            child: Center(
              child: _Taskbar(
                controller: c,
                compact: widget.mobile,
                onMenu: _taskbarMenu,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _window(FeedPlacement placed) {
    final rect = _shown(placed);
    final live = _live.containsKey(placed.id);
    final maxed = c.maximized == placed.id && !widget.mobile;
    final front = c.frontId == placed.id;
    return AnimatedPositioned(
      key: ValueKey(placed.id),
      duration: live ? Duration.zero : const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: CardWindow(
        window: placed.window,
        front: front,
        maximized: maxed,
        movable: !maxed,
        showPin: false,
        closeTooltip: 'Remove',
        onRaise: () => c.raise(placed.id),
        onDragStart: () {
          c.raise(placed.id);
          setState(() => _live[placed.id] = rect);
        },
        onDrag: (delta) => _drag(placed, delta),
        onDragEnd: () => _commit(placed),
        onResize: (delta) => _resize(placed, delta),
        onResizeEnd: () => _commit(placed),
        onSwapCompact: () => c.toggleWidgetMode(placed.id, canvas: _area),
        onMinimize: () => c.minimize(placed.id),
        onMaximize: () => c.toggleMaximize(placed.id, canvas: _area),
        onClose: () => c.remove(placed.id),
        child: _surface(placed, FrontendDisplay.full),
      ),
    );
  }

  Widget _widget(FeedPlacement placed) {
    final rect = _shown(placed);
    final live = _live.containsKey(placed.id);
    final compact = placed.pin.compact;
    final shape = compact != null && compact.shape.isNotEmpty
        ? compact.shape
        : 'card';
    final size = compact != null && compact.size.isNotEmpty
        ? compact.size
        : 'medium';
    return AnimatedPositioned(
      key: ValueKey('widget-${placed.id}'),
      duration: live ? Duration.zero : const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        onTap: widget.mobile ? () => _openSheet(placed) : null,
        onPanStart: (_) {
          c.raise(placed.id);
          setState(() => _live[placed.id] = rect);
        },
        onPanUpdate: (d) => _drag(placed, d.delta),
        onPanEnd: (_) => _commit(placed),
        child: CompactWidgetTile(
          window: placed.window,
          shape: shape,
          size: size,
          lifted: live,
          onMenu: () => _widgetActions(placed),
          child: _surface(placed, FrontendDisplay.compact),
        ),
      ),
    );
  }

  /// A sheet on phones, a floating panel on desktop.
  Future<void> _taskbarMenu(FeedPlacement placed) {
    return showAppPicker<void>(
      context: context,
      maxWidth: 320,
      isScrollControlled: true,
      builder: (_) => _TaskbarActions(
        placement: placed,
        onToggle: () => c.taskbarTap(placed.id),
        onRemove: () => c.remove(placed.id),
      ),
    );
  }
}

class _TaskbarActions extends StatelessWidget {
  const _TaskbarActions({
    required this.placement,
    required this.onToggle,
    required this.onRemove,
  });

  final FeedPlacement placement;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    void act(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              placement.minimized
                  ? Icons.open_in_browser_rounded
                  : Icons.minimize_rounded,
            ),
            title: Text(placement.minimized ? 'Restore' : 'Minimize'),
            onTap: () => act(onToggle),
          ),
          ListTile(
            leading: const Icon(Icons.close_rounded),
            title: const Text('Remove'),
            onTap: () => act(onRemove),
          ),
        ],
      ),
    );
  }
}

class _EmptyDesk extends StatelessWidget {
  const _EmptyDesk({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PanelEmpty(
                icon: Icons.widgets_outlined,
                title: 'Your desk',
                message:
                    'Open the toolbox and place a pinned window from any space. Drag it anywhere on this desk.',
              ),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: onOpen,
                icon: const Icon(Icons.handyman_rounded, size: 18),
                label: const Text('Toolbox'),
              ),
            ],
          ),
        ),
      );
}

class _Taskbar extends StatelessWidget {
  const _Taskbar({
    required this.controller,
    required this.onMenu,
    this.compact = false,
  });

  final FeedCanvasController controller;
  final ValueChanged<FeedPlacement> onMenu;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = compact ? 42.0 : 48.0;
    final placed = controller.placements;
    return GlassSurface(
      alpha: AppSurfaces.overlayAlphaOf(context),
      blur: AppSurfaces.blurSigmaOf(context),
      borderRadius: BorderRadius.circular(40),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
          vertical: 8,
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BarButton(
                size: item,
                icon: Icons.handyman_rounded,
                tooltip: 'Toolbox',
                badge: controller.pins.length,
                selected: controller.toolboxOpen,
                onTap: () => controller.setToolboxOpen(!controller.toolboxOpen),
              ),
              Container(
                width: 1,
                height: item * .7,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                color: scheme.outlineVariant,
              ),
              if (placed.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Placed windows show up here',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final itemPlaced in placed)
                _BarItem(
                  key: ValueKey('bar-${itemPlaced.id}'),
                  placement: itemPlaced,
                  size: item,
                  selected:
                      controller.frontId == itemPlaced.id &&
                      !itemPlaced.minimized,
                  onTap: () => controller.taskbarTap(itemPlaced.id),
                  onRemove: () => controller.remove(itemPlaced.id),
                  onMenu: () => onMenu(itemPlaced),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.size,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge = 0,
    this.selected = false,
  });

  final double size;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badge;
  final bool selected;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.size;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _hover ? 1.12 : 1,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutBack,
            child: Badge(
              isLabelVisible: widget.badge > 0,
              label: Text('${widget.badge}'),
              backgroundColor: scheme.tertiary,
              textColor: scheme.onTertiary,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                width: s,
                height: s,
                decoration: BoxDecoration(
                  color: widget.selected
                      ? scheme.primary
                      : ThemeRoles.wellFill(context),
                  borderRadius: BorderRadius.circular(
                    widget.selected ? s * .3 : s / 2,
                  ),
                ),
                child: Icon(
                  widget.icon,
                  size: s * .5,
                  color: widget.selected
                      ? scheme.onPrimary
                      : ThemeRoles.wellInk(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BarItem extends StatefulWidget {
  const _BarItem({
    super.key,
    required this.placement,
    required this.size,
    required this.selected,
    required this.onTap,
    required this.onRemove,
    required this.onMenu,
  });

  final FeedPlacement placement;
  final double size;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onMenu;

  @override
  State<_BarItem> createState() => _BarItemState();
}

class _BarItemState extends State<_BarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placed = widget.placement;
    final where = placed.roomId == 'home'
        ? placed.spaceName
        : '${placed.spaceName} · ${placed.roomName}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: '${placed.label} · $where',
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onMenu,
            onSecondaryTap: widget.onMenu,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: placed.minimized && !_hover ? .5 : 1,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedScale(
                    scale: _hover ? 1.12 : 1,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutBack,
                    child: ToolAvatar(
                      tool: placed.pin.tool,
                      name: placed.pin.name,
                      size: widget.size,
                      selected: widget.selected,
                    ),
                  ),
                  Positioned(
                    top: -4,
                    right: -4,
                    child: AnimatedScale(
                      scale: _hover ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutBack,
                      child: Material(
                        color: scheme.inverseSurface,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: widget.onRemove,
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.close_rounded,
                              size: 13,
                              color: scheme.onInverseSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Toolbox extends StatelessWidget {
  const _Toolbox({
    required this.controller,
    required this.search,
    required this.mobile,
    required this.onOpenSpace,
    required this.onPlace,
    required this.onShow,
  });

  final FeedCanvasController controller;
  final TextEditingController search;
  final bool mobile;
  final ValueChanged<String> onOpenSpace;
  final ValueChanged<FeedPinSource> onPlace;
  final ValueChanged<FeedPinSource> onShow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = search.text.trim().toLowerCase();
    final shelves = _shelves(query);
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.min(560.0, math.max(0.0, box.maxWidth - 24));
        final height = math.max(0.0, box.maxHeight - 16);
        return Center(
          child: GestureDetector(
            onTap: () {},
            child: SizedBox(
              width: width,
              height: height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: AppShape.borderRadius(context, 28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .22),
                      blurRadius: 32,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: GlassSurface(
                  alpha: AppSurfaces.overlayAlphaOf(context),
                  blur: AppSurfaces.blurSigmaOf(context),
                  borderRadius: AppShape.borderRadius(context, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 16, 8, 4),
                        child: Row(
                          children: [
                            Icon(Icons.handyman_rounded, color: scheme.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Toolbox',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  Text(
                                    'Pinned windows from every space and room',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Refresh',
                              onPressed: controller.refreshCatalog,
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              onPressed: () => controller.setToolboxOpen(false),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                      if (controller.pinsLoading)
                        const LinearProgressIndicator(minHeight: 2),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: TextField(
                          controller: search,
                          decoration: const InputDecoration(
                            isDense: true,
                            prefixIcon: Icon(Icons.search_rounded),
                            hintText: 'Search pins and spaces',
                          ),
                        ),
                      ),
                      Expanded(
                        child: shelves.isEmpty
                            ? Center(
                                child: Text(
                                  controller.pinsLoading
                                      ? 'Loading pinned windows…'
                                      : 'No spaces yet',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  16,
                                ),
                                children: [
                                  for (final shelf in shelves) ...[
                                    _SpaceHeader(
                                      name: shelf.name,
                                      onOpen: () => onOpenSpace(shelf.name),
                                    ),
                                    if (shelf.rooms.isEmpty)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          0,
                                          16,
                                          12,
                                        ),
                                        child: Text(
                                          controller.pinsLoading
                                              ? 'Looking for pinned windows…'
                                              : 'No pinned windows',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                    for (final room in shelf.rooms.values) ...[
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          2,
                                          12,
                                          4,
                                        ),
                                        child: Text(
                                          room.name,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(
                                                color: scheme.primary,
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      for (final pin in room.pins)
                                        _PinRow(
                                          source: pin,
                                          placed: controller.isPlaced(pin),
                                          mobile: mobile,
                                          onPlace: () => onPlace(pin),
                                          onShow: () => onShow(pin),
                                        ),
                                    ],
                                    const SizedBox(height: 8),
                                  ],
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<_Shelf> _shelves(String query) {
    final shelves = <String, _Shelf>{};
    for (final space in controller.spaces) {
      shelves[space.id] = _Shelf(space.id, space.name);
    }
    for (final pin in controller.pins) {
      final shelf = shelves[pin.spaceId];
      if (shelf == null) continue;
      final room = shelf.rooms.putIfAbsent(
        pin.roomId,
        () => _ShelfRoom(pin.roomId, pin.roomName),
      );
      room.pins.add(pin);
    }
    bool matches(_Shelf shelf) {
      if (query.isEmpty) return true;
      if (shelf.name.toLowerCase().contains(query)) return true;
      for (final room in shelf.rooms.values) {
        if (room.name.toLowerCase().contains(query)) return true;
        for (final pin in room.pins) {
          if (pin.label.toLowerCase().contains(query) ||
              pin.pin.argsSummary.toLowerCase().contains(query)) {
            return true;
          }
        }
      }
      return false;
    }

    final out = <_Shelf>[];
    for (final shelf in shelves.values) {
      if (!matches(shelf)) continue;
      if (query.isEmpty || shelf.name.toLowerCase().contains(query)) {
        out.add(shelf);
        continue;
      }
      final copy = _Shelf(shelf.id, shelf.name);
      for (final room in shelf.rooms.values) {
        final pins = room.pins
            .where(
              (pin) =>
                  room.name.toLowerCase().contains(query) ||
                  pin.label.toLowerCase().contains(query) ||
                  pin.pin.argsSummary.toLowerCase().contains(query),
            )
            .toList();
        if (pins.isEmpty) continue;
        copy.rooms[room.id] = _ShelfRoom(room.id, room.name)..pins.addAll(pins);
      }
      out.add(copy);
    }
    return out;
  }
}

class _Shelf {
  _Shelf(this.id, this.name);
  final String id;
  final String name;
  final Map<String, _ShelfRoom> rooms = {};
}

class _ShelfRoom {
  _ShelfRoom(this.id, this.name);
  final String id;
  final String name;
  final List<FeedPinSource> pins = [];
}

class _SpaceHeader extends StatelessWidget {
  const _SpaceHeader({required this.name, required this.onOpen});

  final String name;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 0, 2),
      child: Row(
        children: [
          Icon(
            Icons.workspaces_outline,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: 'Open $name',
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _PinRow extends StatelessWidget {
  const _PinRow({
    required this.source,
    required this.placed,
    required this.mobile,
    required this.onPlace,
    required this.onShow,
  });

  final FeedPinSource source;
  final bool placed;
  final bool mobile;
  final VoidCallback onPlace;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail = [
      if (source.pin.argsSummary.isNotEmpty) source.pin.argsSummary,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.surfaceContainerLow.withValues(alpha: .65),
        borderRadius: AppShape.borderRadius(context, 16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(
            children: [
              ToolAvatar(
                tool: source.pin.tool,
                name: source.pin.name,
                size: 36,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (detail.isNotEmpty)
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              placed
                  ? TextButton(onPressed: onShow, child: const Text('Show'))
                  : FilledButton.tonal(
                      onPressed: onPlace,
                      child: Text(mobile ? 'Add widget' : 'Place'),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WidgetActions extends StatelessWidget {
  const _WidgetActions({
    required this.placement,
    required this.mobile,
    required this.onWindow,
    required this.onMaximize,
    required this.onMinimize,
    required this.onRemove,
  });

  final FeedPlacement placement;
  final bool mobile;
  final VoidCallback onWindow;
  final VoidCallback onMaximize;
  final VoidCallback onMinimize;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    void act(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: ToolAvatar(
              tool: placement.pin.tool,
              name: placement.pin.name,
              size: 36,
            ),
            title: Text(
              placement.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              mobile ? 'Compact widget' : 'On your desk',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          if (!mobile)
            ListTile(
              leading: const Icon(Icons.web_asset_rounded),
              title: const Text('Window'),
              onTap: () => act(onWindow),
            ),
          if (!mobile)
            ListTile(
              leading: const Icon(Icons.open_in_full_rounded),
              title: const Text('Maximize'),
              onTap: () => act(onMaximize),
            ),
          ListTile(
            leading: const Icon(Icons.minimize_rounded),
            title: const Text('Minimize'),
            onTap: () => act(onMinimize),
          ),
          ListTile(
            leading: Icon(Icons.close_rounded, color: scheme.error),
            title: Text('Remove', style: TextStyle(color: scheme.error)),
            onTap: () => act(onRemove),
          ),
        ],
      ),
    );
  }
}

/// The full window of a compact widget, in the same sheet a phone desk uses.
class _FeedWindowSheet extends StatelessWidget {
  const _FeedWindowSheet({
    required this.placement,
    required this.onMinimize,
    required this.onRemove,
    required this.child,
  });

  final FeedPlacement placement;
  final VoidCallback onMinimize;
  final VoidCallback onRemove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = [
      if (placement.pin.argsSummary.isNotEmpty) placement.pin.argsSummary,
      placement.roomId == 'home'
          ? placement.spaceName
          : '${placement.spaceName} · ${placement.roomName}',
    ].join('  ·  ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
          child: Row(
            children: [
              ToolAvatar(
                tool: placement.pin.tool,
                name: placement.pin.name,
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      placement.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Minimize',
                onPressed: () {
                  Navigator.of(context).maybePop();
                  onMinimize();
                },
                icon: const Icon(Icons.minimize_rounded),
              ),
              IconButton(
                tooltip: 'Remove',
                onPressed: () {
                  Navigator.of(context).maybePop();
                  onRemove();
                },
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: .5)),
        Expanded(child: child),
      ],
    );
  }
}
