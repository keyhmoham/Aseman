import 'package:flutter/material.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/elpian_node.dart';

class HtmlTime {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';

    Widget result = Text(text);

    if (node.style != null) {
      result = CSSProperties.applyStyle(result, node.style);
    }

    return result;
  }
}
