import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianGridView {
  static Widget build(ElpianNode node, List<Widget> children) {
    final crossAxisCount = numProp(node, 'crossAxisCount')?.toInt() ?? 2;

    return GridView.count(
      crossAxisCount: crossAxisCount,
      shrinkWrap: true,
      children: children,
    );
  }
}
