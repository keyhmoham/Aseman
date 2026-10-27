import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianIndexedStack {
  static Widget build(ElpianNode node, List<Widget> children) {
    final index = children.isEmpty ? null : (numProp(node, 'index')?.toInt() ?? 0).clamp(0, children.length - 1);

    return IndexedStack(
      index: index,
      children: children,
    );
  }
}
