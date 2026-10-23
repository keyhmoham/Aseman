import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import '../core/media.dart';
import '../css/css_properties.dart';

class ElpianImage {
  static Widget build(ElpianNode node, List<Widget> children) {
    final src = node.props['src'] as String? ?? '';
    final fit = parseBoxFit(node.props['fit']) ?? BoxFit.contain;
    final alt = node.props['alt'] as String?;

    // Any source the engine or its host loads (network with the host's
    // credentials, the host's own files, data: URIs, SVG, assets).
    Widget result = ElpianMediaImage(
        src: src,
        fit: fit,
        width: node.style?.width,
        height: node.style?.height,
        alt: alt);

    if (node.style != null) {
      result = CSSProperties.applyStyle(result, node.style);
    }

    return result;
  }
}

/// A `fit` prop: a [BoxFit], or its CSS / Surface Spec spelling (`contain`, `cover`,
/// `fill`, `none`, `scaleDown` / `scale-down`, `fitWidth`, `fitHeight`).
BoxFit? parseBoxFit(Object? fit) {
  if (fit is BoxFit) return fit;
  if (fit is! String) return null;
  switch (fit.replaceAll('-', '').toLowerCase()) {
    case 'contain':
      return BoxFit.contain;
    case 'cover':
      return BoxFit.cover;
    case 'fill':
      return BoxFit.fill;
    case 'none':
      return BoxFit.none;
    case 'scaledown':
      return BoxFit.scaleDown;
    case 'fitwidth':
      return BoxFit.fitWidth;
    case 'fitheight':
      return BoxFit.fitHeight;
  }
  return null;
}
