import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the person arranged on the desktop panes, kept on this device:
/// each resizable pane's width, which side a desk sits on, and whether a
/// list or feed pane is hidden.
///
/// Values are addressed by the same `storageKey` a [SplitPane] is given
/// (`desk.room`, `home.feed`, …), so every pane pair remembers its own
/// arrangement. Stored in [SharedPreferences], like the theme.
class PaneLayout extends ChangeNotifier {
  PaneLayout._();

  /// A store that never touches the device, for tests.
  @visibleForTesting
  PaneLayout.memory() : _persist = false;

  static final PaneLayout instance = PaneLayout._();

  static const storageKey = 'aseman.panes';

  final Map<String, double> _widths = {};
  final Map<String, bool> _flags = {};
  bool _persist = true;
  bool _loaded = false;
  Future<void>? _loading;
  Future<void>? _save;

  /// Loads the saved arrangement. Safe to call more than once; whatever the
  /// person changed before it finished is kept.
  static Future<void> restore() => instance.load();

  Future<void> load() {
    if (!_persist || _loaded) return Future.value();
    return _loading ??= _read();
  }

  Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      var changed = false;
      final widths = decoded['widths'];
      if (widths is Map) {
        widths.forEach((key, value) {
          if (key is String && value is num && !_widths.containsKey(key)) {
            _widths[key] = value.toDouble();
            changed = true;
          }
        });
      }
      final flags = decoded['flags'];
      if (flags is Map) {
        flags.forEach((key, value) {
          if (key is String && value is bool && !_flags.containsKey(key)) {
            _flags[key] = value;
            changed = true;
          }
        });
      }
      if (changed) notifyListeners();
    } catch (_) {
      // No device store here: the arrangement lasts for this session.
    } finally {
      _loaded = true;
    }
  }

  /// The width the person dragged [key] to, if they did.
  double? width(String key) => _widths[key];

  /// Sets [key]'s width. A drag passes `save: false` and saves once, when it
  /// ends. `null` forgets the width, back to the pane's default.
  void setWidth(String key, double? value, {bool save = true}) {
    if (value == null) {
      if (_widths.remove(key) == null) return;
    } else {
      if (_widths[key] == value) return;
      _widths[key] = value;
    }
    notifyListeners();
    if (save) this.save();
  }

  /// Forgets every arrangement (and, on the device, nothing: only memory).
  @visibleForTesting
  void reset() {
    _widths.clear();
    _flags.clear();
    notifyListeners();
  }

  bool flag(String key) => _flags[key] ?? false;

  void setFlag(String key, bool value) {
    if (flag(key) == value) return;
    _flags[key] = value;
    notifyListeners();
    save();
  }

  /// Whether the pane stored under [key] is hidden.
  bool hidden(String key) => flag('$key.hidden');

  /// Whether the pane pair under [key] has traded places.
  bool swapped(String key) => flag('$key.swapped');

  void save() {
    if (!_persist) return;
    _save = (_save ?? Future.value()).then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          storageKey,
          jsonEncode({'widths': _widths, 'flags': _flags}),
        );
      } catch (_) {}
    });
  }
}

/// Two panes side by side — a flexible [main] and a [side] with a width the
/// person controls — joined by one standard handle on their shared line.
///
/// The handle sits centered vertically on the line. Drag it, or focus it and
/// use the arrow keys, to resize the side pane; double-click resets it. With
/// [swappable] it carries a button that trades the panes' places, and with
/// [collapsible] a button that hides the side pane so [main] takes its
/// space (a small tab on the same edge brings it back).
///
/// The panes stay mounted (and keep their state) while they are resized,
/// swapped or hidden.
class SplitPane extends StatefulWidget {
  const SplitPane({
    super.key,
    required this.main,
    required this.side,
    required this.storageKey,
    required this.defaultSideWidth,
    this.sideLabel = 'panel',
    this.minSideWidth = 200,
    this.minMainWidth = 360,
    this.sideLeading = false,
    this.swappable = false,
    this.collapsible = false,
    this.layout,
  });

  /// The pane that takes whatever the side pane leaves.
  final Widget main;

  /// The pane with the adjustable width. Give it no width of its own.
  final Widget side;

  /// Names this pair in [PaneLayout]; its width, side and visibility are
  /// remembered under it.
  final String storageKey;

  /// The side pane's width until the person resizes it, for a row [total]
  /// logical pixels wide.
  final double Function(double total) defaultSideWidth;

  /// What the side pane is called in tooltips and by a screen reader
  /// ("desk", "feed", "chats list").
  final String sideLabel;

  final double minSideWidth;
  final double minMainWidth;

  /// Whether the side pane starts at the leading edge (a list or feed) or the
  /// trailing one (a desk), before any swap.
  final bool sideLeading;

  /// Adds the button that swaps the two panes.
  final bool swappable;

  /// Adds the buttons that hide and show the side pane.
  final bool collapsible;

  /// Where the arrangement is kept; the device store unless a test passes one.
  final PaneLayout? layout;

  @override
  State<SplitPane> createState() => _SplitPaneState();
}

class _SplitPaneState extends State<SplitPane> {
  /// The handle's grab area, centered on the 1dp line between the panes.
  static const double _grab = 13;
  static const double _line = 1;
  static const double _keyStep = 16;

  PaneLayout get _layout => widget.layout ?? PaneLayout.instance;

  /// Where the width is while a drag is under way, before it is clamped.
  double _dragWidth = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_layout.load());
  }

  double _maxSide(double total) =>
      math.max(widget.minSideWidth, total - widget.minMainWidth - _line);

  double _sideWidth(double total) {
    final wanted =
        _layout.width(_widthKey) ?? widget.defaultSideWidth(total);
    return wanted.clamp(widget.minSideWidth, _maxSide(total)).toDouble();
  }

  String get _widthKey => '${widget.storageKey}.width';

  void _setWidth(double total, double value, {bool save = false}) {
    _layout.setWidth(
      _widthKey,
      value.clamp(widget.minSideWidth, _maxSide(total)).roundToDouble(),
      save: save,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _layout,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final total = box.maxWidth;
        final hidden = widget.collapsible && _layout.hidden(widget.storageKey);
        final swapped = widget.swappable && _layout.swapped(widget.storageKey);
        final leading = widget.sideLeading != swapped;
        // A hidden pane is still laid out at the width it will come back at,
        // so its content never squeezes while it is away.
        final side = _sideWidth(total);

        // Both panes are always children of one Stack, in a fixed order, so
        // moving or hiding either keeps its State.
        return Stack(
          fit: StackFit.expand,
          children: [
            PositionedDirectional(
              key: const ValueKey('split-main'),
              top: 0,
              bottom: 0,
              start: leading && !hidden ? side + _line : 0,
              end: !leading && !hidden ? side + _line : 0,
              child: widget.main,
            ),
            PositionedDirectional(
              key: const ValueKey('split-side'),
              top: 0,
              bottom: 0,
              start: leading ? 0 : null,
              end: leading ? null : 0,
              width: hidden ? 0 : side,
              child: ExcludeFocus(
                excluding: hidden,
                child: Visibility(
                  visible: !hidden,
                  maintainState: true,
                  child: OverflowBox(
                    alignment: leading
                        ? AlignmentDirectional.centerStart
                        : AlignmentDirectional.centerEnd,
                    minWidth: side,
                    maxWidth: side,
                    child: SizedBox(width: side, child: widget.side),
                  ),
                ),
              ),
            ),
            if (hidden)
              _RevealTab(
                key: const ValueKey('split-reveal'),
                leading: leading,
                label: widget.sideLabel,
                onPressed: () => _layout.setFlag(
                  '${widget.storageKey}.hidden',
                  false,
                ),
              )
            else
              PositionedDirectional(
                key: const ValueKey('split-handle'),
                top: 0,
                bottom: 0,
                start: leading
                    ? side + _line / 2 - _grab / 2
                    : total - side - _line / 2 - _grab / 2,
                width: _grab,
                child: _Seam(
                  label: widget.sideLabel,
                  value: side,
                  sideLeading: leading,
                  onDragStart: () => _dragWidth = _sideWidth(total),
                  onDrag: (dx) {
                    _dragWidth += leading ? dx : -dx;
                    _setWidth(total, _dragWidth);
                  },
                  onDragEnd: () => _layout.save(),
                  onNudge: (delta) => _setWidth(
                    total,
                    _sideWidth(total) + delta,
                    save: true,
                  ),
                  onReset: () => _layout.setWidth(_widthKey, null),
                ),
              ),
            if (!hidden && (widget.swappable || widget.collapsible))
              PositionedDirectional(
                key: const ValueKey('split-actions'),
                top: 0,
                bottom: 0,
                start: leading
                    ? side + _line / 2 - _SeamButton.size / 2
                    : total - side - _line / 2 - _SeamButton.size / 2,
                width: _SeamButton.size,
                child: Center(
                  child: _SeamActions(
                    sideLeading: leading,
                    label: widget.sideLabel,
                    onHide: widget.collapsible
                        ? () => _layout.setFlag(
                            '${widget.storageKey}.hidden',
                            true,
                          )
                        : null,
                    onSwap: widget.swappable
                        ? () => _layout.setFlag(
                            '${widget.storageKey}.swapped',
                            !swapped,
                          )
                        : null,
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// The handle on the line between two panes: a hairline with a grip pill
/// centered vertically on it.
class _Seam extends StatefulWidget {
  const _Seam({
    required this.label,
    required this.value,
    required this.sideLeading,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    required this.onNudge,
    required this.onReset,
  });

  final String label;
  final double value;

  /// Whether the side pane is on the leading edge of the handle.
  final bool sideLeading;
  final VoidCallback onDragStart;

  /// Logical-pixel movement to the right since the last call.
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  /// A keyboard step: positive widens the side pane.
  final ValueChanged<double> onNudge;
  final VoidCallback onReset;

  @override
  State<_Seam> createState() => _SeamState();
}

class _SeamState extends State<_Seam> {
  bool _hover = false;
  bool _dragging = false;
  bool _focused = false;

  bool get _active => _hover || _dragging || _focused;

  /// +1 when the text direction runs left to right, -1 otherwise.
  double _sign(BuildContext context) =>
      Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final sign = _sign(context);
    final towardTrailing = event.logicalKey == LogicalKeyboardKey.arrowRight
        ? sign
        : event.logicalKey == LogicalKeyboardKey.arrowLeft
        ? -sign
        : 0.0;
    if (towardTrailing == 0) return KeyEventResult.ignored;
    // Moving the line toward the trailing edge widens a leading pane and
    // narrows a trailing one.
    final widen = widget.sideLeading ? towardTrailing : -towardTrailing;
    widget.onNudge(widen * _SplitPaneState._keyStep);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sign = _sign(context);
    return Semantics(
      container: true,
      label: 'Resize ${widget.label}',
      value: '${widget.value.round()}',
      increasedValue: '${(widget.value + _SplitPaneState._keyStep).round()}',
      decreasedValue: '${(widget.value - _SplitPaneState._keyStep).round()}',
      onIncrease: () => widget.onNudge(_SplitPaneState._keyStep),
      onDecrease: () => widget.onNudge(-_SplitPaneState._keyStep),
      child: Focus(
        onKeyEvent: _onKey,
        onFocusChange: (value) => setState(() => _focused = value),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // The line follows the pointer from the first pixel, not from
            // after the drag slop.
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (_) {
              setState(() => _dragging = true);
              widget.onDragStart();
            },
            onHorizontalDragUpdate: (details) =>
                widget.onDrag(details.delta.dx * sign),
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              widget.onDragEnd();
            },
            onHorizontalDragCancel: () {
              if (!_dragging) return;
              setState(() => _dragging = false);
              widget.onDragEnd();
            },
            onDoubleTap: widget.onReset,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // The line itself: a hairline at rest, accented when held.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: _active ? 3 : 1,
                  color: _active
                      ? scheme.primary.withValues(alpha: _dragging ? .9 : .6)
                      : scheme.outlineVariant.withValues(alpha: .5),
                ),
                // The grip, dead center on the line.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 5,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: _active
                        ? scheme.primary
                        : scheme.onSurfaceVariant.withValues(alpha: .38),
                    border: Border.all(
                      color: scheme.surface.withValues(alpha: .9),
                      width: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small round button that rides on the handle.
class _SeamButton extends StatelessWidget {
  static const double size = 24;

  const _SeamButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: CircleBorder(side: BorderSide(color: scheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// The hide and swap buttons, stacked above and below the grip so the grip
/// itself stays centered on the line.
class _SeamActions extends StatelessWidget {
  const _SeamActions({
    required this.sideLeading,
    required this.label,
    this.onHide,
    this.onSwap,
  });

  final bool sideLeading;
  final String label;
  final VoidCallback? onHide;
  final VoidCallback? onSwap;

  /// Distance from the line's middle to a button's middle: clear of the grip.
  static const double _offset = 44;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final hide = onHide;
    final swap = onSwap;
    return SizedBox(
      width: _SeamButton.size,
      height: _offset * 2 + _SeamButton.size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (hide != null)
            Positioned(
              top: 0,
              child: _SeamButton(
                key: const ValueKey('split-hide'),
                tooltip: 'Hide $label',
                // Points the way the pane goes: toward its own edge.
                icon: sideLeading == !rtl
                    ? Icons.chevron_left_rounded
                    : Icons.chevron_right_rounded,
                onPressed: hide,
              ),
            ),
          if (swap != null)
            Positioned(
              bottom: 0,
              child: _SeamButton(
                key: const ValueKey('split-swap'),
                tooltip: 'Swap sides',
                icon: Icons.swap_horiz_rounded,
                onPressed: swap,
              ),
            ),
        ],
      ),
    );
  }
}

/// What stays at the edge when the side pane is hidden: a small tab,
/// centered vertically where the handle was, that brings the pane back.
class _RevealTab extends StatelessWidget {
  const _RevealTab({
    super.key,
    required this.leading,
    required this.label,
    required this.onPressed,
  });

  final bool leading;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // The tab hangs off the edge the pane left from.
    final radius = const Radius.circular(12);
    final shape = RoundedRectangleBorder(
      side: BorderSide(color: scheme.outlineVariant),
      borderRadius: BorderRadiusDirectional.only(
        topEnd: leading ? radius : Radius.zero,
        bottomEnd: leading ? radius : Radius.zero,
        topStart: leading ? Radius.zero : radius,
        bottomStart: leading ? Radius.zero : radius,
      ),
    );
    return PositionedDirectional(
      top: 0,
      bottom: 0,
      start: leading ? 0 : null,
      end: leading ? null : 0,
      child: Center(
        child: Tooltip(
          message: 'Show $label',
          child: Material(
            color: scheme.surfaceContainerHigh,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('split-show'),
              onTap: onPressed,
              child: SizedBox(
                width: 20,
                height: 56,
                child: Icon(
                  // Points the way the pane will come back from.
                  leading == !rtl
                      ? Icons.chevron_right_rounded
                      : Icons.chevron_left_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
