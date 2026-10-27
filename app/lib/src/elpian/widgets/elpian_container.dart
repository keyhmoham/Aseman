import 'package:flutter/material.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';
import '../css/css_properties.dart';

class ElpianContainer {
  static Widget build(ElpianNode node, List<Widget> children) {
    Widget? child;
    if (children.isNotEmpty) {
      child = children.length == 1
          ? children.first
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: children,
            );
    }

    Widget result = Container(
      width: numProp(node, 'width'),
      height: numProp(node, 'height'),
      padding: _as<EdgeInsets>(node.props['padding']),
      margin: _as<EdgeInsets>(node.props['margin']),
      alignment: _as<Alignment>(node.props['alignment']),
      decoration: _as<BoxDecoration>(node.props['decoration']),
      child: child,
    );

    if (node.style != null) {
      result = CSSProperties.applyStyle(result, node.style);
    }

    return result;
  }
}

/// Dart-typed props (from Dart callers); JSON trees set these through style.
T? _as<T>(Object? v) => v is T ? v : null;
