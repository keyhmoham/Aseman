import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianCircularProgressIndicator {
  static Widget build(ElpianNode node, List<Widget> children) {
    return CircularProgressIndicator(
      value: numProp(node, 'value'),
      backgroundColor: node.style?.backgroundColor,
      color: node.style?.color,
      strokeWidth: node.style?.borderWidth ?? 4.0,
    );
  }
}
