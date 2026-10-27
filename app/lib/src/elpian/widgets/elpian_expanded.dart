import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianExpanded {
  static Widget build(ElpianNode node, List<Widget> children) {
    final child = children.isNotEmpty ? children.first : Container();
    final flex = flexProp(node);

    return Expanded(
      flex: flex,
      child: child,
    );
  }
}
