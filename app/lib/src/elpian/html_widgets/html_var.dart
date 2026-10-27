import 'package:flutter/material.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/css_style.dart';
import '../models/elpian_node.dart';

class HtmlVar {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';

    const defaultStyle = CSSStyle(
      fontStyle: FontStyle.italic,
    );

    final mergedStyle = node.style ?? defaultStyle;
    Widget result =
        Text(text, style: CSSProperties.createTextStyle(mergedStyle));
    result = CSSProperties.applyStyle(result, mergedStyle);

    return result;
  }
}
