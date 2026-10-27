import 'package:flutter/material.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/css_style.dart';
import '../models/elpian_node.dart';

class HtmlStrong {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';

    // Merge defaults with custom style
    final mergedStyle = CSSStyle(
      fontWeight: node.style?.fontWeight ?? FontWeight.bold,
      color: node.style?.color,
      fontSize: node.style?.fontSize,
      fontFamily: node.style?.fontFamily,
      letterSpacing: node.style?.letterSpacing,
      backgroundColor: node.style?.backgroundColor,
      padding: node.style?.padding,
      opacity: node.style?.opacity,
    );

    Widget result =
        Text(text, style: CSSProperties.createTextStyle(mergedStyle));

    result = CSSProperties.applyStyle(result, mergedStyle);

    return result;
  }
}
