import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import '../core/node_events.dart';
import 'elpian_expressive.dart';

/// A Material 3 Expressive button.
///
/// Props: `text` (or one child as content); `variant` — `filled` (default),
/// `tonal`, `outlined`, `text`, `elevated`, `danger` (the older
/// `className` `primary` / `secondary` / `ghost` / `outline` / `danger`
/// map onto them); `icon` / `trailingIcon` (Material icon names); `size`
/// `xs` `s` (default) `m` `l` `xl`; `shape` `round` (default) / `square`;
/// `selected` (a toggle button: tonal → filled, round → square);
/// `loading`; `fullWidth`; `disabled`. Style: `backgroundColor`, `color`,
/// `padding`, `borderRadius`, `fontSize`, `fontWeight`, `margin`,
/// `width`, `height`, `opacity`. Corners morph tighter while pressed.
/// Events: `tap` (also `click`), `longpress`.
class ElpianButton {
  static const Map<String, String> _classVariants = {
    'primary': 'filled',
    'btn-primary': 'filled',
    'secondary': 'tonal',
    'tonal': 'tonal',
    'ghost': 'text',
    'btn-ghost': 'text',
    'link': 'text',
    'outline': 'outlined',
    'outlined': 'outlined',
    'danger': 'danger',
    'error': 'danger',
  };

  static String variantOf(ElpianNode node) {
    final v = node.props['variant'];
    if (v is String && v.isNotEmpty) return v.toLowerCase();
    final selected = boolProp(node, 'selected');
    if (selected != null) return selected ? 'filled' : 'tonal';
    for (final c in classesOf(node)) {
      final mapped = _classVariants[c];
      if (mapped != null) return mapped;
    }
    return 'filled';
  }

  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final variant = variantOf(node);
    final size = ExpressiveSize.parse(node.props['size']);
    final selected = boolProp(node, 'selected');
    final square = node.props['shape'] == 'square' || selected == true;
    final loading = boolProp(node, 'loading') == true;
    final disabled = boolProp(node, 'disabled') == true || loading;
    final style = node.style;
    // The `primary` class only colors text: on a filled button that would
    // paint the label in its own background color.
    final classColored =
        node.props['variant'] == null &&
        classesOf(node).contains('primary') &&
        style?.backgroundColor == null;
    final fg = classColored ? null : style?.color;

    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final text = node.props['text'] ?? node.props['label'];
        final iconColor = fg;
        Widget? icon = loading
            ? SizedBox.square(
                dimension: size.icon * 0.8,
                child: const CircularProgressIndicator(strokeWidth: 2.5),
              )
            : iconWidget(node.props['icon'], size: size.icon, color: iconColor);
        final trailing = iconWidget(
          node.props['trailingIcon'],
          size: size.icon,
          color: iconColor,
        );
        final label = children.isNotEmpty
            ? children.first
            : Text(
                text == null ? 'Button' : '$text',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
        final hasLabel = children.isNotEmpty || text != null || icon == null;
        Widget content = Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) icon,
            if (icon != null && hasLabel) SizedBox(width: size.padding / 2.5),
            if (hasLabel) Flexible(child: label),
            if (trailing != null) ...[
              SizedBox(width: size.padding / 2.5),
              trailing,
            ],
          ],
        );

        final (Color? bg, Color? on) = switch (variant) {
          'danger' || 'error' => (scheme.error, scheme.onError),
          'tonal' || 'secondary' => (
            scheme.secondaryContainer,
            scheme.onSecondaryContainer,
          ),
          'tertiary' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
          _ => (null, null),
        };
        final background = style?.backgroundColor ?? bg;
        final foreground = fg ?? on;
        final borderRadius = style?.borderRadius;
        final buttonStyle = ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(size.height, size.height)),
          padding: WidgetStatePropertyAll(
            style?.padding ??
                EdgeInsets.symmetric(horizontal: hasLabel ? size.padding : 0),
          ),
          iconSize: WidgetStatePropertyAll(size.icon),
          textStyle: WidgetStatePropertyAll(
            TextStyle(
              fontSize: style?.fontSize ?? size.font,
              fontWeight:
                  style?.fontWeight ??
                  (size.index >= ExpressiveSize.l.index
                      ? FontWeight.w500
                      : FontWeight.w600),
              letterSpacing: size.index >= ExpressiveSize.l.index ? 0 : 0.1,
            ),
          ),
          shape: borderRadius != null
              ? WidgetStatePropertyAll(
                  RoundedRectangleBorder(borderRadius: borderRadius),
                )
              : morphingShape(
                  size,
                  square: square,
                  side: variant == 'outlined' || variant == 'outline'
                      ? BorderSide(
                          color: style?.borderColor ?? scheme.outlineVariant,
                          width: style?.borderWidth ?? 1,
                        )
                      : null,
                ),
          backgroundColor: background == null
              ? null
              : WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.disabled)
                      ? scheme.onSurface.withValues(alpha: 0.1)
                      : background,
                ),
          foregroundColor: foreground == null
              ? null
              : WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.disabled)
                      ? scheme.onSurface.withValues(alpha: 0.38)
                      : foreground,
                ),
          animationDuration: ElpianMotion.fast,
        );

        final onPressed = disabled ? null : e.activate;
        final onLongPress = disabled || !e.has('longpress')
            ? null
            : () => e.emit('longpress');
        Widget result = switch (variant) {
          'outlined' || 'outline' => OutlinedButton(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: buttonStyle,
            child: content,
          ),
          'text' || 'ghost' || 'link' => TextButton(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: buttonStyle,
            child: content,
          ),
          'elevated' => ElevatedButton(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: buttonStyle,
            child: content,
          ),
          _ => FilledButton(
            onPressed: onPressed,
            onLongPress: onLongPress,
            style: buttonStyle,
            child: content,
          ),
        };
        result = ExpressivePress(enabled: !disabled, child: result);
        final tooltip = textProp(node, 'tooltip');
        if (tooltip != null) result = Tooltip(message: tooltip, child: result);
        if (boolProp(node, 'fullWidth') == true) {
          result = SizedBox(width: double.infinity, child: result);
        }
        if (style != null) {
          if (style.width != null || style.height != null) {
            result = SizedBox(
              width: style.width,
              height: style.height,
              child: result,
            );
          }
          if (style.opacity != null && style.opacity! < 1.0) {
            result = Opacity(opacity: style.opacity!, child: result);
          }
          if (style.margin != null) {
            result = Padding(padding: style.margin!, child: result);
          }
        }
        return result;
      },
    );
  }
}
