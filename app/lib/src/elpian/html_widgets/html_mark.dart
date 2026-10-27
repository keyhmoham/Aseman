import 'package:flutter/material.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/css_style.dart';
import '../models/elpian_node.dart';

class HtmlMark {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';

    const defaultStyle = CSSStyle(
      backgroundColor: Color(0xFFFFFF00),
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    );

    final mergedStyle = node.style ?? defaultStyle;
    Widget result =
        Text(text, style: CSSProperties.createTextStyle(mergedStyle));
    result = CSSProperties.applyStyle(result, mergedStyle);

    return result;
  }
}
