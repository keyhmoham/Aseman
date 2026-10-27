import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianGridView {
  static Widget build(ElpianNode node, List<Widget> children) {
    final count = numProp(node, 'crossAxisCount');
    final crossAxisCount = count == null || !count.isFinite || count < 1 ? 2 : count.round();

    return GridView.count(
      crossAxisCount: crossAxisCount,
      shrinkWrap: true,
      children: children,
    );
  }
}
