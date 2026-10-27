import 'package:flutter/material.dart';
import '../core/lenient.dart';
import '../models/elpian_node.dart';

class HtmlOption {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';
    return Text(text);
  }
}
