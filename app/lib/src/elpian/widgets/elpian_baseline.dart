import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianBaseline {
  static Widget build(ElpianNode node, List<Widget> children) {
    final child = children.isNotEmpty ? children.first : Container();
    final baseline = numProp(node, 'baseline') ?? 0.0;

    return Baseline(
      baseline: baseline,
      baselineType: TextBaseline.alphabetic,
      child: child,
    );
  }
}
