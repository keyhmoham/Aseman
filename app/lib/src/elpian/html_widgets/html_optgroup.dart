import 'package:flutter/material.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/elpian_node.dart';

class HtmlOptgroup {
  static Widget build(ElpianNode node, List<Widget> children) {
    final label = looseStr(node.props['label']) ?? '';

    Widget result = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ...children,
      ],
    );

    if (node.style != null) {
      result = CSSProperties.applyStyle(result, node.style);
    }

    return result;
  }
}
