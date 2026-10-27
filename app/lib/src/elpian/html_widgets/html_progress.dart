import 'package:flutter/material.dart';
import '../core/lenient.dart';
import '../models/elpian_node.dart';

class HtmlProgress {
  static Widget build(ElpianNode node, List<Widget> children) {
    final value = (looseNum(node.props['value']))?.toDouble();
    final max = (looseNum(node.props['max']))?.toDouble() ?? 1.0;

    return LinearProgressIndicator(
      value: value != null ? value / max : null,
      backgroundColor: Colors.grey[200],
    );
  }
}
