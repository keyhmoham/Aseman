import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

/// A Material 3 badge on its child (an icon, an avatar).
///
/// Props: `label` (or `count`; past `max`, default 99, it shows `99+`);
/// without either it is a small dot. `show` (default true). Style:
/// `backgroundColor`, `color`.
class ElpianBadge {
  static Widget build(ElpianNode node, List<Widget> children) {
    final child = children.isNotEmpty ? children.first : const SizedBox();
    final count = numProp(node, 'count');
    final max = numProp(node, 'max') ?? 99;
    String? label = textProp(node, 'label');
    if (label == null && count != null) {
      label = count > max ? '${max.toInt()}+' : '${count.toInt()}';
    }
    final show = boolProp(node, 'show') ?? (count == null || count > 0);
    return Badge(
      isLabelVisible: show,
      label: label == null ? null : Text(label),
      backgroundColor: node.style?.backgroundColor,
      textColor: node.style?.color,
      child: child,
    );
  }
}
