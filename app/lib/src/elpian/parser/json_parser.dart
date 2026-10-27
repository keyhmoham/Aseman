import 'dart:convert';
import '../models/elpian_node.dart';

class JsonParser {
  static ElpianNode parse(String jsonString) {
    final Map<String, dynamic> json = jsonDecode(jsonString);
    return ElpianNode.fromJson(json);
  }

  static List<ElpianNode> parseList(String jsonString) {
    // Lenient like children: null entries skipped, strings become Text.
    return ElpianNode.childrenOf(jsonDecode(jsonString));
  }

  static String stringify(ElpianNode node) {
    return jsonEncode(node.toJson());
  }

  static String stringifyList(List<ElpianNode> nodes) {
    return jsonEncode(nodes.map((node) => node.toJson()).toList());
  }
}
