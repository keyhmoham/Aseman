import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianLinearProgressIndicator {
  static Widget build(ElpianNode node, List<Widget> children) {
    return LinearProgressIndicator(
      value: numProp(node, 'value'),
      backgroundColor: node.style?.backgroundColor,
      color: node.style?.color,
    );
  }
}
