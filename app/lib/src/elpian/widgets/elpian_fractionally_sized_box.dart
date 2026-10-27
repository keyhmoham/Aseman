import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianFractionallySizedBox {
  static Widget build(ElpianNode node, List<Widget> children) {
    final child = children.isNotEmpty ? children.first : null;

    return FractionallySizedBox(
      widthFactor: sizeProp(node, 'widthFactor'),
      heightFactor: sizeProp(node, 'heightFactor'),
      alignment: node.style?.alignment ?? Alignment.center,
      child: child,
    );
  }
}
