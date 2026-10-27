import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianIndexedStack {
  static Widget build(ElpianNode node, List<Widget> children) {
    final index = numProp(node, 'index')?.toInt() ?? 0;

    return IndexedStack(
      index: index,
      children: children,
    );
  }
}
