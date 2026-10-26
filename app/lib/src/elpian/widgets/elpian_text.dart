import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import '../css/css_properties.dart';
import 'elpian_expressive.dart';

/// Text.
///
/// Props: `text`; `variant` — an M3 type role (`displayLarge` …
/// `labelSmall`, with an `Emphasized` suffix for the bolder expressive
/// weight; see [typeRole]); `color` — a theme role (`primary`, `secondary`,
/// `tertiary`, `error`, `muted` / `onSurfaceVariant`); `maxLines`,
/// `overflow`, `softWrap`, `textAlign`. `style` overrides the role.
class ElpianText {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text =
        node.props['text'] as String? ?? node.props['data'] as String? ?? '';
    final variant = node.props['variant'];
    final role = node.props['color'];

    TextStyle? textStyle;
    if (node.props['style'] is TextStyle) {
      textStyle = node.props['style'] as TextStyle;
    }
    if (node.style != null) {
      textStyle = CSSProperties.createTextStyle(node.style);
    }

    Widget text0(TextStyle? style) => Text(
      text,
      style: style,
      textAlign: node.props['textAlign'] as TextAlign? ?? node.style?.textAlign,
      maxLines: (node.props['maxLines'] as num?)?.toInt(),
      overflow:
          node.props['overflow'] as TextOverflow? ?? node.style?.textOverflow,
      softWrap: node.props['softWrap'] as bool?,
    );

    Widget result;
    if (variant is String || role is String) {
      result = Builder(
        builder: (context) {
          var style = typeRole(context, variant);
          final scheme = Theme.of(context).colorScheme;
          final color = switch (role) {
            'primary' => scheme.primary,
            'secondary' => scheme.secondary,
            'tertiary' => scheme.tertiary,
            'error' => scheme.error,
            'muted' ||
            'onSurfaceVariant' ||
            'secondaryText' => scheme.onSurfaceVariant,
            'onSurface' => scheme.onSurface,
            'onPrimaryContainer' => scheme.onPrimaryContainer,
            'onSecondaryContainer' => scheme.onSecondaryContainer,
            'onTertiaryContainer' => scheme.onTertiaryContainer,
            _ => null,
          };
          if (color != null) {
            style = (style ?? const TextStyle()).copyWith(color: color);
          }
          return text0(style == null ? textStyle : style.merge(textStyle));
        },
      );
    } else {
      result = text0(textStyle);
    }

    if (node.style != null) {
      result = CSSProperties.applyStyle(result, node.style);
    }

    return result;
  }
}
