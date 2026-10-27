import 'package:flutter/material.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/elpian_node.dart';

class HtmlOutput {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';

    Widget result = Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text),
    );

    if (node.style != null) {
      result = CSSProperties.applyStyle(result, node.style);
    }

    return result;
  }
}
