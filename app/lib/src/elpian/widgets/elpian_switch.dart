import 'package:flutter/material.dart';

import '../core/elpian_services.dart';
import '../core/lenient.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

/// A Material 3 switch: its thumb grows and shows a check when on.
///
/// Props: `value` (bool), `label` (text beside it; tapping it toggles
/// too), `icons` (default true: check / close on the thumb), `disabled`.
/// Event: `change` with `{value}`.
class ElpianSwitch {
  static Widget build(ElpianNode node, List<Widget> children) {
    // Captured while the engine's service scope is active: the handlers
    // run later, outside it.
    final dispatcher = ElpianServices.current.events;
    final value = looseBool(node.props['value']) ?? false;
    final elementId = node.key ?? 'element_${node.hashCode}';
    final disabled = boolProp(node, 'disabled') == true;
    final icons = boolProp(node, 'icons') ?? true;
    void change(bool v) => dispatcher.dispatchChange(elementId, v);

    final control = Switch(
      value: value,
      thumbIcon: icons
          ? WidgetStateProperty.resolveWith(
              (s) => Icon(
                s.contains(WidgetState.selected) ? Icons.check : Icons.close,
                size: 16,
              ),
            )
          : null,
      onChanged: disabled ? null : change,
    );
    return labelled(node, control, disabled ? null : () => change(!value));
  }

  /// [control] with `props.label` beside it, the label toggling it too.
  static Widget labelled(
    ElpianNode node,
    Widget control,
    VoidCallback? toggle,
  ) {
    final label = textProp(node, 'label');
    if (label == null) return control;
    final leading = node.props['labelPosition'] == 'end';
    final text = Flexible(child: Text(label));
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: leading
              ? [control, const SizedBox(width: 12), text]
              : [text, const SizedBox(width: 12), control],
        ),
      ),
    );
  }
}
