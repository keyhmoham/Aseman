import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianSpacer {
  static Widget build(ElpianNode node, List<Widget> children) {
    final flex = numProp(node, 'flex')?.toInt() ?? 1;

    return Spacer(flex: flex);
  }
}
