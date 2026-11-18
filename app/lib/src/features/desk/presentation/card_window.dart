import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../domain/desk_models.dart';
import 'tool_avatar.dart';

/// A tool's frontend as a floating card window: a title bar to drag it by
/// (with the result it shows, pin, minimize, maximize and close), the
/// frontend, and a grip to resize it. Pressing anywhere brings it to the front.
/// A framed desk-app window: glass shell, title bar and chrome controls.
/// App UI gadgets deliberately do **not** use this — they float as frameless
/// gadgets so they can take custom shapes.
class CardWindow extends StatefulWidget {
  const CardWindow({
    super.key,
    required this.window,
    required this.child,
    this.front = false,
    this.pinned = false,
    this.maximized = false,
    this.movable = true,
    this.onRaise,
    this.onDragStart,
    this.onDrag,
    this.onDragEnd,
    this.onResize,
    this.onResizeEnd,
    this.onClose,
    this.onPin,
    this.onMinimize,
    this.onMaximize,
    this.onSwapCompact,
    this.showPin = true,
    this.closeTooltip = 'Close',
    this.chromeOverlayTooltip = true,
  });

  final DeskWindow window;
  final Widget child;

  /// The front window: a stronger outline and shadow.
  final bool front;
  final bool pinned;
  final bool maximized;

  /// Dragging and resizing are offered (not while gathered or maximized).
  final bool movable;
  final VoidCallback? onRaise;
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDrag;
  final VoidCallback? onDragEnd;
  final ValueChanged<Offset>? onResize;
  final VoidCallback? onResizeEnd;
  final VoidCallback? onClose;
  final VoidCallback? onPin;
  final VoidCallback? onMinimize;
  final VoidCallback? onMaximize;

  /// Switches this window into its compact widget. Hidden when null.
  final VoidCallback? onSwapCompact;

  /// The pin control. Surfaces that are not the room desk turn it off.
  final bool showPin;

  /// The close control's name (`Remove` on the feed desk).
  final String closeTooltip;

  /// Hover labels via [Tooltip]. Off for cards hosted in the root overlay:
  /// that portal cannot host another one, and the page behind the card
  /// becomes the red error screen.
  final bool chromeOverlayTooltip;

  @override
  State<CardWindow> createState() => _CardWindowState();
}

class _CardWindowState extends State<CardWindow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _life = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    reverseDuration: const Duration(milliseconds: 180),
  )..forward();
  bool _dragging = false;
  bool _resizing = false;

  /// A press on the resize grip. Raising a window reorders it in the desk's
  /// stack, which moves its platform views (the page's <iframe>, the grip's
  /// interceptor) in the DOM and cancels the press under the finger. So the
  /// raise waits until the finger is lifted.
  bool _gripDown = false;

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  void _raiseAfterGrip() {
    if (!_gripDown) return;
    _gripDown = false;
    widget.onRaise?.call();
  }

  Future<void> _close() async {
    await _life.reverse();
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final w = widget.window;
    final appear = CurvedAnimation(
      parent: _life,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    );
    final subtitle = [
      if (w.argsSummary.isNotEmpty) w.argsSummary,
      if (w.openedBy.isNotEmpty &&
          !RegExp(r'^[0-9a-f]{20,}$').hasMatch(w.openedBy))
        'by ${w.openedBy}',
    ].join('  ·  ');
    final shell = ThemeChrome.floatingShell(
      context,
      lift: _dragging ? 8 : (widget.front ? 4 : 0),
      radius: widget.maximized ? context.radiusInner : null,
      front: widget.front || _dragging,
    );
    final radius = shell.borderRadius is BorderRadius
        ? shell.borderRadius as BorderRadius
        : context.cardBorderRadius;
    final card = DecoratedBox(
      decoration: shell,
      child: GlassSurface(
        alpha: widget.front
            ? AppSurfaces.overlayAlphaOf(context)
            : AppSurfaces.cardAlphaOf(context),
        borderRadius: radius,
        border: true,
        color: widget.front ? scheme.surfaceContainer : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The title bar: drag by the label; chrome buttons stay tappable.
            Container(
              height: 56,
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              color:
                  (widget.front
                          ? scheme.surfaceContainer
                          : scheme.surfaceContainerLow)
                      .withValues(alpha: .35),
              child: Row(
                children: [
                  Expanded(
                    child: MouseRegion(
                      cursor: widget.movable
                          ? SystemMouseCursors.grab
                          : MouseCursor.defer,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: widget.onMaximize,
                        onPanStart: widget.movable
                            ? (_) {
                                setState(() => _dragging = true);
                                widget.onDragStart?.call();
                              }
                            : null,
                        onPanUpdate: widget.movable
                            ? (d) => widget.onDrag?.call(d.delta)
                            : null,
                        onPanEnd: widget.movable
                            ? (_) {
                                setState(() => _dragging = false);
                                widget.onDragEnd?.call();
                              }
                            : null,
                        child: Row(
                          children: [
                            ToolAvatar(tool: w.tool, name: w.name, size: 34),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    w.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  if (subtitle.isNotEmpty)
                                    Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (widget.showPin)
                    WindowChromeButton(
                      overlayTooltip: widget.chromeOverlayTooltip,
                      tooltip: widget.pinned
                          ? 'Unpin'
                          : 'Pin to the pinned desk',
                      icon: widget.pinned
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                      selected: widget.pinned,
                      onPressed: widget.onPin,
                    ),
                  if (widget.onSwapCompact != null)
                    WindowChromeButton(
                      overlayTooltip: widget.chromeOverlayTooltip,
                      tooltip: 'Compact widget',
                      icon: Icons.widgets_outlined,
                      onPressed: widget.onSwapCompact,
                    ),
                  WindowChromeButton(
                    overlayTooltip: widget.chromeOverlayTooltip,
                    tooltip: 'Minimize',
                    icon: Icons.minimize_rounded,
                    onPressed: widget.onMinimize,
                  ),
                  WindowChromeButton(
                    overlayTooltip: widget.chromeOverlayTooltip,
                    tooltip: widget.maximized ? 'Restore' : 'Maximize',
                    icon: widget.maximized
                        ? Icons.close_fullscreen_rounded
                        : Icons.open_in_full_rounded,
                    onPressed: widget.onMaximize,
                  ),
                  WindowChromeButton(
                    overlayTooltip: widget.chromeOverlayTooltip,
                    tooltip: widget.closeTooltip,
                    icon: Icons.close_rounded,
                    danger: true,
                    onPressed: widget.onClose == null ? null : _close,
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: .5),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: widget.child),
                  // While the window is dragged or resized, a transparent shield
                  // covers the content. A web page is an <iframe>: it swallows
                  // pointer moves that cross it, and the gesture stalls.
                  if (_dragging || _resizing)
                    Positioned.fill(
                      child: PointerInterceptor(child: const SizedBox.expand()),
                    ),
                  if (widget.movable)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      // The grip sits over the page's <iframe>, which would take
                      // its pointer events. The interceptor keeps them in Flutter.
                      child: PointerInterceptor(
                        child: Listener(
                          onPointerDown: (_) => _gripDown = true,
                          onPointerUp: (_) => _raiseAfterGrip(),
                          onPointerCancel: (_) => _raiseAfterGrip(),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.resizeDownRight,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (_) {
                                setState(() => _resizing = true);
                                widget.onDragStart?.call();
                              },
                              onPanUpdate: (d) =>
                                  widget.onResize?.call(d.delta),
                              onPanEnd: (_) {
                                setState(() => _resizing = false);
                                widget.onResizeEnd?.call();
                              },
                              onPanCancel: () {
                                if (_resizing)
                                  setState(() => _resizing = false);
                              },
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CustomPaint(
                                  painter: _GripPainter(
                                    scheme.onSurfaceVariant.withValues(
                                      alpha: .5,
                                    ),
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
          ],
        ),
      ),
    );
    return Listener(
      onPointerDown: (_) {
        if (!_gripDown) widget.onRaise?.call();
      },
      child: FadeTransition(
        opacity: _life,
        child: ScaleTransition(
          scale: Tween(begin: .9, end: 1.0).animate(appear),
          child: AnimatedScale(
            scale: _dragging ? 1.015 : 1,
            duration: const Duration(milliseconds: 160),
            child: card,
          ),
        ),
      ),
    );
  }
}

class WindowChromeButton extends StatefulWidget {
  const WindowChromeButton({
    required this.tooltip,
    required this.icon,
    this.onPressed,
    this.selected = false,
    this.danger = false,
    this.overlayTooltip = true,
  });

  final String tooltip;
  final bool overlayTooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool danger;

  @override
  State<WindowChromeButton> createState() => _WindowChromeButtonState();
}

class _WindowChromeButtonState extends State<WindowChromeButton> {
  bool _hover = false;
  bool _want = false;
  bool _queued = false;

  /// IconButton applies its hover ink inside the mouse-tracker update. On
  /// this scaled card that reenters the tracker and the framework replaces
  /// the whole window with the red error screen. Hover is applied on the
  /// next frame instead, and the ink never leaves this box.
  void _hoverTo(bool value) {
    _want = value;
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted || _hover == _want) return;
      setState(() => _hover = _want);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.danger
        ? scheme.error
        : widget.selected
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final button = Semantics(
      button: true,
      tooltip: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => _hoverTo(true),
        onExit: (_) => _hoverTo(false),
        cursor: widget.onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 32,
            height: 32,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _hover
                    ? (widget.danger
                          ? scheme.error.withValues(alpha: .14)
                          : scheme.primary.withValues(alpha: .10))
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(widget.icon, size: 18, color: fg),
            ),
          ),
        ),
      ),
    );
    // A tooltip is an overlay portal. Cards on the root overlay cannot
    // host one: hovering asserts node.depth > theater.depth and the page
    // behind the card turns into the red error screen.
    if (!widget.overlayTooltip) return button;
    return Tooltip(message: widget.tooltip, child: button);
  }
}

class _GripPainter extends CustomPainter {
  _GripPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (final d in [6.0, 11.0, 16.0]) {
      canvas.drawLine(
        Offset(size.width - 6, size.height - 6 - d),
        Offset(size.width - 6 - d, size.height - 6),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => old.color != color;
}
