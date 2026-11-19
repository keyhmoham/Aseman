import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/desk_board.dart';
import '../domain/desk_models.dart';
import 'board/board_geometry.dart';
import 'board/board_item_view.dart';
import 'board/board_painter.dart';
import 'board/board_toolbar.dart';
import 'card_window.dart';
import 'desk_controller.dart';

/// A desk pane at least as wide as a small tablet (600 logical pixels) shows
/// its windows as a free whiteboard rather than the grid of widgets.
const double freeDeskWidth = 600;

/// Where the world's origin sits inside the (large) box the canvas lays its
/// things out in, so that things at negative coordinates can still be hit.
const double _origin = 30000;

/// Room under the things for the bar of tools when the view is fitted.
const double _bottomBand = 84;

const double _minScale = .25, _maxScale = 3;

enum _Mode { none, pan, marquee, move, shape, arrow, pen }

/// The room's desk as a free whiteboard: its windows (tools' frontends, the
/// mini-apps) are cards that can be dragged and resized anywhere on an
/// endless canvas that pans and zooms, and beside them people and agents put
/// note cards, shapes, free text, arrows and pen drawings. Arrows stick to
/// notes, shapes, text and windows and follow them. Everything is kept on
/// the node, so agents (board_add, board_update, board_mindmap, desk_arrange)
/// and people work on the same board.
class FreeDesk extends StatefulWidget {
  const FreeDesk({
    super.key,
    required this.controller,
    required this.windowContent,
    required this.pinPreview,
    this.emptyState,
    this.topInset = 0,
  });

  final DeskController controller;

  /// A window's frontend.
  final Widget Function(BuildContext context, DeskWindow window) windowContent;

  /// A pinned window's frontend, for its preview.
  final Widget Function(DeskPin pin) pinPreview;

  /// Shown on an empty desk.
  final Widget? emptyState;

  /// Room at the top for something drawn over the desk.
  final double topInset;

  @override
  State<FreeDesk> createState() => _FreeDeskState();
}

class _FreeDeskState extends State<FreeDesk>
    with SingleTickerProviderStateMixin {
  DeskController get c => widget.controller;

  // The view.
  late Offset _pan = Offset(0, widget.topInset);
  double _scale = 1;
  Size _viewport = Size.zero;
  late final AnimationController _glide;
  Tween<Offset>? _panTween;
  Tween<double>? _scaleTween;

  // Tools and selection.
  BoardTool _tool = BoardTool.select;
  String _shape = 'rect';
  String? _color;
  final Set<String> _selected = {};
  String? _editing;

  // Things being dragged or resized, ahead of the node.
  final Map<String, DeskItem> _live = {};
  final Map<String, Rect> _liveWindows = {};

  // The pointer gesture on the canvas itself.
  _Mode _mode = _Mode.none;
  Offset _anchor = Offset.zero;
  Offset _cursorAt = Offset.zero;
  double _startScale = 1;
  Offset _focalWorld = Offset.zero;
  List<Offset> _pen = [];
  DeskEnd? _arrowFrom;
  Rect? _snap;
  Map<String, DeskItem> _moveBase = {};
  Offset _moveDelta = Offset.zero;

  // A handle being dragged.
  Rect _resizeBase = Rect.zero;
  Offset _resizeAcc = Offset.zero;
  Offset _endBase = Offset.zero;

  /// Where the last pointer went down: a drawing starts there, not where
  /// the drag slop ended.
  Offset _downAt = Offset.zero;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapPos = Offset.zero;

  // What this screen has seen, to point out what others add out of sight.
  Set<String> _known = {};
  final Set<String> _madeHere = {};
  bool _settled = false;
  bool _offscreenNew = false;

  final FocusNode _keys = FocusNode(debugLabel: 'free desk');

  @override
  void initState() {
    super.initState();
    _glide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(_glideStep);
    if (c.loaded) {
      _settled = true;
      _known = _ids();
    }
    c.addListener(_changed);
  }

  @override
  void didUpdateWidget(FreeDesk old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _known = _ids();
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _glide.dispose();
    _keys.dispose();
    super.dispose();
  }

  Set<String> _ids() => {
    for (final w in c.state.windows) w.id,
    for (final i in c.state.items) i.id,
  };

  void _changed() {
    if (!mounted) return;
    final now = _ids();
    if (!c.loaded) {
      _known = now;
      _settled = false;
    } else if (!_settled) {
      _settled = true;
      _known = now;
    } else {
      final fresh = now.difference(_known).difference(_madeHere);
      if (fresh.isNotEmpty && _viewport != Size.zero) {
        final view = _visibleWorld();
        final seen = [
          for (final w in c.state.windows)
            if (fresh.contains(w.id)) w.rect,
          for (final i in c.state.items)
            if (fresh.contains(i.id) && i.isBox) i.rect,
        ];
        if (seen.any((r) => !view.overlaps(r))) _offscreenNew = true;
      }
      _known = now;
    }
    _selected.removeWhere((id) => c.itemById(id) == null);
    if (_editing != null && c.itemById(_editing!) == null) _editing = null;
    setState(() {});
  }

  // --- coordinates -----------------------------------------------------------

  Offset _toWorld(Offset screen) => (screen - _pan) / _scale;
  Offset _toScreen(Offset world) => world * _scale + _pan;
  Rect _toScreenRect(Rect r) =>
      Rect.fromPoints(_toScreen(r.topLeft), _toScreen(r.bottomRight));

  Rect _visibleWorld() => Rect.fromPoints(
    _toWorld(Offset.zero),
    _toWorld(Offset(_viewport.width, _viewport.height - _bottomBand)),
  );

  void _glideStep() {
    final p = _panTween, s = _scaleTween;
    if (p == null || s == null) return;
    final t = Curves.easeInOutCubic.transform(_glide.value);
    setState(() {
      _pan = p.transform(t);
      _scale = s.transform(t);
    });
  }

  void _glideTo(Offset pan, double scale) {
    _panTween = Tween(begin: _pan, end: pan);
    _scaleTween = Tween(begin: _scale, end: scale);
    _glide.forward(from: 0);
  }

  /// Zooms by [factor] about the screen point [about].
  void _zoomAt(double factor, Offset about) {
    final next = (_scale * factor).clamp(_minScale, _maxScale).toDouble();
    final world = _toWorld(about);
    setState(() {
      _scale = next;
      _pan = about - world * next;
    });
  }

  void _zoomBy(double factor) => _zoomAt(
    factor,
    Offset(_viewport.width / 2, (_viewport.height - _bottomBand) / 2),
  );

  /// Shows everything: the cards, the notes and the rest.
  void _fit() {
    final rects = [
      for (final w in c.state.windows)
        if (!c.isMinimized(w.id)) _windowRect(w),
      for (final i in _items) ?_boundsOf(i),
    ];
    final all = boundsOf(rects);
    _offscreenNew = false;
    if (all == null) {
      _glideTo(Offset(0, widget.topInset), 1);
      return;
    }
    const pad = 48.0;
    final area = Size(
      math.max(120, _viewport.width - pad * 2),
      math.max(120, _viewport.height - widget.topInset - _bottomBand - pad),
    );
    final scale = math
        .min(1.0, math.min(area.width / all.width, area.height / all.height))
        .clamp(_minScale, _maxScale)
        .toDouble();
    final pan = Offset(
      _viewport.width / 2 - all.center.dx * scale,
      widget.topInset + (_viewport.height - widget.topInset - _bottomBand) / 2 -
          all.center.dy * scale,
    );
    _glideTo(pan, scale);
  }

  void _reveal(Rect r) {
    final pan = Offset(
      _viewport.width / 2 - r.center.dx * _scale,
      widget.topInset +
          (_viewport.height - widget.topInset - _bottomBand) / 2 -
          r.center.dy * _scale,
    );
    _glideTo(pan, _scale);
  }

  // --- what is on the board ---------------------------------------------------

  List<DeskItem> get _items => [
    for (final i in c.state.items) _live[i.id] ?? i,
  ];

  Rect _windowRect(DeskWindow w) => _liveWindows[w.id] ?? w.rect;

  Rect? _boundsOf(DeskItem i) {
    if (i.isArrow) return _arrowOf(i)?.path.getBounds();
    return i.rect;
  }

  BoardTarget? _target(String ref) {
    final item = _live[ref] ?? c.itemById(ref);
    if (item != null) {
      return item.isBox
          ? BoardTarget(item.rect, shape: item.isShape ? item.shape : 'rect')
          : null;
    }
    final w = c.state.windows.where((w) => w.id == ref).firstOrNull;
    return w == null ? null : BoardTarget(_windowRect(w));
  }

  ArrowShape? _arrowOf(DeskItem a) => arrowShape(a, _target);

  /// The box or window under [p], front-most first, as an arrow end.
  ({String ref, Rect rect})? _boxAt(Offset p) {
    final stack = <(int, String, Rect)>[
      for (final i in _items)
        if (i.isBox) (i.z, i.id, i.rect),
      for (final w in c.state.windows)
        if (!c.isMinimized(w.id)) (w.z, w.id, _windowRect(w)),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    for (final e in stack) {
      if (e.$3.inflate(2).contains(p)) return (ref: e.$2, rect: e.$3);
    }
    return null;
  }

  /// The arrow or stroke closest to [p] (within a few pixels), if any.
  DeskItem? _lineAt(Offset p) {
    final reach = 8 / _scale;
    final lines = [
      for (final i in _items)
        if (i.isArrow || i.isStroke) i,
    ]..sort((a, b) => b.z.compareTo(a.z));
    for (final i in lines) {
      final d = i.isArrow
          ? _arrowOf(i)?.distanceTo(p) ?? double.infinity
          : distanceToPolyline(p, i.points);
      if (d <= reach + (i.width > 0 ? i.width / 2 : 1.5)) return i;
    }
    return null;
  }

  // --- tools -----------------------------------------------------------------

  String _colorFor(String kind) =>
      _color ??
      switch (kind) {
        DeskItemKind.note => 'yellow',
        DeskItemKind.shape => 'blue',
        DeskItemKind.arrow => 'gray',
        _ => 'black',
      };

  void _setTool(BoardTool t) {
    if (_editing != null) return;
    setState(() {
      _tool = t;
      if (t != BoardTool.select) _selected.clear();
    });
  }

  void _after(String id) {
    _madeHere.add(id);
    setState(() {
      _tool = BoardTool.select;
      _selected
        ..clear()
        ..add(id);
    });
  }

  void _makeNote(Offset p) {
    final id = c.addItem(
      DeskItem(
        id: '',
        kind: DeskItemKind.note,
        rect: Rect.fromCenter(center: p, width: 200, height: 140),
        color: _colorFor(DeskItemKind.note),
      ),
    );
    _after(id);
    setState(() => _editing = id);
  }

  void _makeText(Offset p) {
    final id = c.addItem(
      DeskItem(
        id: '',
        kind: DeskItemKind.text,
        rect: Rect.fromLTWH(p.dx - 20, p.dy - 14, 200, 32),
        text: 'Text',
        color: _colorFor(DeskItemKind.text),
      ),
    );
    _after(id);
    setState(() => _editing = id);
  }

  void _makeShape(Rect r) {
    final id = c.addItem(
      DeskItem(
        id: '',
        kind: DeskItemKind.shape,
        rect: r,
        shape: _shape,
        fill: 'soft',
        color: _colorFor(DeskItemKind.shape),
      ),
    );
    _after(id);
  }

  void _makeArrow(DeskEnd from, DeskEnd to) {
    final id = c.addItem(
      DeskItem(
        id: '',
        kind: DeskItemKind.arrow,
        from: from,
        to: to,
        head: 'arrow',
        tail: 'none',
        dash: 'solid',
        path: 'straight',
        width: 2,
        color: _colorFor(DeskItemKind.arrow),
      ),
    );
    _after(id);
  }

  void _makeStroke(List<Offset> points) {
    final pts = thinStroke(points);
    if (pts.length < 2) return;
    final id = c.addItem(
      DeskItem(
        id: '',
        kind: DeskItemKind.stroke,
        rect: boundsOf([for (final p in pts) Rect.fromPoints(p, p)])!,
        points: pts,
        color: _colorFor(DeskItemKind.stroke),
        width: 3,
      ),
    );
    _madeHere.add(id);
  }

  // --- the canvas gestures ----------------------------------------------------

  void _beginPan(Offset focal) {
    _mode = _Mode.pan;
    _startScale = _scale;
    _focalWorld = _toWorld(focal);
  }

  void _onScaleStart(ScaleStartDetails d) {
    if (_editing != null) {
      _keys.requestFocus(); // ends the edit; the words are kept
      return;
    }
    _glide.stop();
    _anchor = _cursorAt = _toWorld(
      d.pointerCount == 1 ? _downAt : d.localFocalPoint,
    );
    if (d.pointerCount > 1 || _tool == BoardTool.hand) {
      _beginPan(d.localFocalPoint);
      return;
    }
    switch (_tool) {
      case BoardTool.select:
        final hit = _lineAt(_anchor);
        if (hit != null) {
          if (!_selected.contains(hit.id)) {
            setState(() {
              if (!HardwareKeyboard.instance.isShiftPressed) _selected.clear();
              _selected.add(hit.id);
            });
          }
          _beginMove();
        } else {
          _mode = _Mode.marquee;
          if (!HardwareKeyboard.instance.isShiftPressed) {
            setState(_selected.clear);
          }
        }
      case BoardTool.shape:
        _mode = _Mode.shape;
      case BoardTool.arrow:
        _mode = _Mode.arrow;
        final box = _boxAt(_anchor);
        _arrowFrom = box == null
            ? DeskEnd(point: _anchor)
            : DeskEnd(ref: box.ref);
        _snap = box?.rect;
      case BoardTool.pen:
        _mode = _Mode.pen;
        _pen = [_anchor];
      default:
        _mode = _Mode.none;
    }
    setState(() {});
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_editing != null) return;
    if (d.pointerCount > 1 && _mode != _Mode.pan) {
      _startScale = _scale / (d.scale == 0 ? 1 : d.scale);
      _mode = _Mode.pan;
      _focalWorld = _toWorld(d.localFocalPoint);
    }
    final here = _toWorld(d.localFocalPoint);
    switch (_mode) {
      case _Mode.pan:
        final next = (_startScale * d.scale)
            .clamp(_minScale, _maxScale)
            .toDouble();
        setState(() {
          _scale = next;
          _pan = d.localFocalPoint - _focalWorld * next;
        });
      case _Mode.marquee:
        setState(() => _cursorAt = here);
      case _Mode.move:
        _moveDelta = here - _anchor;
        setState(() {
          for (final e in _moveBase.entries) {
            _live[e.key] = e.value.shifted(_moveDelta);
          }
        });
      case _Mode.shape:
        setState(() => _cursorAt = here);
      case _Mode.arrow:
        final box = _boxAt(here);
        setState(() {
          _cursorAt = here;
          _snap = box?.rect;
        });
      case _Mode.pen:
        if ((here - _pen.last).distance * _scale >= 2) {
          setState(() {
            _pen.add(here);
            _cursorAt = here;
          });
        }
      case _Mode.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final mode = _mode;
    _mode = _Mode.none;
    switch (mode) {
      case _Mode.marquee:
        final m = Rect.fromPoints(_anchor, _cursorAt);
        if (m.width > 3 || m.height > 3) {
          setState(() {
            for (final i in _items) {
              final r = _boundsOf(i);
              if (r != null && r.overlaps(m)) _selected.add(i.id);
            }
          });
        }
      case _Mode.move:
        _endMove();
      case _Mode.shape:
        final r = Rect.fromPoints(_anchor, _cursorAt);
        if (r.width >= 24 && r.height >= 24) _makeShape(r);
      case _Mode.arrow:
        final from = _arrowFrom;
        final box = _boxAt(_cursorAt);
        final to = box == null
            ? DeskEnd(point: _cursorAt)
            : DeskEnd(ref: box.ref);
        if (from != null &&
            (_cursorAt - _anchor).distance > 12 &&
            !(from.stuck && from.ref == to.ref)) {
          _makeArrow(from, to);
        }
      case _Mode.pen:
        _makeStroke(_pen);
      case _Mode.pan:
      case _Mode.none:
        break;
    }
    setState(() {
      _pen = [];
      _snap = null;
      _arrowFrom = null;
    });
  }

  void _onBgTap(TapUpDetails d) {
    if (_editing != null) {
      _keys.requestFocus(); // ends the edit; the words are kept
      return;
    }
    final p = _toWorld(d.localPosition);
    // A second tap close to the first, soon after: a double click. (Not a
    // double-tap recognizer: it would make every single tap wait for it.)
    final now = DateTime.now();
    final double_ =
        _tool == BoardTool.select &&
        now.difference(_lastTapAt) < const Duration(milliseconds: 350) &&
        (d.localPosition - _lastTapPos).distance < 24;
    _lastTapAt = now;
    _lastTapPos = d.localPosition;
    if (double_) {
      _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);
      _onBgDoubleTap(p);
      return;
    }
    switch (_tool) {
      case BoardTool.select:
        final hit = _lineAt(p);
        setState(() {
          if (HardwareKeyboard.instance.isShiftPressed && hit != null) {
            _selected.contains(hit.id)
                ? _selected.remove(hit.id)
                : _selected.add(hit.id);
          } else {
            _selected
              ..clear()
              ..addAll([?hit?.id]);
          }
        });
      case BoardTool.note:
        _makeNote(p);
      case BoardTool.text:
        _makeText(p);
      case BoardTool.shape:
        _makeShape(Rect.fromCenter(center: p, width: 160, height: 100));
      default:
        break;
    }
  }

  void _onBgDoubleTap(Offset p) {
    if (_tool != BoardTool.select || _editing != null) return;
    final line = _lineAt(p);
    if (line != null && line.isArrow) {
      unawaited(_editLabel(line));
      return;
    }
    if (line == null) _makeNote(p);
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final s = event as PointerScrollEvent;
      final zoom =
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (zoom) {
        _zoomAt(math.exp(-s.scrollDelta.dy / 320), s.localPosition);
      } else {
        final shift = HardwareKeyboard.instance.isShiftPressed;
        setState(
          () => _pan -= shift
              ? Offset(s.scrollDelta.dy, 0)
              : s.scrollDelta,
        );
      }
    });
  }

  MouseCursor get _cursor => switch (_tool) {
    BoardTool.hand =>
      _mode == _Mode.pan ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
    BoardTool.select => SystemMouseCursors.basic,
    _ => SystemMouseCursors.precise,
  };

  // --- moving things -----------------------------------------------------------

  void _beginMove() {
    _moveBase = {
      for (final id in _selected)
        if (c.itemById(id) case final DeskItem i) id: i,
    };
    if (_moveBase.isEmpty) return;
    _moveDelta = Offset.zero;
    _mode = _Mode.move;
    c.beginInteraction();
  }

  void _endMove() {
    // A pan that never started (a plain tap) ends nothing.
    if (_moveBase.isEmpty) return;
    _mode = _Mode.none;
    c.endInteraction();
    final next = {..._live};
    _live.clear();
    if (_moveDelta.distance > 0) unawaited(c.updateItems(next));
    _moveBase = {};
    if (mounted) setState(() {});
  }

  void _itemDragStart(DeskItem it) {
    if (!_selected.contains(it.id)) {
      setState(() {
        if (!HardwareKeyboard.instance.isShiftPressed) _selected.clear();
        _selected.add(it.id);
      });
    }
    _anchor = Offset.zero;
    _beginMove();
  }

  void _itemDragUpdate(Offset worldDelta) {
    _moveDelta += worldDelta;
    setState(() {
      for (final e in _moveBase.entries) {
        _live[e.key] = e.value.shifted(_moveDelta);
      }
    });
  }

  void _tapItem(DeskItem it) {
    if (_editing != null && _editing != it.id) return;
    setState(() {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _selected.contains(it.id)
            ? _selected.remove(it.id)
            : _selected.add(it.id);
      } else {
        _selected
          ..clear()
          ..add(it.id);
      }
    });
    unawaited(c.frontItem(it.id));
  }

  Future<void> _finishEdit(String id, String text) async {
    final it = c.itemById(id);
    setState(() => _editing = null);
    if (it == null) return;
    if (it.isText && text.trim().isEmpty) {
      await c.removeItems([id]);
      return;
    }
    if (text == it.text) return;
    var rect = it.rect;
    if (it.isText) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: boardFontSize(it), height: 1.3),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width);
      rect = Rect.fromLTWH(rect.left, rect.top, rect.width, tp.height + 4);
    }
    await c.updateItem(it.copyWith(text: text, rect: rect));
  }

  Future<void> _editLabel(DeskItem arrow) async {
    final controller = TextEditingController(text: arrow.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Arrow label'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'What the arrow means'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted) return;
    final cur = c.itemById(arrow.id);
    if (cur != null && cur.text != text) await c.updateItem(cur.copyWith(text: text));
  }

  // --- selection actions -------------------------------------------------------

  List<DeskItem> get _selection => [
    for (final id in _selected)
      if (c.itemById(id) != null) _live[id] ?? c.itemById(id)!,
  ];

  void _change(DeskItem Function(DeskItem) f) {
    final next = {for (final i in _selection) i.id: f(i)};
    unawaited(c.updateItems(next));
  }

  void _delete() {
    if (_selected.isEmpty) return;
    final ids = [..._selected];
    setState(_selected.clear);
    unawaited(c.removeItems(ids));
  }

  void _duplicate() {
    final copies = [
      for (final i in _selection)
        if (!i.isArrow) i.shifted(const Offset(24, 24)),
    ];
    if (copies.isEmpty) return;
    final ids = c.addItems(copies);
    _madeHere.addAll(ids);
    setState(() {
      _selected
        ..clear()
        ..addAll(ids);
    });
  }

  void _front() {
    for (final id in _selected) {
      unawaited(c.frontItem(id));
    }
  }

  // --- keys --------------------------------------------------------------------

  bool get _typing {
    final focus = FocusManager.instance.primaryFocus;
    return _editing != null ||
        (focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
            null) ||
        focus?.context?.widget is EditableText;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _typing) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (ctrl) {
      if (key == LogicalKeyboardKey.keyZ) {
        unawaited(shift ? c.redo() : c.undo());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        unawaited(c.redo());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyD) {
        _duplicate();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyA) {
        setState(() => _selected.addAll([for (final i in _items) i.id]));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (_selected.isEmpty) return KeyEventResult.ignored;
      _delete();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _selected.clear();
        _tool = BoardTool.select;
      });
      return KeyEventResult.handled;
    }
    final label = key.keyLabel.toUpperCase();
    for (final t in BoardTool.values) {
      if (t.key == label) {
        _setTool(t);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // --- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        _viewport = box.biggest;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => c.reportViewport(box.biggest, free: true),
        );
        final items = _items;
        final windows = [
          for (final w in c.state.windows)
            if (!c.isMinimized(w.id)) w,
        ];
        final arrows = [
          for (final i in items)
            if (i.isArrow) i,
        ]..sort((a, b) => a.z.compareTo(b.z));
        final strokes = [
          for (final i in items)
            if (i.isStroke) i,
        ]..sort((a, b) => a.z.compareTo(b.z));
        final empty = windows.isEmpty && items.isEmpty;
        final preview = _preview();
        final topWindow = windows.isEmpty
            ? 0
            : windows.map((w) => w.z).reduce(math.max);
        return Focus(
          focusNode: _keys,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: _onSignal,
            onPointerDown: (e) {
              _downAt = e.localPosition;
              if (_editing == null) _keys.requestFocus();
            },
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: MouseRegion(
                      cursor: _cursor,
                      child: GestureDetector(
                        key: const ValueKey('board-canvas'),
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        onScaleEnd: _onScaleEnd,
                        onTapUp: _onBgTap,
                        child: CustomPaint(
                          painter: BoardGridPainter(
                            pan: _pan,
                            scale: _scale,
                            color: scheme.onSurface.withValues(alpha: .13),
                          ),
                          child: empty && widget.emptyState != null
                              ? Padding(
                                  padding: EdgeInsets.only(
                                    top: widget.topInset,
                                    bottom: _bottomBand,
                                  ),
                                  child: widget.emptyState,
                                )
                              : const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: BoardLinesPainter(
                          arrows: arrows,
                          resolve: _target,
                          scheme: scheme,
                          selected: _selected,
                          pan: _pan,
                          scale: _scale,
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: _tool != BoardTool.select,
                      child: _world(items, windows, topWindow),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: BoardInkPainter(
                          strokes: strokes,
                          preview: preview,
                          scheme: scheme,
                          selected: _selected,
                          pan: _pan,
                          scale: _scale,
                        ),
                      ),
                    ),
                  ),
                  ..._chrome(scheme),
                  _bars(context, windows),
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
            ),
          ),
        );
      },
    );
  }

  BoardPreview? _preview() {
    switch (_mode) {
      case _Mode.marquee:
        return BoardPreview(marquee: Rect.fromPoints(_anchor, _cursorAt));
      case _Mode.shape:
        return BoardPreview(
          shapeRect: Rect.fromPoints(_anchor, _cursorAt),
          shapeKind: _shape,
          color: _colorFor(DeskItemKind.shape),
        );
      case _Mode.arrow:
        final from = _arrowFrom;
        if (from == null) return null;
        final start = c.endPoint(from) ?? _anchor;
        return BoardPreview(
          arrowFrom: start,
          arrowTo: _cursorAt,
          snap: _snap,
          color: _colorFor(DeskItemKind.arrow),
        );
      case _Mode.pen:
        return BoardPreview(
          penPoints: _pen,
          color: _colorFor(DeskItemKind.stroke),
        );
      default:
        return null;
    }
  }

  /// The boxes and windows, laid out in world coordinates under one transform.
  Widget _world(List<DeskItem> items, List<DeskWindow> windows, int topWindow) {
    final entries = <(int, Widget)>[
      for (final i in items)
        if (i.isBox) (i.z, _boxItem(i)),
      for (final w in windows) (w.z, _window(w, w.z == topWindow)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: 0,
      minHeight: 0,
      maxWidth: _origin * 2,
      maxHeight: _origin * 2,
      child: Transform(
        transform: Matrix4.identity()
          ..translateByDouble(
            _pan.dx - _origin * _scale,
            _pan.dy - _origin * _scale,
            0,
            1,
          )
          ..scaleByDouble(_scale, _scale, 1, 1),
        child: SizedBox(
          width: _origin * 2,
          height: _origin * 2,
          child: Stack(
            clipBehavior: Clip.none,
            children: [for (final e in entries) e.$2],
          ),
        ),
      ),
    );
  }

  Widget _boxItem(DeskItem it) {
    final editing = _editing == it.id;
    final view = BoardItemView(
      key: ValueKey('view-${it.id}'),
      item: it,
      editing: editing,
      onEditDone: (t) => unawaited(_finishEdit(it.id, t)),
    );
    return Positioned(
      key: ValueKey('item-${it.id}'),
      left: it.rect.left + _origin,
      top: it.rect.top + _origin,
      width: it.rect.width,
      height: it.rect.height,
      child: editing
          ? view
          // Selecting takes the pointer-down itself: a gesture detector that
          // also listens for a double tap would wait out the double-tap time.
          : Listener(
              onPointerDown: (_) => _tapItem(it),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Follows the pointer from the first pixel, not after the slop.
                  dragStartBehavior: DragStartBehavior.down,
                  onDoubleTap: it.editable
                      ? () => setState(() {
                          _selected
                            ..clear()
                            ..add(it.id);
                          _editing = it.id;
                        })
                      : null,
                  onPanStart: (_) => _itemDragStart(it),
                  onPanUpdate: (d) => _itemDragUpdate(d.delta),
                  onPanEnd: (_) => _endMove(),
                  onPanCancel: _endMove,
                  child: view,
                ),
              ),
            ),
    );
  }

  Widget _window(DeskWindow w, bool front) {
    final rect = _windowRect(w);
    return Positioned(
      key: ValueKey('window-${w.id}'),
      left: rect.left + _origin,
      top: rect.top + _origin,
      width: rect.width,
      height: rect.height,
      child: CardWindow(
        window: w,
        chromeOverlayTooltip: false,
        front: front,
        pinned: c.isPinned(w),
        showMaximize: false,
        onRaise: () => c.raise(w.id),
        onDragStart: () {
          c.beginInteraction();
          setState(() => _liveWindows[w.id] = rect);
        },
        onDrag: (d) => setState(() {
          _liveWindows[w.id] = (_liveWindows[w.id] ?? rect).shift(d);
        }),
        onDragEnd: () => unawaited(_commitWindow(w.id)),
        onResize: (d) => setState(() {
          final r = _liveWindows[w.id] ?? rect;
          _liveWindows[w.id] = Rect.fromLTWH(
            r.left,
            r.top,
            math.max(DeskGeometry.minW, r.width + d.dx),
            math.max(DeskGeometry.minH, r.height + d.dy),
          );
        }),
        onResizeEnd: () => unawaited(_commitWindow(w.id)),
        onClose: () => c.close(w.id),
        onPin: () => c.togglePin(w),
        onMinimize: () => c.minimize(w.id),
        child: KeyedSubtree(
          key: ValueKey('content-${w.id}'),
          child: widget.windowContent(context, w),
        ),
      ),
    );
  }

  Future<void> _commitWindow(String id) async {
    final r = _liveWindows[id];
    c.endInteraction();
    if (r == null) return;
    await c.move(
      id,
      Rect.fromLTWH(
        r.left.roundToDouble(),
        r.top.roundToDouble(),
        r.width.roundToDouble(),
        r.height.roundToDouble(),
      ),
    );
    if (mounted) setState(() => _liveWindows.remove(id));
  }

  // --- selection chrome (screen space) ----------------------------------------

  List<Widget> _chrome(ColorScheme scheme) {
    final sel = _selection;
    if (sel.isEmpty || _tool != BoardTool.select || _editing != null) {
      return const [];
    }
    final out = <Widget>[];
    Rect? union;
    for (final i in sel) {
      final r = _boundsOf(i);
      if (r == null) continue;
      final s = _toScreenRect(r);
      union = union == null ? s : union.expandToInclude(s);
      if (i.isBox || i.isStroke) {
        out.add(
          Positioned.fromRect(
            rect: s.inflate(3),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 1.5),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        );
      }
    }
    if (union == null) return out;
    if (sel.length == 1) {
      final one = sel.first;
      if (one.isBox) {
        out.addAll(_resizeHandles(one, scheme));
      } else if (one.isArrow) {
        out.addAll(_endHandles(one, scheme));
      }
    }
    final bar = Positioned(
      left: (union.center.dx - 180).clamp(8.0, math.max(8.0, _viewport.width - 368)),
      top: union.top - 54 < widget.topInset + 4
          ? math.min(union.bottom + 14, _viewport.height - _bottomBand - 50)
          : union.top - 54,
      child: BoardContextBar(
        items: sel,
        onChange: _change,
        onDelete: _delete,
        onDuplicate: _duplicate,
        onFront: _front,
        onLabel: () {
          if (sel.length == 1 && sel.first.isArrow) {
            unawaited(_editLabel(sel.first));
          }
        },
      ),
    );
    out.add(bar);
    return out;
  }

  List<Widget> _resizeHandles(DeskItem it, ColorScheme scheme) {
    final s = _toScreenRect(it.rect);
    final spots = <(Alignment, Offset, MouseCursor)>[
      (Alignment.topLeft, s.topLeft, SystemMouseCursors.resizeUpLeft),
      (Alignment.topCenter, s.topCenter, SystemMouseCursors.resizeUp),
      (Alignment.topRight, s.topRight, SystemMouseCursors.resizeUpRight),
      (Alignment.centerLeft, s.centerLeft, SystemMouseCursors.resizeLeft),
      (Alignment.centerRight, s.centerRight, SystemMouseCursors.resizeRight),
      (Alignment.bottomLeft, s.bottomLeft, SystemMouseCursors.resizeDownLeft),
      (Alignment.bottomCenter, s.bottomCenter, SystemMouseCursors.resizeDown),
      (Alignment.bottomRight, s.bottomRight, SystemMouseCursors.resizeDownRight),
    ];
    return [
      for (final (align, at, cursor) in spots)
        _handle(
          key: ValueKey('resize-${align.x.toInt()}-${align.y.toInt()}'),
          at: at,
          cursor: cursor,
          scheme: scheme,
          onStart: () {
            _resizeBase = it.rect;
            _resizeAcc = Offset.zero;
            c.beginInteraction();
          },
          onUpdate: (d) {
            _resizeAcc += d / _scale;
            setState(() => _live[it.id] = it.copyWith(rect: _resized(_resizeBase, align, _resizeAcc)));
          },
          onEnd: () {
            c.endInteraction();
            final next = _live.remove(it.id);
            if (next != null) unawaited(c.updateItem(next));
            setState(() {});
          },
        ),
    ];
  }

  /// [base] with the edges [align] names moved by [d].
  Rect _resized(Rect base, Alignment align, Offset d) {
    var l = base.left, t = base.top, r = base.right, b = base.bottom;
    if (align.x < 0) l = math.min(l + d.dx, r - 48);
    if (align.x > 0) r = math.max(r + d.dx, l + 48);
    if (align.y < 0) t = math.min(t + d.dy, b - 32);
    if (align.y > 0) b = math.max(b + d.dy, t + 32);
    return Rect.fromLTRB(l, t, r, b);
  }

  List<Widget> _endHandles(DeskItem arrow, ColorScheme scheme) {
    final shape = _arrowOf(arrow);
    if (shape == null) return const [];
    Widget end(bool isFrom, Offset at) {
      final base = _toScreen(at);
      return _handle(
        key: ValueKey(isFrom ? 'arrow-from' : 'arrow-to'),
        at: base,
        cursor: SystemMouseCursors.precise,
        scheme: scheme,
        round: true,
        onBegin: () {
          _resizeAcc = Offset.zero;
          _endBase = base;
        },
        onStart: c.beginInteraction,
        onUpdate: (d) {
          _resizeAcc += d;
          final p = _toWorld(_endBase + _resizeAcc);
          final box = _boxAt(p);
          final e = box != null && box.ref != arrow.id
              ? DeskEnd(ref: box.ref)
              : DeskEnd(point: p);
          final cur = _live[arrow.id] ?? arrow;
          setState(() {
            _snap = box?.rect;
            _live[arrow.id] = isFrom
                ? cur.copyWith(from: e)
                : cur.copyWith(to: e);
          });
        },
        onEnd: () {
          c.endInteraction();
          final next = _live.remove(arrow.id);
          _resizeAcc = Offset.zero;
          _snap = null;
          if (next != null) unawaited(c.updateItem(next));
          setState(() {});
        },
      );
    }

    return [end(true, shape.start), end(false, shape.end)];
  }

  Widget _handle({
    required Key key,
    required Offset at,
    required MouseCursor cursor,
    required ColorScheme scheme,
    required VoidCallback onStart,
    required ValueChanged<Offset> onUpdate,
    required VoidCallback onEnd,
    VoidCallback? onBegin,
    bool round = false,
  }) {
    const size = 14.0;
    return Positioned(
      key: key,
      left: at.dx - size,
      top: at.dy - size,
      width: size * 2,
      height: size * 2,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (_) {
            onBegin?.call();
            onStart();
          },
          onPanUpdate: (d) => onUpdate(d.delta),
          onPanEnd: (_) => onEnd(),
          onPanCancel: onEnd,
          child: Center(
            child: Container(
              width: size - 2,
              height: size - 2,
              decoration: BoxDecoration(
                color: scheme.surface,
                shape: round ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: round ? null : BorderRadius.circular(3),
                border: Border.all(color: scheme.primary, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- bars --------------------------------------------------------------------

  Widget _bars(BuildContext context, List<DeskWindow> windows) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Center(
              child: BoardToolbar(
                tool: _tool,
                onTool: _setTool,
                shape: _shape,
                onShape: (s) => setState(() => _shape = s),
                color: _color ?? 'gray',
                onColor: (v) => setState(() => _color = v),
                apps: _appsMenu(windows),
              ),
            ),
          ),
          Positioned(
            left: 12,
            bottom: 14,
            child: _pill(scheme, [
              BoardBarButton(
                key: const ValueKey('board-undo'),
                icon: Icons.undo_rounded,
                tooltip: 'Undo (Ctrl+Z)',
                onPressed: c.canUndo ? () => unawaited(c.undo()) : null,
              ),
              BoardBarButton(
                key: const ValueKey('board-redo'),
                icon: Icons.redo_rounded,
                tooltip: 'Redo (Ctrl+Shift+Z)',
                onPressed: c.canRedo ? () => unawaited(c.redo()) : null,
              ),
            ]),
          ),
          Positioned(
            right: 12,
            bottom: 14,
            child: _pill(scheme, [
              BoardBarButton(
                key: const ValueKey('board-zoom-out'),
                icon: Icons.remove_rounded,
                tooltip: 'Zoom out',
                onPressed: () => _zoomBy(1 / 1.25),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _glideTo(Offset(0, widget.topInset), 1),
                child: Tooltip(
                  message: 'Reset zoom',
                  child: SizedBox(
                    width: 44,
                    child: Text(
                      '${(_scale * 100).round()}%',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
              ),
              BoardBarButton(
                key: const ValueKey('board-zoom-in'),
                icon: Icons.add_rounded,
                tooltip: 'Zoom in',
                onPressed: () => _zoomBy(1.25),
              ),
              BoardBarButton(
                key: const ValueKey('board-fit'),
                icon: Icons.fit_screen_outlined,
                tooltip: 'Show everything',
                onPressed: _fit,
              ),
            ]),
          ),
          if (_offscreenNew)
            Positioned(
              top: widget.topInset + 10,
              left: 0,
              right: 0,
              child: Center(
                child: ActionChip(
                  key: const ValueKey('board-new-offscreen'),
                  avatar: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: const Text('New on the board, out of view · Show'),
                  onPressed: _fit,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pill(ColorScheme scheme, List<Widget> children) => Material(
    elevation: 2,
    color: scheme.surfaceContainerHigh,
    shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );

  /// The windows on the board: bring one into view, or back from minimized.
  Widget _appsMenu(List<DeskWindow> shown) {
    final all = c.state.windows;
    final pins = c.state.pins;
    return PopupMenuButton<Object>(
      key: const ValueKey('board-apps'),
      tooltip: 'Apps on this board',
      icon: Icon(
        Icons.widgets_outlined,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onSelected: (v) {
        if (v is DeskWindow) {
          c.restore(v.id);
          unawaited(c.raise(v.id));
          _reveal(_windowRect(v));
        } else if (v is DeskPin) {
          unawaited(c.openPin(v));
        }
      },
      itemBuilder: (_) => [
        if (all.isEmpty && pins.isEmpty)
          const PopupMenuItem<Object>(
            enabled: false,
            child: Text('No apps yet — ask an agent, or open one from the library'),
          ),
        for (final w in all)
          PopupMenuItem<Object>(
            value: w,
            child: Row(
              children: [
                Icon(
                  c.isMinimized(w.id)
                      ? Icons.web_asset_off_outlined
                      : Icons.web_asset_rounded,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    w.label.isEmpty ? 'Window' : w.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (pins.isNotEmpty) const PopupMenuDivider(),
        for (final p in pins)
          PopupMenuItem<Object>(
            value: p,
            child: Row(
              children: [
                const Icon(Icons.push_pin_outlined, size: 18),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Open ${p.label.isEmpty ? 'pinned app' : p.label}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
