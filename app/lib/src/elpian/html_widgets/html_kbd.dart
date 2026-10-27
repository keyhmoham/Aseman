import 'package:flutter/material.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/css_style.dart';
import '../models/elpian_node.dart';

class HtmlKbd {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';

    const defaultStyle = CSSStyle(
      fontFamily: 'monospace',
      backgroundColor: Color(0xFFEEEEEE),
      padding: EdgeInsets.all(4),
      borderRadius: BorderRadius.all(Radius.circular(3)),
    );

    final mergedStyle = node.style ?? defaultStyle;
    Widget result =
        Text(text, style: CSSProperties.createTextStyle(mergedStyle));
    result = CSSProperties.applyStyle(result, mergedStyle);

    return result;
  }
}
