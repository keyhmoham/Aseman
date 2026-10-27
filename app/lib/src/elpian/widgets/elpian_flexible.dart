import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianFlexible {
  static Widget build(ElpianNode node, List<Widget> children) {
    final child = children.isNotEmpty ? children.first : Container();
    final flex = numProp(node, 'flex')?.toInt() ?? 1;

    return Flexible(
      flex: flex,
      child: child,
    );
  }
}
