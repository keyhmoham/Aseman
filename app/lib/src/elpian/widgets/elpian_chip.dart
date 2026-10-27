import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import '../core/node_events.dart';
import 'elpian_expressive.dart';

/// A Material 3 chip.
///
/// Props: `label`; `icon` (a Material icon name); `selected` (a filter
/// chip: shows a check and reports `change` with `{value}`); `variant` —
/// `assist` (default), `filter`, `input` (with a remove button: `remove`
/// event), `suggestion`; `disabled`. Events: `tap`, `change`, `remove`.
class ElpianChip {
  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final label = Text('${node.props['label'] ?? node.props['text'] ?? ''}');
    final variant = textProp(node, 'variant') ?? 'assist';
    final selected = boolProp(node, 'selected');
    final disabled = boolProp(node, 'disabled') == true;
    final icon = iconWidget(node.props['icon'], size: 18);
    final bg = node.style?.backgroundColor;

    if (selected != null || variant == 'filter') {
      final on = selected ?? false;
      return FilterChip(
        label: label,
        avatar: on ? null : icon,
        selected: on,
        backgroundColor: bg,
        onSelected: disabled
            ? null
            : (v) {
                if (e.has('change')) e.emit('change', data: {'value': v});
                e.activate();
              },
      );
    }
    if (variant == 'input') {
      return InputChip(
        label: label,
        avatar: icon,
        backgroundColor: bg,
        isEnabled: !disabled,
        onPressed: e.hasAny(const ['tap', 'click']) ? e.activate : null,
        onDeleted: e.has('remove') ? () => e.emit('remove') : null,
      );
    }
    final tappable = e.hasAny(const ['tap', 'click']);
    if (!tappable) {
      return Chip(label: label, avatar: icon, backgroundColor: bg);
    }
    return ActionChip(
      label: label,
      avatar: icon,
      backgroundColor: bg,
      elevation: variant == 'elevated' ? 1 : null,
      onPressed: disabled ? null : e.activate,
    );
  }
}
