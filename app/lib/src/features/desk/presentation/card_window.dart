import 'package:flutter/material.dart';

import '../domain/desk_models.dart';
import 'tool_avatar.dart';

/// A tool's frontend as a floating card window: a title bar to drag it by
/// (with the result it shows, pin, minimize, maximize and close), the
/// frontend, and a grip to resize it. Pressing anywhere brings it to the front.
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

  @override
  State<CardWindow> createState() => _CardWindowState();
}

class _CardWindowState extends State<CardWindow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _life = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 180))
    ..forward();
  bool _dragging = false;

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
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
        parent: _life, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
    final subtitle = [
      if (w.argsSummary.isNotEmpty) w.argsSummary,
      if (w.openedBy.isNotEmpty &&
          !RegExp(r'^[0-9a-f]{20,}$').hasMatch(w.openedBy))
        'by ${w.openedBy}',
    ].join('  ·  ');
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(widget.maximized ? 20 : 28),
        border: Border.all(
            color: widget.front
                ? scheme.primary.withValues(alpha: .45)
                : scheme.outlineVariant.withValues(alpha: .7),
            width: widget.front ? 1.4 : 1),
        boxShadow: [
          BoxShadow(
              color: Colors.black
                  .withValues(alpha: widget.front || _dragging ? .22 : .10),
              blurRadius: _dragging
                  ? 40
                  : widget.front
                      ? 28
                      : 14,
              offset: Offset(
                  0,
                  _dragging
                      ? 18
                      : widget.front
                          ? 10
                          : 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The title bar: drag by the label; chrome buttons stay tappable.
          Container(
            height: 56,
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            color: widget.front
                ? scheme.surfaceContainer
                : scheme.surfaceContainerLow,
            child: Row(children: [
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
                    child: Row(children: [
                      ToolAvatar(tool: w.tool, name: w.name, size: 34),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(w.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                            if (subtitle.isNotEmpty)
                              Text(subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                          color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
              _ChromeButton(
                tooltip: widget.pinned ? 'Unpin' : 'Pin to the pinned desk',
                icon: widget.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                selected: widget.pinned,
                onPressed: widget.onPin,
              ),
              _ChromeButton(
                tooltip: 'Minimize',
                icon: Icons.minimize_rounded,
                onPressed: widget.onMinimize,
              ),
              _ChromeButton(
                tooltip: widget.maximized ? 'Restore' : 'Maximize',
                icon: widget.maximized
                    ? Icons.close_fullscreen_rounded
                    : Icons.open_in_full_rounded,
                onPressed: widget.onMaximize,
              ),
              _ChromeButton(
                tooltip: 'Close',
                icon: Icons.close_rounded,
                danger: true,
                onPressed: widget.onClose == null ? null : _close,
              ),
            ]),
          ),
          Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: .5)),
          Expanded(
            child: Stack(children: [
              Positioned.fill(child: widget.child),
              if (widget.movable)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => widget.onDragStart?.call(),
                      onPanUpdate: (d) => widget.onResize?.call(d.delta),
                      onPanEnd: (_) => widget.onResizeEnd?.call(),
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CustomPaint(
                            painter: _GripPainter(
                                scheme.onSurfaceVariant.withValues(alpha: .5))),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ],
      ),
    );
    return Listener(
      onPointerDown: (_) => widget.onRaise?.call(),
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

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.tooltip,
    required this.icon,
    this.onPressed,
    this.selected = false,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      style: IconButton.styleFrom(
        foregroundColor: selected ? scheme.primary : scheme.onSurfaceVariant,
        hoverColor: danger ? scheme.errorContainer : null,
        highlightColor: danger ? scheme.error.withValues(alpha: .2) : null,
      ),
      icon: Icon(icon),
    );
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
      canvas.drawLine(Offset(size.width - 6, size.height - 6 - d),
          Offset(size.width - 6 - d, size.height - 6), p);
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => old.color != color;
}
