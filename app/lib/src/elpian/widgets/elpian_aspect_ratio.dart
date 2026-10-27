import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

class ElpianAspectRatio {
  static Widget build(ElpianNode node, List<Widget> children) {
    final child = children.isNotEmpty ? children.first : Container();
    final ratio = sizeProp(node, 'aspectRatio');
    final aspectRatio = ratio == null || ratio == 0 ? 1.0 : ratio;

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: child,
    );
  }
}
