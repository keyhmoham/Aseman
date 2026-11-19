
import 'package:flutter/material.dart';

/// How a whiteboard colour name looks on the current theme. A name is one of
/// the node's palette (yellow, pink, …) or `#rrggbb`.
class BoardInk {
  const BoardInk({required this.strong, required this.soft, required this.text});

  /// Outlines, lines, strokes and solid fills.
  final Color strong;

  /// A card's or a soft shape's fill.
  final Color soft;

  /// Words on [soft].
  final Color text;

  /// Words on a solid fill of [strong].
  Color get onStrong =>
      ThemeData.estimateBrightnessForColor(strong) == Brightness.dark
      ? Colors.white
      : const Color(0xFF1B1B1F);

  static const _named = <String, Color>{
    'yellow': Color(0xFFF2B705),
    'pink': Color(0xFFE5558F),
    'blue': Color(0xFF3B82E0),
    'green': Color(0xFF2FA36B),
    'purple': Color(0xFF8B5CD6),
    'orange': Color(0xFFEE7B22),
    'red': Color(0xFFDB4437),
    'teal': Color(0xFF1FA39A),
    'gray': Color(0xFF7B8494),
  };

  static Color? _parse(String name) {
    final c = _named[name];
    if (c != null) return c;
    if (name.length == 7 && name.startsWith('#')) {
      final v = int.tryParse(name.substring(1), radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return null;
  }

  /// [name] on [scheme]. Unknown names fall back to [fallback].
  static BoardInk of(
    ColorScheme scheme,
    String name, {
    String fallback = 'gray',
  }) {
    final dark = scheme.brightness == Brightness.dark;
    if (name == 'black') {
      return BoardInk(
        strong: scheme.onSurface,
        soft: scheme.surfaceContainerHighest,
        text: scheme.onSurface,
      );
    }
    if (name == 'white') {
      return BoardInk(
        strong: dark ? const Color(0xFFF4F4F6) : const Color(0xFFFFFFFF),
        soft: dark ? const Color(0xFF2B2D33) : const Color(0xFFFFFFFF),
        text: scheme.onSurface,
      );
    }
    final base = _parse(name) ?? _parse(fallback) ?? _named['gray']!;
    return BoardInk(
      strong: base,
      soft: Color.alphaBlend(
        base.withValues(alpha: dark ? .30 : .30),
        dark ? const Color(0xFF1F2126) : const Color(0xFFFFFFFF),
      ),
      text: dark ? const Color(0xFFF1F1F4) : const Color(0xFF1B1B1F),
    );
  }
}
