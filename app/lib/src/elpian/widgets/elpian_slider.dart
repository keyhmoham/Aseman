import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import '../core/elpian_services.dart';
import 'elpian_expressive.dart';

/// A Material 3 slider (the 2024 design: a tall track, a slim handle).
///
/// Props: `value`, `min` (0), `max` (1); `divisions` or `step` (snaps);
/// `label` (true, or a suffix such as `"%"`: shows the value on a bubble
/// while dragging); `disabled`. Event: `change` with `{value}`.
class ElpianSlider {
  static Widget build(ElpianNode node, List<Widget> children) {
    // Captured while the engine's service scope is active: the handlers
    // run later, outside it.
    final dispatcher = ElpianServices.current.events;
    final min = numProp(node, 'min') ?? 0.0;
    final rawMax = numProp(node, 'max') ?? 1.0;
    final max = rawMax > min ? rawMax : min + 1;
    final value = (numProp(node, 'value') ?? (min + max) / 2)
        .clamp(min, max)
        .toDouble();
    final elementId = node.key ?? 'element_${node.hashCode}';
    final step = numProp(node, 'step');
    var divisions = numProp(node, 'divisions')?.toInt();
    if (divisions == null && step != null && step > 0 && max > min) {
      divisions = ((max - min) / step).round();
    }
    final label = node.props['label'];
    String? text;
    if (label == true || label is String) {
      final whole = value == value.roundToDouble();
      text =
          '${whole ? value.toInt() : value.toStringAsFixed(1)}'
          '${label is String ? label : ''}';
    }

    return Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions == null || divisions < 1 ? null : divisions,
      label: text,
      onChanged: boolProp(node, 'disabled') == true
          ? null
          : (newValue) {
              dispatcher.dispatchChange(elementId, newValue);
            },
    );
  }
}
