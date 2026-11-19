import 'package:flutter/material.dart';

import '../../domain/desk_board.dart';
import 'board_painter.dart';
import 'board_palette.dart';

/// The type size a box item uses when it has none of its own.
double boardFontSize(DeskItem item) =>
    item.fontSize > 0 ? item.fontSize : (item.isText ? 18 : 15);

/// A note card, a shape or free text on the whiteboard, drawn at its own size
/// (the canvas places and scales it). With [editing] its words are a text field
/// in place; [onEditDone] hands back what was typed.
class BoardItemView extends StatefulWidget {
  const BoardItemView({
    super.key,
    required this.item,
    this.editing = false,
    this.onEditDone,
  });

  final DeskItem item;
  final bool editing;
  final ValueChanged<String>? onEditDone;

  @override
  State<BoardItemView> createState() => _BoardItemViewState();
}

class _BoardItemViewState extends State<BoardItemView> {
  late final TextEditingController _text = TextEditingController(
    text: widget.item.text,
  );
  final FocusNode _focus = FocusNode();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    if (widget.editing) _startEditing();
  }

  void _startEditing() {
    _done = false;
    _text.text = widget.item.text;
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _text.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.editing) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(BoardItemView old) {
    super.didUpdateWidget(old);
    if (widget.editing && !old.editing) _startEditing();
  }

  void _focusChanged() {
    if (!_focus.hasFocus && widget.editing) _finish();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    widget.onEditDone?.call(_text.text);
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  Widget _words(TextStyle style, TextAlign align) {
    if (widget.editing) {
      return Focus(
        onKeyEvent: (node, event) {
          // Escape ends the edit; the words are kept.
          if (event.logicalKey.keyLabel == 'Escape') {
            _finish();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: _text,
          focusNode: _focus,
          style: style,
          textAlign: align,
          maxLines: null,
          cursorColor: style.color,
          decoration: const InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
          ),
        ),
      );
    }
    return Text(
      widget.item.text,
      style: style,
      textAlign: align,
      overflow: TextOverflow.fade,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    final size = boardFontSize(item);
    switch (item.kind) {
      case DeskItemKind.note:
        final ink = BoardInk.of(scheme, item.color, fallback: 'yellow');
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ink.soft,
            borderRadius: BorderRadius.circular(6),
            border: Border(top: BorderSide(color: ink.strong, width: 4)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .16),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: _words(
            TextStyle(fontSize: size, height: 1.3, color: ink.text),
            TextAlign.start,
          ),
        );
      case DeskItemKind.shape:
        final ink = BoardInk.of(scheme, item.color, fallback: 'blue');
        final solid = item.fill == 'solid';
        return CustomPaint(
          painter: _ShapePainter(
            kind: item.shape.isEmpty ? 'rect' : item.shape,
            fill: item.fill == 'none'
                ? null
                : solid
                ? ink.strong
                : ink.soft,
            stroke: ink.strong,
            width: item.width > 0 ? item.width : 2,
          ),
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: item.shape == 'ellipse' || item.shape == 'diamond'
                    ? item.rect.width * .16
                    : 10,
                vertical: 6,
              ),
              child: _words(
                TextStyle(
                  fontSize: size,
                  height: 1.25,
                  color: solid ? ink.onStrong : ink.text == const Color(0xFFF1F1F4) ? ink.text : scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
                TextAlign.center,
              ),
            ),
          ),
        );
      default:
        final ink = BoardInk.of(scheme, item.color, fallback: 'black');
        return Align(
          alignment: Alignment.topLeft,
          child: _words(
            TextStyle(fontSize: size, height: 1.3, color: ink.strong),
            TextAlign.start,
          ),
        );
    }
  }
}

class _ShapePainter extends CustomPainter {
  const _ShapePainter({
    required this.kind,
    required this.fill,
    required this.stroke,
    required this.width,
  });

  final String kind;
  final Color? fill;
  final Color stroke;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final path = shapeOutline(kind, (Offset.zero & size).deflate(width / 2));
    if (fill != null) canvas.drawPath(path, Paint()..color = fill!);
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ShapePainter old) =>
      old.kind != kind ||
      old.fill != fill ||
      old.stroke != stroke ||
      old.width != width;
}
