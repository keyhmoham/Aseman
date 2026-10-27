import 'package:flutter/material.dart';
import '../core/lenient.dart';
import '../models/elpian_node.dart';

class HtmlMeter {
  static Widget build(ElpianNode node, List<Widget> children) {
    final value = (looseNum(node.props['value']))?.toDouble() ?? 0.5;
    final min = (looseNum(node.props['min']))?.toDouble() ?? 0.0;
    final max = (looseNum(node.props['max']))?.toDouble() ?? 1.0;

    final normalized = (value - min) / (max - min);

    return LinearProgressIndicator(
      value: normalized,
      backgroundColor: Colors.grey[200],
      valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
    );
  }
}
