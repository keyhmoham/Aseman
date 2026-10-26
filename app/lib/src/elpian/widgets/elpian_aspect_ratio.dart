import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianAspectRatio {
  static Widget build(ElpianNode node, List<Widget> children) {
    final child = children.isNotEmpty ? children.first : Container();
    final aspectRatio = numProp(node, 'aspectRatio') ?? 1.0;

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: child,
    );
  }
}
