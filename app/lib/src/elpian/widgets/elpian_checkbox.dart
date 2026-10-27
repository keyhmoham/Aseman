import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import '../core/elpian_services.dart';
import 'elpian_expressive.dart';
import 'elpian_switch.dart';

/// A Material 3 checkbox. Props: `value` (bool), `label` (text after it;
/// tapping it toggles too), `disabled`. Event: `change` with `{value}`.
class ElpianCheckbox {
  static Widget build(ElpianNode node, List<Widget> children) {
    // Captured while the engine's service scope is active: the handlers
    // run later, outside it.
    final dispatcher = ElpianServices.current.events;
    final value = node.props['value'] as bool? ?? false;
    final elementId = node.key ?? 'element_${node.hashCode}';
    final disabled = boolProp(node, 'disabled') == true;
    void change(bool v) => dispatcher.dispatchChange(elementId, v);

    final control = Checkbox(
      value: value,
      onChanged: disabled ? null : (v) => change(v ?? false),
    );
    final labelled = node.props['labelPosition'] == null
        ? ElpianNode(
            type: node.type,
            props: {...node.props, 'labelPosition': 'end'},
            key: node.key,
          )
        : node;
    return ElpianSwitch.labelled(
      labelled,
      control,
      disabled ? null : () => change(!value),
    );
  }
}
