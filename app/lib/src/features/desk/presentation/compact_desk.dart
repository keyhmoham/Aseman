import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../elpian/core/media.dart';
import '../../../genui/genui.dart'
    show CompactHint, FrontendDisplay, FrontendPresentation;
import '../domain/desk_models.dart';
import 'desk_controller.dart';
import 'desk_dock.dart';
import 'pinned_desk.dart';
import 'tool_avatar.dart';

/// Below this width the desk is a [CompactDesk]; at and above it, the
/// floating card windows of the desktop.
const double compactDeskWidth = 600;

/// The desk on a phone: every window as a compact widget on a board — the
/// minimal information about its data, laid out for its size and shape —
/// that opens the full frontend in a bottom sheet when tapped. Widgets are
/// arranged by dragging (long-press, then move); the menu of each sets its
/// size (small 1×1, medium 2×1, large 2×2 cells) and shape (card, squircle,
/// pill, circle, leaf), pins or deletes it. Closing the sheet minimizes the
/// window to the dock. The arrangement is kept on the node with the window
/// (its `compact`), so it follows the person.
class CompactDesk extends StatefulWidget {
  const CompactDesk({
    super.key,
    required this.controller,
    required this.windowContent,
    required this.pinPreview,
    this.emptyState,
    this.topInset = 0,
  });

  final DeskController controller;

  /// A window's frontend; shown compact on the board and in full in the
  /// sheet (the enclosing [FrontendPresentation] says which).
  final Widget Function(BuildContext context, DeskWindow window) windowContent;
  final Widget Function(DeskPin pin) pinPreview;
  final Widget? emptyState;
  final double topInset;

  @override
  State<CompactDesk> createState() => CompactDeskState();
}

/// A widget's cells on the board.
class BoardSpan {
  const BoardSpan(this.columns, this.rows);
  final int columns;
  final int rows;
}

/// Where a widget sits: its top-left cell and its span.
class BoardSlot {
  const BoardSlot(this.column, this.row, this.span);
  final int column;
  final int row;
  final BoardSpan span;
}

/// The cells of a widget of [size] and [shape] on a board [columns] wide.
BoardSpan boardSpan(String size, String shape, int columns) {
  if (shape == 'circle' || size == 'small') return const BoardSpan(1, 1);
  final wide = math.min(2, columns);
  return size == 'large' ? BoardSpan(wide, 2) : BoardSpan(wide, 1);
}

/// Packs widgets of [spans], in order, each at the first free cells that
/// fit it (row by row, left to right) — a home screen's dense grid.
List<BoardSlot> packBoard(List<BoardSpan> spans, int columns) {
  final taken = <int, Set<int>>{};
  bool free(int col, int row, BoardSpan s) {
    if (col + s.columns > columns) return false;
    for (var r = row; r < row + s.rows; r++) {
      for (var c = col; c < col + s.columns; c++) {
        if (taken[r]?.contains(c) ?? false) return false;
      }
    }
    return true;
  }

  final out = <BoardSlot>[];
  for (final s in spans) {
    var row = 0;
    while (true) {
      final col = [
        for (var c = 0; c < columns; c++) c,
      ].firstWhere((c) => free(c, row, s), orElse: () => -1);
      if (col >= 0) {
        for (var r = row; r < row + s.rows; r++) {
          for (var c = col; c < col + s.columns; c++) {
            (taken[r] ??= {}).add(c);
          }
        }
        out.add(BoardSlot(col, row, s));
        break;
      }
      row++;
    }
  }
  return out;
}

/// The outline of a widget of [shape].
ShapeBorder boardShape(String shape) => switch (shape) {
      'squircle' => const ContinuousRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(64)),
        ),
      'pill' => const StadiumBorder(),
      'circle' => const CircleBorder(),
      'leaf' => const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(44),
            bottomRight: Radius.circular(44),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(12),
          ),
        ),
      _ => const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(26)),
        ),
    };

class CompactDeskState extends State<CompactDesk> {
  static const double _gap = 12;
  static const double _side = 16;
  static const _motion = Duration(milliseconds: 380);
  static const _curve = Curves.easeOutCubic;

  final _scroll = ScrollController();
  final _board = GlobalKey();

  /// Looks frontends asked for (by window), until the person chooses one.
  final Map<String, CompactHint> _hints = {};

  /// Widgets that just arrived, highlighted for a moment.
  final Set<String> _fresh = {};
  final List<Timer> _timers = [];
  Set<String> _seen = {};
  String _scope = '';

  // Dragging: the widget, its board order as it would land, the finger in
  // board coordinates and where it holds the widget.
  String? _dragId;
  List<String>? _dragOrder;
  Offset _finger = Offset.zero;
  Offset _grab = Offset.zero;

  DeskController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(CompactDesk old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    for (final t in _timers) {
      t.cancel();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final scope = '${c.spaceId}/${c.room}';
    final ids = {for (final w in c.state.windows) w.id};
    if (scope != _scope) {
      _scope = scope;
      _seen = c.loaded ? ids : {};
      _fresh.clear();
    } else if (c.loaded) {
      final arrived = ids.difference(_seen);
      if (_seen.isNotEmpty && arrived.isNotEmpty) {
        _fresh.addAll(arrived);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _reveal(arrived.last),
        );
        _timers.add(Timer(const Duration(milliseconds: 1600), () {
          if (mounted) setState(() => _fresh.removeAll(arrived));
        }));
      }
      _seen = ids;
    }
    setState(() {});
  }

  /// The look of [w]'s widget: the person's choice, else its frontend's
  /// hint, else a medium card.
  (String shape, String size) _look(DeskWindow w) {
    final hint = _hints[w.id];
    String pick(
      String? chosen,
      String? hinted,
      List<String> allowed,
      String fallback,
    ) =>
        allowed.contains(chosen)
            ? chosen!
            : allowed.contains(hinted)
                ? hinted!
                : fallback;
    return (
      pick(w.compact?.shape, hint?.shape, DeskCompact.shapes, 'card'),
      pick(w.compact?.size, hint?.size, DeskCompact.sizes, 'medium'),
    );
  }

  int _columns(double width) =>
      math.max(2, ((width - 2 * _side + _gap) / (168 + _gap)).floor());

  ({Map<String, Rect> rects, double height}) _layout(
    List<DeskWindow> windows,
    double width,
  ) {
    final columns = _columns(width);
    final cell = (width - 2 * _side - _gap * (columns - 1)) / columns;
    final slots = packBoard([
      for (final w in windows) boardSpan(_look(w).$2, _look(w).$1, columns),
    ], columns);
    final rects = <String, Rect>{};
    var rows = 0;
    for (var i = 0; i < windows.length; i++) {
      final s = slots[i];
      rows = math.max(rows, s.row + s.span.rows);
      rects[windows[i].id] = Rect.fromLTWH(
        _side + s.column * (cell + _gap),
        s.row * (cell + _gap),
        s.span.columns * cell + (s.span.columns - 1) * _gap,
        s.span.rows * cell + (s.span.rows - 1) * _gap,
      );
    }
    return (
      rects: rects,
      height: rows == 0 ? 0 : rows * cell + (rows - 1) * _gap,
    );
  }

  List<DeskWindow> _windows() {
    final focus = c.focusTool;
    final board = [
      for (final w in c.state.boardOrder)
        if (!c.isMinimized(w.id) && (focus == null || w.tool == focus)) w,
    ];
    final order = _dragOrder;
    if (order == null) return board;
    final byId = {for (final w in board) w.id: w};
    return [
      for (final id in order)
        if (byId[id] != null) byId[id]!,
    ];
  }

  void _reveal(String id) {
    final box = _board.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_scroll.hasClients) return;
    final rect = _layout(_windows(), box.size.width).rects[id];
    if (rect == null) return;
    final view = _scroll.position.viewportDimension;
    final top = rect.top + widget.topInset;
    if (top >= _scroll.offset &&
        top + rect.height <= _scroll.offset + view - 160) {
      return;
    }
    _scroll.animateTo(
      math.min(_scroll.position.maxScrollExtent, math.max(0, top - 24)),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
    );
  }

  Offset _toBoard(Offset global) {
    final box = _board.currentContext!.findRenderObject()! as RenderBox;
    return box.globalToLocal(global);
  }

  void _dragStart(DeskWindow w, LongPressStartDetails d, Rect rect) {
    HapticFeedback.mediumImpact();
    c.beginInteraction();
    setState(() {
      _dragId = w.id;
      _dragOrder = [for (final x in _windows()) x.id];
      _finger = _toBoard(d.globalPosition);
      _grab = _finger - rect.topLeft;
    });
  }

  void _dragMove(LongPressMoveUpdateDetails d, double width) {
    final id = _dragId;
    if (id == null) return;
    _finger = _toBoard(d.globalPosition);
    // The widget under the finger gives the dragged one its place.
    final layout = _layout(_windows(), width);
    final order = [..._dragOrder!];
    for (final e in layout.rects.entries) {
      if (e.key != id && e.value.contains(_finger)) {
        final to = order.indexOf(e.key);
        order
          ..remove(id)
          ..insert(to, id);
        break;
      }
    }
    // Near the edges the board scrolls along.
    if (_scroll.hasClients) {
      final view = _scroll.position.viewportDimension;
      final y = d.globalPosition.dy -
          (context.findRenderObject()! as RenderBox)
              .localToGlobal(Offset.zero)
              .dy;
      final step = y < widget.topInset + 72
          ? -12.0
          : y > view - 180
              ? 12.0
              : 0.0;
      if (step != 0) {
        _scroll.jumpTo(
          (_scroll.offset + step).clamp(0.0, _scroll.position.maxScrollExtent),
        );
      }
    }
    setState(() => _dragOrder = order);
  }

  void _dragEnd() {
    final id = _dragId, order = _dragOrder;
    c.endInteraction();
    setState(() {
      _dragId = null;
      _dragOrder = null;
    });
    if (id == null || order == null) return;
    final before = [for (final w in c.state.boardOrder) w.id];
    // Its place among every widget (others may be hidden by a focus).
    final next = order.indexOf(id);
    final anchor = next + 1 < order.length ? order[next + 1] : null;
    final rest = [...before]..remove(id);
    final at = anchor == null ? rest.length : rest.indexOf(anchor);
    if (before.indexOf(id) != at) c.arrange(id, order: at);
  }

  /// Opens [w] in full, in a bottom sheet.
  Future<void> openSheet(DeskWindow w) {
    final media = ElpianMediaScope.maybeOf(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        Widget body = _WindowSheet(
          controller: c,
          windowId: w.id,
          content: (window) => FrontendPresentation(
            display: FrontendDisplay.sheet,
            child: KeyedSubtree(
              key: ValueKey('sheet-${window.id}'),
              child: Builder(
                  builder: (context) => widget.windowContent(context, window)),
            ),
          ),
        );
        if (media != null)
          body = ElpianMediaScope(resolver: media, child: body);
        return body;
      },
    );
  }

  Future<void> _menu(DeskWindow w) async {
    final (shape, size) = _look(w);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _WidgetMenu(
        window: w,
        shape: shape,
        size: size,
        pinned: c.isPinned(w),
        onLook: (shape, size) => c.arrange(w.id, shape: shape, size: size),
        onOpen: () => openSheet(w),
        onPin: () => c.togglePin(w),
        onClose: () => c.close(w.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final windows = _windows();
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, box) {
              final width = box.maxWidth;
              final layout = _layout(windows, width);
              // Minimized windows stay in the dock; only a truly empty desk
              // shows the empty state.
              if (windows.isEmpty &&
                  c.state.windows.isEmpty &&
                  widget.emptyState != null) {
                return Padding(
                  padding: EdgeInsets.only(
                    top: widget.topInset,
                    bottom: DeskGeometry.bottomReserve,
                  ),
                  child: widget.emptyState,
                );
              }
              return SingleChildScrollView(
                controller: _scroll,
                physics: _dragId == null
                    ? const AlwaysScrollableScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  top: widget.topInset + 12,
                  bottom: DeskGeometry.bottomReserve - 40,
                ),
                child: SizedBox(
                  key: _board,
                  height: layout.height,
                  width: width,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final w in windows)
                        if (w.id != _dragId)
                          _tile(w, layout.rects[w.id]!, width),
                      // The dragged widget follows the finger, above the others.
                      for (final w in windows)
                        if (w.id == _dragId)
                          _tile(w, layout.rects[w.id]!, width),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Center(child: DeskDock(controller: c, compact: true)),
        ),
        Positioned.fill(
          bottom: 84,
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
                    ? PinnedDesk(controller: c, preview: widget.pinPreview)
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
    );
  }

  Widget _tile(DeskWindow w, Rect rect, double width) {
    final dragging = w.id == _dragId;
    final (shape, size) = _look(w);
    final at = dragging ? _finger - _grab : rect.topLeft;
    return AnimatedPositioned(
      key: ValueKey(w.id),
      duration: dragging ? Duration.zero : _motion,
      curve: _curve,
      left: at.dx,
      top: at.dy,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        onTap: () => openSheet(w),
        onLongPressStart: (d) => _dragStart(w, d, rect),
        onLongPressMoveUpdate: (d) => _dragMove(d, width),
        onLongPressEnd: (_) => _dragEnd(),
        onLongPressCancel: () {
          if (_dragId != null) _dragEnd();
        },
        child: AnimatedScale(
          scale: dragging ? 1.06 : 1,
          duration: const Duration(milliseconds: 160),
          child: CompactWidgetTile(
            window: w,
            shape: shape,
            size: size,
            lifted: dragging,
            fresh: _fresh.contains(w.id),
            onMenu: () => _menu(w),
            child: FrontendPresentation(
              display: FrontendDisplay.compact,
              shape: shape,
              size: size,
              title: w.label,
              accent: ToolAvatar.schemeFor(w.tool, Theme.of(context).brightness)
                  .primary,
              onHint: (hint) {
                if (_hints[w.id] != hint && mounted) {
                  setState(() => _hints[w.id] = hint);
                }
              },
              onExpand: () => openSheet(w),
              child: KeyedSubtree(
                key: ValueKey('compact-${w.id}'),
                child: Builder(
                    builder: (context) => widget.windowContent(context, w)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One widget on the board: the window's compact frontend in its shape,
/// named by its tool, with a menu.
class CompactWidgetTile extends StatelessWidget {
  const CompactWidgetTile({
    super.key,
    required this.window,
    required this.shape,
    required this.size,
    required this.child,
    this.lifted = false,
    this.fresh = false,
    this.onMenu,
  });

  final DeskWindow window;
  final String shape;
  final String size;
  final Widget child;
  final bool lifted;
  final bool fresh;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tool =
        ToolAvatar.schemeFor(window.tool, Theme.of(context).brightness);
    final border = boardShape(shape);
    final round = shape == 'circle';
    final pill = shape == 'pill';
    final small = size == 'small' || round;
    final inset = round
        ? 18.0
        : pill
            // (A capsule's ends curve in deep: keep clear of them.)
            ? 34.0
            : 14.0;
    final header = Row(
      children: [
        ToolAvatar(tool: window.tool, name: window.name, size: small ? 22 : 26),
        if (!small) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              window.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
            ),
          ),
        ] else
          const Spacer(),
        if (onMenu != null)
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              tooltip: 'App options',
              padding: EdgeInsets.zero,
              iconSize: 18,
              onPressed: onMenu,
              icon: Icon(
                Icons.more_horiz_rounded,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
    return Semantics(
      button: true,
      label: '${window.label}, app. Tap to open, long-press to move.',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        decoration: ShapeDecoration(
          shape: border is OutlinedBorder
              ? border.copyWith(
                  side: BorderSide(
                    color: fresh
                        ? scheme.primary
                        : scheme.outlineVariant.withValues(alpha: .6),
                    width: fresh ? 2 : 1,
                  ),
                )
              : border,
          color: scheme.surfaceContainerLow,
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: lifted ? .28 : .08),
              blurRadius: lifted ? 30 : 10,
              offset: Offset(0, lifted ? 14 : 3),
            ),
          ],
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: border),
          child: DecoratedBox(
            // A wash of the tool's color, strongest behind its mark.
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tool.primaryContainer.withValues(alpha: .55),
                  scheme.surfaceContainerLow.withValues(alpha: 0),
                ],
                stops: const [0, .7],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                inset,
                round || pill ? 14 : 10,
                round || pill ? inset : 8,
                round ? 14 : inset - 2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (round)
                    Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        height: 26,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ToolAvatar(
                              tool: window.tool,
                              name: window.name,
                              size: 20,
                            ),
                            if (onMenu != null)
                              SizedBox(
                                width: 26,
                                height: 26,
                                child: IconButton(
                                  tooltip: 'App options',
                                  padding: EdgeInsets.zero,
                                  iconSize: 16,
                                  onPressed: onMenu,
                                  icon: const Icon(Icons.more_horiz_rounded),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                  else
                    SizedBox(height: 26, child: header),
                  const SizedBox(height: 8),
                  Expanded(
                    // A glance: taps open the widget, they do not reach in.
                    child: IgnorePointer(
                      child: Padding(
                        padding: EdgeInsets.only(right: round ? 0 : 6),
                        child: child,
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

/// The full frontend of a window in the sheet, with its title and actions;
/// closes itself when the window closes or is minimized away.
class _WindowSheet extends StatelessWidget {
  const _WindowSheet({
    required this.controller,
    required this.windowId,
    required this.content,
  });

  final DeskController controller;
  final String windowId;
  final Widget Function(DeskWindow window) content;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final w =
            controller.state.windows.where((x) => x.id == windowId).firstOrNull;
        if (w == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).maybePop();
          });
          return SizedBox(height: height * .3);
        }
        final scheme = Theme.of(context).colorScheme;
        final subtitle = [
          if (w.argsSummary.isNotEmpty && !w.isDesigned) w.argsSummary,
          if (w.isDesigned && w.request.trim().isNotEmpty)
            'for “${w.request.trim()}”',
        ].join('  ·  ');
        final pinned = controller.isPinned(w);
        return SizedBox(
          height: height * .9,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    ToolAvatar(tool: w.tool, name: w.name, size: 34),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            w.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: pinned ? 'Unpin' : 'Pin to the pinned desk',
                      onPressed: () => controller.togglePin(w),
                      icon: Icon(
                        pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Minimize',
                      onPressed: () {
                        controller.minimize(w.id);
                        Navigator.of(context).maybePop();
                      },
                      icon: const Icon(Icons.minimize_rounded),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: .5),
              ),
              Expanded(child: content(w)),
            ],
          ),
        );
      },
    );
  }
}

/// A widget's options: its size and shape, open, pin, delete.
class _WidgetMenu extends StatefulWidget {
  const _WidgetMenu({
    required this.window,
    required this.shape,
    required this.size,
    required this.pinned,
    required this.onLook,
    required this.onOpen,
    required this.onPin,
    required this.onClose,
  });

  final DeskWindow window;
  final String shape;
  final String size;
  final bool pinned;
  final void Function(String shape, String size) onLook;
  final VoidCallback onOpen;
  final VoidCallback onPin;
  final VoidCallback onClose;

  @override
  State<_WidgetMenu> createState() => _WidgetMenuState();
}

class _WidgetMenuState extends State<_WidgetMenu> {
  late String _shape = widget.shape;
  late String _size = widget.size;

  static const _sizeLabels = {
    'small': 'Small',
    'medium': 'Medium',
    'large': 'Large',
  };
  static const _shapeLabels = {
    'card': 'Card',
    'squircle': 'Squircle',
    'pill': 'Pill',
    'circle': 'Circle',
    'leaf': 'Leaf',
  };

  void _set({String? shape, String? size}) {
    setState(() {
      _shape = shape ?? _shape;
      _size = size ?? _size;
      // A circle is one cell; a bigger widget leaves the circle.
      if (shape == 'circle') _size = 'small';
      if (size != null && size != 'small' && _shape == 'circle') {
        _shape = 'card';
      }
    });
    widget.onLook(_shape, _size);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final maxH = MediaQuery.sizeOf(context).height * .72;
    final subtitle = [
      if (widget.window.argsSummary.isNotEmpty && !widget.window.isDesigned)
        widget.window.argsSummary,
      if (widget.window.isDesigned && widget.window.request.trim().isNotEmpty)
        'for “${widget.window.request.trim()}”',
    ].join('  ·  ');
    Widget label(String title) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            title,
            style: text.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: .2,
            ),
          ),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        16 + MediaQuery.paddingOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ToolAvatar(
                  tool: widget.window.tool,
                  name: widget.window.name,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.window.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        subtitle.isEmpty ? 'Board widget' : subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    label('Size'),
                    SegmentedButton<String>(
                      segments: [
                        for (final s in DeskCompact.sizes)
                          ButtonSegment(
                            value: s,
                            label: Text(_sizeLabels[s]!),
                          ),
                      ],
                      selected: {_size},
                      onSelectionChanged: (v) => _set(size: v.first),
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(height: 16),
                    label('Shape'),
                    SizedBox(
                      height: 76,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: DeskCompact.shapes.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (context, i) {
                          final s = DeskCompact.shapes[i];
                          final selected = s == _shape;
                          return Semantics(
                            button: true,
                            selected: selected,
                            label: _shapeLabels[s],
                            child: InkWell(
                              customBorder: boardShape(s),
                              onTap: () => _set(shape: s),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOutCubic,
                                width: s == 'pill' ? 76 : 64,
                                padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? scheme.primaryContainer
                                          .withValues(alpha: .55)
                                      : scheme.surfaceContainerHighest
                                          .withValues(alpha: .55),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: selected
                                        ? scheme.primary.withValues(alpha: .55)
                                        : scheme.outlineVariant
                                            .withValues(alpha: .35),
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: s == 'pill' ? 44 : 28,
                                      height: 28,
                                      decoration: ShapeDecoration(
                                        color: selected
                                            ? scheme.primary
                                            : scheme.onSurfaceVariant
                                                .withValues(alpha: .35),
                                        shape: boardShape(s),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _shapeLabels[s]!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.labelSmall?.copyWith(
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: selected
                                            ? scheme.onPrimaryContainer
                                            : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onOpen();
                    },
                    icon: const Icon(Icons.open_in_full_rounded, size: 18),
                    label: const Text('Open'),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: widget.pinned ? 'Unpin' : 'Pin',
                  onPressed: () {
                    widget.onPin();
                    Navigator.of(context).pop();
                  },
                  icon: Icon(
                    widget.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Delete window',
                  style: IconButton.styleFrom(
                    foregroundColor: scheme.error,
                    backgroundColor:
                        scheme.errorContainer.withValues(alpha: .55),
                  ),
                  onPressed: () {
                    widget.onClose();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
