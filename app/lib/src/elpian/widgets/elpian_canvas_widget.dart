import 'package:flutter/material.dart';
import '../css/css_parser.dart';

import '../canvas/canvas_widget.dart';
import '../core/node_events.dart';
import '../models/elpian_node.dart';

/// `Canvas`: vector drawing by canvas `commands`, `width` / `height` (else
/// it fills the space it is given), `backgroundColor`. Event `resize` with
/// `{width, height}` when it is laid out at a new size; gestures (`drag*`,
/// `pointer*`, `scale*`) come from the engine, in the canvas's coordinates.
class ElpianCanvasWidget {
  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final width = _toDouble(node.props['width']);
    final height = _toDouble(node.props['height']);
    final bg = node.props['backgroundColor'];
    // A Color from Dart callers, a CSS color string from JSON.
    final backgroundColor = bg is Color ? bg : CSSParser.parseColor(bg);

    final commands = _normalizeCommands(node.props['commands']);

    return ElpianCanvas(
      commands: commands,
      width: width ?? node.style?.width,
      height: height ?? node.style?.height,
      backgroundColor: backgroundColor ?? node.style?.backgroundColor,
      onResize: e.has('resize')
          ? (size) => e.emit('resize',
              data: {'width': size.width, 'height': size.height})
          : null,
    );
  }

  static List<Map<String, dynamic>> _normalizeCommands(dynamic rawCommands) {
    if (rawCommands is List<Map<String, dynamic>>) {
      return rawCommands;
    }

    if (rawCommands is List) {
      return rawCommands
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }

    return const [];
  }

  /// A size: a finite, non-negative number, else null.
  static double? _toDouble(dynamic value) {
    final v = value is num ? value.toDouble() : (value is String ? double.tryParse(value) : null);
    return v == null || v < 0 || !v.isFinite ? null : v;
  }
}
