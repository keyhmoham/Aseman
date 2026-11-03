import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import '../models/css_style.dart';
import '../core/node_events.dart';
import '../css/css_properties.dart';
import 'elpian_expressive.dart';
import '../../core/theme/app_shape.dart';

/// A Material 3 card around its children (a column).
///
/// Props: `variant` — `filled` (a tonal container), `elevated`, `outlined`,
/// or the theme's card when absent; `elevation`; `radius` (corner radius,
/// default the theme's); `tone` — `primary` `secondary` `tertiary` `error`
/// (their container colors, for a highlighted card). Style: `padding`
/// (inside), `backgroundColor`, `borderRadius`, `borderColor` /
/// `borderWidth`, `gap` (between children), and the box props outside
/// (`margin`, `width`, …). With a `tap` (or `longpress` / `doubletap`)
/// event the card ripples and springs when pressed.
class ElpianCard {
  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final style = node.style;
    final gap = style?.gap;
    Widget? child;
    if (children.length == 1) {
      child = children.first;
    } else if (children.isNotEmpty) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0 && gap != null && gap > 0) SizedBox(height: gap),
            children[i],
          ],
        ],
      );
    }
    Widget cardChild = child ?? const SizedBox.shrink();
    if (style?.padding != null) {
      cardChild = Padding(padding: style!.padding!, child: cardChild);
    }
    final tappable = e.hasAny(const ['tap', 'click', 'longpress', 'doubletap']);

    Widget result = Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final variant = textProp(node, 'variant');
        final tone = textProp(node, 'tone');
        final (Color? toneBg, Color? toneFg) = switch (tone) {
          'primary' => (scheme.primaryContainer, scheme.onPrimaryContainer),
          'secondary' => (
            scheme.secondaryContainer,
            scheme.onSecondaryContainer,
          ),
          'tertiary' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
          'error' ||
          'danger' => (scheme.errorContainer, scheme.onErrorContainer),
          'inverse' => (scheme.inverseSurface, scheme.onInverseSurface),
          _ => (null, null),
        };
        final themeShape = theme.cardTheme.shape;
        final radius = numProp(node, 'radius');
        BorderRadiusGeometry? corners =
            style?.borderRadius ??
            (radius != null ? BorderRadius.circular(radius) : null);
        if (corners == null && themeShape is RoundedRectangleBorder) {
          corners = themeShape.borderRadius;
        }
        corners ??= AppShape.borderRadius(context, 24);
        final side = style?.borderColor != null
            ? BorderSide(
                color: style!.borderColor!,
                width: style.borderWidth ?? 1.0,
              )
            : switch (variant) {
                'outlined' => BorderSide(color: scheme.outlineVariant),
                'filled' || 'elevated' => BorderSide.none,
                _ =>
                  toneBg != null
                      ? BorderSide.none
                      : (themeShape is OutlinedBorder
                            ? themeShape.side
                            : BorderSide.none),
              };
        final color =
            style?.backgroundColor ??
            toneBg ??
            switch (variant) {
              'filled' => scheme.surfaceContainerHighest,
              'elevated' => scheme.surfaceContainerLow,
              'outlined' => scheme.surface,
              _ => null,
            };
        final elevation =
            style?.boxShadow != null && style!.boxShadow!.isNotEmpty
            ? style.boxShadow!.first.blurRadius / 2
            : sizeProp(node, 'elevation') ??
                  (variant == 'elevated' ? 1.0 : null);
        Widget body = cardChild;
        if (tappable) {
          body = InkWell(
            onTap: e.has('tap') || e.has('click') ? e.activate : null,
            onLongPress: e.has('longpress') ? () => e.emit('longpress') : null,
            onDoubleTap: e.has('doubletap') ? () => e.emit('doubletap') : null,
            child: body,
          );
        }
        if (toneFg != null) {
          body = IconTheme.merge(
            data: IconThemeData(color: toneFg),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: toneFg),
              child: body,
            ),
          );
        }
        Widget card = Card(
          elevation: elevation,
          color: color,
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: corners, side: side),
          clipBehavior: Clip.antiAlias,
          child: body,
        );
        if (tappable) card = ExpressivePress(scale: 0.98, child: card);
        return card;
      },
    );

    if (style != null) {
      // Only the box props outside the card: the rest is drawn by the card.
      final externalStyle = CSSStyle(
        width: style.width,
        height: style.height,
        minWidth: style.minWidth,
        maxWidth: style.maxWidth,
        minHeight: style.minHeight,
        maxHeight: style.maxHeight,
        margin: style.margin,
        opacity: style.opacity,
        flex: style.flex,
        transform: style.transform,
        rotate: style.rotate,
        scale: style.scale,
        alignment: style.alignment,
        visible: style.visible,
      );
      result = CSSProperties.applyStyle(result, externalStyle);
    }

    return result;
  }
}
