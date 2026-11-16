import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_roles.dart';
import '../domain/desk_models.dart';
import 'card_window.dart';
import 'desk_controller.dart';
import 'desk_dock.dart';
import 'pinned_desk.dart';
import 'tool_avatar.dart';

/// The desk of a room: tools' frontends float on it as card windows that
/// people and agents open, move, resize and close; it pans and scrolls when
/// windows lie beyond the screen. The dock is pinned to its bottom; the
/// pinned desk opens over it from the dock.
///
/// [underlay] (workspace side panels) sits above the desk surface and below
/// the windows, so cards can float over the panels while empty desk areas
/// still let those panels receive taps and scrolls.
///
/// [captureSurface] false is a layer over another surface (the workspace):
/// empty space ignores pointers, and cards stay on this layer's viewport so
/// they can move across it. [onlyPresented] draws just the windows
/// [DeskController.present] opened as cards. [showDock] false leaves the dock
/// and the pinned desk to whoever else is showing them (the widget grid).
class FloatingDesk extends StatefulWidget {
  const FloatingDesk({
    super.key,
    required this.controller,
    required this.windowContent,
    required this.pinPreview,
    this.emptyState,
    this.underlay,
    this.topInset = 0,
    this.bottomInset = 0,
    this.captureSurface = true,
    this.onlyPresented = false,
    this.showDock = true,
  });

  final DeskController controller;

  /// A window's frontend.
  final Widget Function(BuildContext context, DeskWindow window) windowContent;

  /// A pinned window's frontend, for its preview.
  final Widget Function(DeskPin pin) pinPreview;

  /// Shown on an empty desk.
  final Widget? emptyState;

  /// Drawn between the desk surface and the windows (e.g. left/right panels).
  final Widget? underlay;

  /// Room at the top for something drawn over the desk (mobile tabs).
  final double topInset;

  /// Room at the bottom when [showDock] is false (the screen's safe area).
  final double bottomInset;

  /// False: this layer does not take pans or taps on empty space.
  final bool captureSurface;

  /// Draw only windows opened as floating cards.
  final bool onlyPresented;

  /// The dock and the pinned desk. Off when another surface owns them.
  final bool showDock;

  @override
  State<FloatingDesk> createState() => _FloatingDeskState();
}

class _FloatingDeskState extends State<FloatingDesk>
    with SingleTickerProviderStateMixin {
  static const _motion = Duration(milliseconds: 520);
  static const _curve = Curves.easeInOutCubicEmphasized;
  static const _gap = 16.0;

  Offset _scroll = Offset.zero;

  /// Rects of windows being dragged or resized, ahead of the node.
  final Map<String, Rect> _live = {};

  /// Windows that just closed (here, by an agent or by someone else),
  /// fading out where they were.
  final Map<String, (DeskWindow, Rect)> _leaving = {};
  static const _leave = Duration(milliseconds: 320);

  /// The windows and where they were drawn, as of the last change.
  Map<String, DeskWindow> _seen = {};
  Map<String, Rect> _placed = {};
  String _scope = '';
  Size _viewport = Size.zero;

  /// The first loaded snapshot is the board, not a burst of new cards.
  bool _settled = false;
  bool _handling = false;

  /// Glides the desk to a window that opened out of sight. Made in
  /// initState: made lazily, a desk that never glided made it in dispose(),
  /// when its ticker can no longer look up the tree.
  late final AnimationController _pan;
  Tween<Offset>? _panTween;

  DeskController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _pan =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 560),
        )..addListener(() {
          final a = _panTween;
          if (a != null) {
            setState(
              () => _scroll = a.transform(
                Curves.easeInOutCubicEmphasized.transform(_pan.value),
              ),
            );
          }
        });
    _scope = '${c.spaceId}/${c.room}';
    if (c.loaded) {
      _settled = true;
      _seen = {for (final w in c.state.windows) w.id: w};
    }
    c.addListener(_changed);
  }

  @override
  void didUpdateWidget(FloatingDesk old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _settled = false;
      _seen = {};
      _scope = '';
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _pan.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted || _handling) return;
    _handling = true;
    try {
      // A shelved or dismissed card must not keep the rect it last flew to
      // (the dock). Coming back from that rect leaves the card undraggable.
      _live.removeWhere(
        (id, _) =>
            c.isMinimized(id) || (widget.onlyPresented && !c.isPresented(id)),
      );
      final now = {for (final w in c.state.windows) w.id: w};
      final scope = '${c.spaceId}/${c.room}';
      if (scope != _scope) {
        // Another room's desk: nothing leaves or arrives, it is just shown.
        _scope = scope;
        _leaving.clear();
        _scroll = Offset.zero;
        _settled = widget.onlyPresented ? false : c.loaded;
        _seen = widget.onlyPresented || !c.loaded ? {} : now;
        if (!widget.onlyPresented || !c.loaded) return;
        // Already loaded under the new scope: that snapshot is the board.
        _settled = true;
        _seen = now;
        return;
      }
      if (widget.onlyPresented && c.loaded && !_settled) {
        _settled = true;
        _seen = now;
        return;
      }
      if (_seen.isNotEmpty || c.loaded) {
        for (final id in _seen.keys) {
          if (now.containsKey(id) || !_placed.containsKey(id)) continue;
          _leaving[id] = (_seen[id]!, _placed[id]!);
          Future<void>.delayed(_leave, () {
            if (mounted) setState(() => _leaving.remove(id));
          });
        }
        final opened = [
          for (final w in now.values)
            if (!_seen.containsKey(w.id)) w,
        ];
        if (widget.onlyPresented && _settled) {
          for (final w in opened) {
            c.present(w.id);
          }
        }
        if (_seen.isNotEmpty && opened.isNotEmpty && widget.captureSurface) {
          _reveal(opened.last.rect);
        }
      }
      _seen = c.loaded ? now : _seen;
      if (widget.onlyPresented && _settled && c.focusTool != null) {
        for (final w in now.values) {
          if (w.tool == c.focusTool && !c.isPresented(w.id)) c.present(w.id);
        }
      }
    } finally {
      _handling = false;
      if (mounted) setState(() {});
    }
  }

  /// The band under the windows: the dock, or the safe area when it is absent.
  double get _bottomBand => widget.showDock
      ? DeskGeometry.bottomReserve
      : math.max(widget.bottomInset, 16);

  /// Keeps a card's title bar on this layer. Used when the layer covers the
  /// screen and does not pan.
  Rect _fit(Rect rect, Size viewport) {
    final maxLeft = math.max(0.0, viewport.width - 96);
    final maxTop = math.max(
      widget.topInset,
      viewport.height - _bottomBand - 48,
    );
    return Rect.fromLTWH(
      rect.left.clamp(0.0, maxLeft),
      rect.top.clamp(widget.topInset, maxTop),
      rect.width,
      rect.height,
    );
  }

  /// Scrolls the desk, animated, until [rect] is in view.
  void _reveal(Rect rect) {
    if (_viewport == Size.zero || c.focusTool != null) return;
    final visible = Rect.fromLTWH(
      _scroll.dx,
      _scroll.dy + widget.topInset,
      _viewport.width,
      _viewport.height - widget.topInset - _bottomBand,
    );
    if (visible.contains(rect.topLeft) &&
        visible.contains(rect.bottomRight.translate(-1, -1))) {
      return;
    }
    final target = Offset(
      math.max(0, rect.left - DeskGeometry.margin),
      math.max(0, rect.top - widget.topInset - DeskGeometry.margin),
    );
    _panTween = Tween(begin: _scroll, end: target);
    _pan.forward(from: 0);
  }

  /// Where windows go to be seen at once, in desk coordinates.
  Rect _usable(Size viewport) => Rect.fromLTWH(
    _scroll.dx + DeskGeometry.margin,
    _scroll.dy + widget.topInset + DeskGeometry.margin,
    math.max(DeskGeometry.minW, viewport.width - 2 * DeskGeometry.margin),
    math.max(
      DeskGeometry.minH,
      viewport.height - widget.topInset - DeskGeometry.margin - _bottomBand,
    ),
  );

  /// The windows of one tool, gathered in a grid in the visible area.
  Map<String, Rect> _gather(List<DeskWindow> windows, Rect area) {
    final n = windows.length;
    var bestCols = 1;
    var bestScale = 0.0;
    for (var cols = 1; cols <= n; cols++) {
      final rows = (n / cols).ceil();
      final cw = (area.width - _gap * (cols - 1)) / cols;
      final ch = (area.height - _gap * (rows - 1)) / rows;
      final scale = math.min(
        cw / DeskGeometry.defaultW,
        ch / DeskGeometry.defaultH,
      );
      if (scale > bestScale) {
        bestScale = scale;
        bestCols = cols;
      }
    }
    final rows = (n / bestCols).ceil();
    final cw = (area.width - _gap * (bestCols - 1)) / bestCols;
    final ch = (area.height - _gap * (rows - 1)) / rows;
    final out = <String, Rect>{};
    for (var i = 0; i < n; i++) {
      final col = i % bestCols, row = i ~/ bestCols;
      final w = math.max(
        DeskGeometry.minW,
        math.min(windows[i].rect.width, cw),
      );
      final h = math.max(
        DeskGeometry.minH,
        math.min(windows[i].rect.height, ch),
      );
      final cell = Rect.fromLTWH(
        area.left + col * (cw + _gap),
        area.top + row * (ch + _gap),
        cw,
        ch,
      );
      out[windows[i].id] = Rect.fromCenter(
        center: cell.center,
        width: w,
        height: h,
      );
    }
    // Fewer windows than the grid holds: the whole group centered.
    final bounds = out.values.reduce((a, b) => a.expandToInclude(b));
    final shift = Offset(
      area.center.dx - bounds.center.dx,
      area.top - bounds.top + math.max(0, (area.height - bounds.height) / 2),
    );
    return out.map((k, r) => MapEntry(k, r.shift(shift)));
  }

  Size _canvas(Size viewport, Iterable<Rect> rects) {
    var w = viewport.width, h = viewport.height;
    for (final r in rects) {
      w = math.max(w, r.right + DeskGeometry.margin);
      h = math.max(h, r.bottom + _bottomBand);
    }
    return Size(w, h);
  }

  void _scrollBy(Offset delta, Size viewport, Size canvas) {
    if (_pan.isAnimating) _pan.stop();
    final next = Offset(
      (_scroll.dx + delta.dx).clamp(
        0.0,
        math.max(0.0, canvas.width - viewport.width),
      ),
      (_scroll.dy + delta.dy).clamp(
        0.0,
        math.max(0.0, canvas.height - viewport.height),
      ),
    );
    if (next != _scroll) setState(() => _scroll = next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final viewport = box.biggest;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => c.reportViewport(viewport),
        );
        final compact = viewport.width < 600;
        final state = c.state;
        final windows = [
          for (final w in state.windows)
            if (!widget.onlyPresented || c.isPresented(w.id)) w,
        ]..sort((a, b) => a.z.compareTo(b.z));
        final focus = c.focusTool;
        final maximized = c.maximized;
        final usable = _usable(viewport);
        final gathered = focus == null
            ? const <String, Rect>{}
            : _gather(windows.where((w) => w.tool == focus).toList(), usable);
        // The dock, in desk coordinates: hidden windows fly into it.
        final dock = Offset(
          _scroll.dx + viewport.width / 2,
          _scroll.dy + viewport.height - 40,
        );
        final topZ = windows.isEmpty ? 0 : windows.last.z;

        final placed = <String, Rect>{};
        final hidden = <String>{};
        for (final w in windows) {
          if (maximized == w.id) {
            placed[w.id] = usable;
          } else if (c.isMinimized(w.id) ||
              (focus != null && w.tool != focus)) {
            // Minimized, or another tool's while one is focused: into the dock.
            hidden.add(w.id);
            placed[w.id] = Rect.fromCenter(
              center: dock,
              width: w.rect.width,
              height: w.rect.height,
            );
          } else {
            final raw = gathered[w.id] ?? _live[w.id] ?? w.rect;
            placed[w.id] = widget.captureSurface ? raw : _fit(raw, viewport);
          }
        }
        _placed = placed;
        _viewport = viewport;
        final canvas = _canvas(viewport, [
          for (final w in windows)
            if (!hidden.contains(w.id) && maximized != w.id)
              widget.captureSurface
                  ? (_live[w.id] ?? w.rect)
                  : (placed[w.id] ?? w.rect),
        ]);
        if (_scroll.dx > canvas.width - viewport.width ||
            _scroll.dy > canvas.height - viewport.height) {
          _scroll = Offset(
            _scroll.dx.clamp(0.0, math.max(0.0, canvas.width - viewport.width)),
            _scroll.dy.clamp(
              0.0,
              math.max(0.0, canvas.height - viewport.height),
            ),
          );
        }
        // Paint order: by z, the maximized window last.
        final order = [
          ...windows.where((w) => w.id != maximized),
          ...windows.where((w) => w.id == maximized),
        ];

        return ClipRect(
          child: Stack(
            children: [
              // The desk itself: drag or scroll it to pan.
              Positioned.fill(
                child: widget.captureSurface
                    ? Listener(
                        onPointerSignal: (e) {
                          if (e is PointerScrollEvent) {
                            GestureBinding.instance.pointerSignalResolver
                                .register(e, (event) {
                                  final s = event as PointerScrollEvent;
                                  _scrollBy(s.scrollDelta, viewport, canvas);
                                });
                          }
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (d) =>
                              _scrollBy(-d.delta, viewport, canvas),
                          child: windows.isEmpty && widget.emptyState != null
                              ? Padding(
                                  padding: EdgeInsets.only(
                                    top: widget.topInset,
                                    bottom: _bottomBand,
                                  ),
                                  child: widget.emptyState,
                                )
                              : const SizedBox.expand(),
                        ),
                      )
                    : const SizedBox.expand(),
              ),
              // Side panels (and similar): above the surface, under the windows.
              if (widget.underlay != null)
                Positioned.fill(child: widget.underlay!),
              Positioned(
                left: -_scroll.dx,
                top: -_scroll.dy,
                width: canvas.width,
                height: canvas.height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final w in order)
                      _window(
                        w,
                        placed[w.id]!,
                        hidden.contains(w.id),
                        w.z == topZ,
                        maximized,
                        focus,
                      ),
                    // Closed windows fade out where they were.
                    for (final e in _leaving.entries)
                      if (!placed.containsKey(e.key))
                        _window(
                          e.value.$1,
                          e.value.$2,
                          false,
                          false,
                          null,
                          null,
                          leaving: true,
                        ),
                  ],
                ),
              ),
              if (canvas.height > viewport.height + 1)
                _ScrollThumb(
                  axis: Axis.vertical,
                  viewport: viewport.height - _bottomBand,
                  content: canvas.height - _bottomBand,
                  offset: _scroll.dy,
                  top: widget.topInset,
                ),
              if (canvas.width > viewport.width + 1)
                _ScrollThumb(
                  axis: Axis.horizontal,
                  viewport: viewport.width,
                  content: canvas.width,
                  offset: _scroll.dx,
                  top: viewport.height - _bottomBand + 4,
                ),
              // Showing one tool's windows: say so, and how to see them all.
              Positioned(
                top: widget.topInset + 8,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: focus == null
                        ? const SizedBox.shrink()
                        : _FocusBanner(
                            key: ValueKey(focus),
                            tool: focus,
                            name: state.openTools
                                .firstWhere(
                                  (t) => t.$1 == focus,
                                  orElse: () => (focus, '', 0),
                                )
                                .$2,
                            onShowAll: () => c.focusOn(null),
                          ),
                  ),
                ),
              ),
              if (widget.showDock)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Center(
                    child: DeskDock(controller: c, compact: compact),
                  ),
                ),
              // The pinned desk, risen from the dock.
              if (widget.showDock)
                Positioned.fill(
                  bottom: compact ? 84 : 96,
                  top: widget.topInset,
                  child: IgnorePointer(
                    ignoring: !c.pinnedOpen,
                    child: AnimatedSlide(
                      offset: Offset(0, c.pinnedOpen ? 0 : .08),
                      duration: const Duration(milliseconds: 380),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: c.pinnedOpen ? 1 : 0,
                        duration: const Duration(milliseconds: 260),
                        child: c.pinnedOpen || c.state.pins.isNotEmpty
                            ? PinnedDesk(
                                controller: c,
                                preview: widget.pinPreview,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              if (c.error != null && !c.loaded)
                Positioned(
                  top: widget.topInset + 8,
                  right: 12,
                  child: Chip(
                    avatar: Icon(
                      Icons.cloud_off_rounded,
                      size: 16,
                      color: scheme.error,
                    ),
                    label: const Text('Desk unavailable'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _window(
    DeskWindow w,
    Rect rect,
    bool hidden,
    bool front,
    String? maximized,
    String? focus, {
    bool leaving = false,
  }) {
    final live = _live.containsKey(w.id);
    final movable = focus == null && maximized == null;
    return AnimatedPositioned(
      key: ValueKey(w.id),
      duration: live ? Duration.zero : _motion,
      curve: _curve,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: IgnorePointer(
        ignoring: hidden || leaving,
        child: AnimatedOpacity(
          opacity: hidden || leaving ? 0 : 1,
          duration: leaving ? _leave : _motion,
          curve: leaving ? Curves.easeIn : _curve,
          child: AnimatedScale(
            scale: hidden
                ? .25
                : leaving
                ? .92
                : 1,
            duration: leaving ? _leave : _motion,
            curve: leaving ? Curves.easeIn : _curve,
            child: CardWindow(
              window: w,
              chromeOverlayTooltip: false,
              front: front && !hidden,
              pinned: c.isPinned(w),
              maximized: maximized == w.id,
              movable: movable,
              onRaise: () => c.raise(w.id),
              onDragStart: () {
                c.beginInteraction();
                setState(() => _live[w.id] = rect);
              },
              onDrag: (d) => setState(() {
                final r = _live[w.id] ?? rect;
                final next = r.shift(d);
                final shifted = next.shift(
                  Offset(math.max(0, -next.left), math.max(0, -next.top)),
                );
                _live[w.id] = widget.captureSurface
                    ? shifted
                    : _fit(shifted, _viewport);
              }),
              onDragEnd: () => _commit(w.id),
              onResize: (d) => setState(() {
                final r = _live[w.id] ?? rect;
                _live[w.id] = Rect.fromLTWH(
                  r.left,
                  r.top,
                  math.max(DeskGeometry.minW, r.width + d.dx),
                  math.max(DeskGeometry.minH, r.height + d.dy),
                );
              }),
              onResizeEnd: () => _commit(w.id),
              // A card over the widget board is only a view of that widget.
              // Close puts the card away. Minimize shelves it for the dock.
              // Neither deletes the widget.
              onClose: () =>
                  widget.onlyPresented ? c.dismiss(w.id) : c.close(w.id),
              onPin: () => c.togglePin(w),
              onMinimize: () =>
                  widget.onlyPresented ? c.shelve(w.id) : c.minimize(w.id),
              onMaximize: () => c.toggleMaximized(w.id),
              child: KeyedSubtree(
                key: ValueKey('content-${w.id}'),
                child: widget.windowContent(context, w),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _commit(String id) async {
    final r = _live[id];
    c.endInteraction();
    if (r == null) return;
    final rounded = Rect.fromLTWH(
      r.left.roundToDouble(),
      r.top.roundToDouble(),
      r.width.roundToDouble(),
      r.height.roundToDouble(),
    );
    await c.move(id, rounded);
    if (mounted) setState(() => _live.remove(id));
  }
}

class _FocusBanner extends StatelessWidget {
  const _FocusBanner({
    super.key,
    required this.tool,
    required this.name,
    required this.onShowAll,
  });

  final String tool;
  final String name;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pill = context.navPillRecipe;
    final shape = ThemeChrome.outlinedBorder(pill);
    final shadows = ThemeChrome.cardDecoration(
      context,
      elevated: true,
    ).boxShadow;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: ThemeRoles.wellFill(context),
        shape: shape,
        shadows: shadows,
      ),
      child: Material(
        color: Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ToolAvatar(tool: tool, name: name, size: 26, selected: true),
              const SizedBox(width: 8),
              Text(
                'Only $name',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              TextButton(onPressed: onShowAll, child: const Text('Show all')),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScrollThumb extends StatelessWidget {
  const _ScrollThumb({
    required this.axis,
    required this.viewport,
    required this.content,
    required this.offset,
    required this.top,
  });

  final Axis axis;
  final double viewport;
  final double content;
  final double offset;
  final double top;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.onSurfaceVariant.withValues(alpha: .35);
    final fraction = (viewport / content).clamp(.08, 1.0);
    final start = (offset / content).clamp(0.0, 1 - fraction);
    if (axis == Axis.vertical) {
      return Positioned(
        right: 3,
        top: top + 8,
        bottom: DeskGeometry.bottomReserve,
        child: LayoutBuilder(
          builder: (context, box) {
            return SizedBox(
              width: 4,
              child: Stack(
                children: [
                  Positioned(
                    top: box.maxHeight * start,
                    height: box.maxHeight * fraction,
                    left: 0,
                    right: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }
    return Positioned(
      left: 8,
      right: 8,
      top: top,
      child: LayoutBuilder(
        builder: (context, box) {
          return SizedBox(
            height: 4,
            child: Stack(
              children: [
                Positioned(
                  left: box.maxWidth * start,
                  width: box.maxWidth * fraction,
                  top: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
