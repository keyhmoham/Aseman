import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../data/gadgets_api.dart';
import 'gadgets_controller.dart';
import 'gadgets_panel.dart';

/// A floating app gadget: the same content stack as an App UI, but
/// **frameless** (no window chrome, glass pad or title bar) so the screen can
/// take any custom gadget-like shape. Desk apps keep framed [CardWindow]s;
/// gadgets do not. Always draggable from the top grabber; right-click or
/// long-press opens the menu (minimise, close, open as page, …). Space
/// gadgets share one layer over the whole workspace; account gadgets float
/// universally over home and workspaces.
class Gadget extends StatelessWidget {
  const Gadget({
    super.key,
    required this.dependencies,
    required this.gadget,
    required this.controller,
    this.spaceId = '',
    this.roomId = '',
    this.constrainToParent = true,
    this.compact = false,
  });

  final AppDependencies dependencies;
  final GadgetInfo gadget;
  final GadgetsController controller;
  final String spaceId;
  final String roomId;

  /// Keep the window inside its Stack parent (surface hosts).
  final bool constrainToParent;

  /// Smaller default size for rail / narrow panels (layout only; no chrome).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layoutOf(gadget.id);
    if (layout.mode != GadgetMode.open) return const SizedBox.shrink();
    return _FloatingGadget(
      dependencies: dependencies,
      gadget: gadget,
      controller: controller,
      layout: layout,
      spaceId: spaceId,
      roomId: roomId,
      constrainToParent: constrainToParent,
      compact: compact,
    );
  }
}

class _FloatingGadget extends StatefulWidget {
  const _FloatingGadget({
    required this.dependencies,
    required this.gadget,
    required this.controller,
    required this.layout,
    required this.spaceId,
    required this.roomId,
    required this.constrainToParent,
    required this.compact,
  });

  final AppDependencies dependencies;
  final GadgetInfo gadget;
  final GadgetsController controller;
  final GadgetState layout;
  final String spaceId;
  final String roomId;
  final bool constrainToParent;
  final bool compact;

  @override
  State<_FloatingGadget> createState() => _FloatingGadgetState();
}

class _FloatingGadgetState extends State<_FloatingGadget> {
  late Offset _offset = widget.layout.offset;
  late Size _size = widget.layout.size;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant _FloatingGadget old) {
    super.didUpdateWidget(old);
    if (old.layout.offset != widget.layout.offset) {
      _offset = widget.layout.offset;
    }
    if (old.layout.size != widget.layout.size) {
      _size = widget.layout.size;
    }
  }

  void _clamp(Size bounds) {
    if (!widget.constrainToParent || bounds == Size.zero) return;
    final maxX = (bounds.width - _size.width).clamp(0.0, bounds.width);
    final maxY = (bounds.height - _size.height).clamp(0.0, bounds.height);
    _offset = Offset(
      _offset.dx.clamp(0.0, maxX),
      _offset.dy.clamp(0.0, maxY),
    );
  }

  void _onDragUpdate(DragUpdateDetails d, Size bounds) {
    setState(() {
      _dragging = true;
      _offset += d.delta;
      _clamp(bounds);
    });
  }

  void _onDragEnd() {
    widget.controller.move(widget.gadget.id, _offset);
    if (mounted) setState(() => _dragging = false);
  }

  Future<void> _menu(Offset global) async {
    final box = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = box?.size ?? MediaQuery.sizeOf(context);
    final local = box?.globalToLocal(global) ?? global;
    final choice = await showAppMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        local.dx,
        local.dy,
        size.width - local.dx,
        size.height - local.dy,
      ),
      items: const [
        PopupMenuItem(
          value: 'minimise',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.minimize_rounded),
            title: Text('Minimise'),
            subtitle: Text('Reopen from Gadgets'),
          ),
        ),
        PopupMenuItem(
          value: 'page',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.open_in_full_rounded),
            title: Text('Open as page'),
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'close',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.close_rounded),
            title: Text('Close'),
          ),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'minimise' || choice == 'close') {
      widget.controller.dock(widget.gadget.id);
    } else if (choice == 'page') {
      await openGadgetPage(
        context,
        widget.dependencies,
        widget.gadget,
        spaceId: widget.spaceId,
        roomId: widget.roomId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final bounds = Size(
        box.maxWidth.isFinite ? box.maxWidth : MediaQuery.sizeOf(context).width,
        box.maxHeight.isFinite
            ? box.maxHeight
            : MediaQuery.sizeOf(context).height,
      );
      _clamp(bounds);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: _offset.dx,
            top: _offset.dy,
            width: _size.width,
            height: _size.height,
            // Frameless: no glass pad / window frame — the app draws its own
            // shape. A slim grabber is the only move affordance.
            child: Material(
              type: MaterialType.transparency,
              child: Listener(
                onPointerDown: (e) {
                  if (e.buttons == kSecondaryMouseButton) {
                    _menu(e.position);
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onLongPressStart: (d) => _menu(d.globalPosition),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: GadgetView(
                          dependencies: widget.dependencies,
                          gadget: widget.gadget,
                          spaceId: widget.spaceId,
                          roomId: widget.roomId,
                        ),
                      ),
                      // Always-on drag handle: a gadget grabber, not a title bar.
                      Positioned(
                        top: 6,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: MouseRegion(
                            cursor: _dragging
                                ? SystemMouseCursors.grabbing
                                : SystemMouseCursors.grab,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanUpdate: (d) => _onDragUpdate(d, bounds),
                              onPanEnd: (_) => _onDragEnd(),
                              onPanCancel: _onDragEnd,
                              child: Semantics(
                                label: 'Move ${widget.gadget.name}',
                                button: true,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  width: _dragging ? 48 : 40,
                                  height: 18,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: (_dragging
                                            ? ThemeRoles.selectedFill(context)
                                            : scheme.surfaceContainerHighest)
                                        .withValues(alpha: _dragging ? .95 : .72),
                                    borderRadius: BorderRadius.circular(99),
                                    border: Border.all(
                                      color: (_dragging
                                              ? ThemeRoles.selectedInk(context)
                                              : scheme.outlineVariant)
                                          .withValues(alpha: .55),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: scheme.shadow
                                            .withValues(alpha: .18),
                                        blurRadius: 6,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: Container(
                                    width: 18,
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color: (_dragging
                                              ? ThemeRoles.selectedInk(context)
                                              : scheme.onSurfaceVariant)
                                          .withValues(alpha: .75),
                                      borderRadius: BorderRadius.circular(99),
                                    ),
                                  ),
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
        ],
      );
    });
  }
}

/// The open floaters of one surface. Minimised gadgets draw nothing (the
/// gadgets manager lists them), and empty areas do not absorb pointer events.
class GadgetLayer extends StatelessWidget {
  const GadgetLayer({
    super.key,
    required this.dependencies,
    required this.controller,
    required this.gadgets,
    this.spaceId = '',
    this.roomId = '',
    this.compact = false,
  });

  final AppDependencies dependencies;
  final GadgetsController controller;
  final List<GadgetInfo> gadgets;
  final String spaceId;
  final String roomId;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final open = [
      for (final p in gadgets)
        if (controller.layoutOf(p.id).mode == GadgetMode.open) p
    ];
    if (open.isEmpty) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final p in open)
          Positioned.fill(
            child: Gadget(
              dependencies: dependencies,
              gadget: p,
              controller: controller,
              spaceId: spaceId,
              roomId: roomId,
              compact: compact,
            ),
          ),
      ],
    );
  }
}
