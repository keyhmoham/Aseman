import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianRotatedBox {
  static Widget build(ElpianNode node, List<Widget> children) {
    final child = children.isNotEmpty ? children.first : Container();
    final quarterTurns = numProp(node, 'quarterTurns')?.toInt() ?? 0;

    return RotatedBox(
      quarterTurns: quarterTurns,
      child: child,
    );
  }
}
