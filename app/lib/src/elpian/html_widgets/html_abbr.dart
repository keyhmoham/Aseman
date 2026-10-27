import 'package:flutter/material.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/elpian_node.dart';

class HtmlAbbr {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';
    final title = looseStr(node.props['title']) ?? '';

    Widget result = Tooltip(
      message: title,
      child: Text(text,
          style: const TextStyle(decoration: TextDecoration.underline)),
    );

    if (node.style != null) {
      result = CSSProperties.applyStyle(result, node.style);
    }

    return result;
  }
}
