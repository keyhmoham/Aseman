import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show Node, highlight;

/// Syntax highlighting for code shown anywhere in the app (files, code
/// blocks of messages and posts): highlight.js grammars, coloured with One
/// Dark or One Light.
abstract final class CodeHighlight {
  /// Fence and file names people use for a language, to its grammar.
  static const _aliases = {
    'js': 'javascript',
    'jsx': 'javascript',
    'mjs': 'javascript',
    'node': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'py': 'python',
    'python3': 'python',
    'sh': 'bash',
    'zsh': 'bash',
    'console': 'bash',
    'yml': 'yaml',
    'rb': 'ruby',
    'rs': 'rust',
    'kt': 'kotlin',
    'csharp': 'cs',
    'c#': 'cs',
    'c': 'cpp',
    'c++': 'cpp',
    'h': 'cpp',
    'hpp': 'cpp',
    'html': 'xml',
    'svg': 'xml',
    'md': 'markdown',
    'golang': 'go',
    'ps': 'powershell',
    'ps1': 'powershell',
    'docker': 'dockerfile',
    'jsonc': 'json',
    'objc': 'objectivec',
    'toml': 'ini',
    'tf': 'ini',
    'proto': 'protobuf',
    'gql': 'graphql',
    'text': '',
    'txt': '',
    'plain': '',
  };

  /// The grammar for [name] ('' for none).
  static String language(String name) {
    final n = name.trim().toLowerCase();
    return _aliases[n] ?? n;
  }

  static Map<String, Color> palette(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static Color background(Brightness brightness) =>
      palette(brightness)['background']!;

  static Color foreground(Brightness brightness) =>
      palette(brightness)['root']!;

  /// [text] as coloured spans in [language]; the text as it is when the
  /// language is unknown or the grammar fails.
  static List<TextSpan> spans(
    String text,
    String language,
    Map<String, Color> palette,
  ) {
    final grammar = CodeHighlight.language(language);
    if (grammar.isEmpty) return [TextSpan(text: text)];
    try {
      final nodes = highlight.parse(text, language: grammar).nodes;
      if (nodes == null) return [TextSpan(text: text)];
      return [for (final n in nodes) _span(n, palette)];
    } catch (_) {
      return [TextSpan(text: text)];
    }
  }

  static TextSpan _span(Node node, Map<String, Color> palette) {
    final color = node.className == null ? null : palette[node.className];
    final style = color == null
        ? null
        : TextStyle(
            color: color,
            fontStyle:
                node.className == 'comment' ||
                    node.className == 'quote' ||
                    node.className == 'emphasis'
                ? FontStyle.italic
                : null,
            fontWeight:
                node.className == 'strong' ||
                    node.className == 'section' ||
                    node.className == 'title'
                ? FontWeight.w700
                : null,
          );
    if (node.value != null) return TextSpan(text: node.value, style: style);
    return TextSpan(
      style: style,
      children: [
        for (final c in node.children ?? const <Node>[]) _span(c, palette),
      ],
    );
  }

  // One Dark and One Light, by highlight.js class.
  static const _dark = <String, Color>{
    'root': Color(0xFFABB2BF),
    'background': Color(0xFF1E2128),
    'comment': Color(0xFF7F848E),
    'quote': Color(0xFF7F848E),
    'doctag': Color(0xFFC678DD),
    'keyword': Color(0xFFC678DD),
    'formula': Color(0xFFC678DD),
    'section': Color(0xFFE06C75),
    'name': Color(0xFFE06C75),
    'selector-tag': Color(0xFFE06C75),
    'deletion': Color(0xFFE06C75),
    'subst': Color(0xFFE06C75),
    'literal': Color(0xFF56B6C2),
    'string': Color(0xFF98C379),
    'regexp': Color(0xFF98C379),
    'addition': Color(0xFF98C379),
    'attribute': Color(0xFF98C379),
    'meta-string': Color(0xFF98C379),
    'built_in': Color(0xFFE6C07B),
    'class': Color(0xFFE6C07B),
    'title': Color(0xFF61AFEF),
    'function': Color(0xFF61AFEF),
    'attr': Color(0xFFD19A66),
    'variable': Color(0xFFD19A66),
    'template-variable': Color(0xFFD19A66),
    'type': Color(0xFFE6C07B),
    'selector-class': Color(0xFFD19A66),
    'selector-attr': Color(0xFFD19A66),
    'selector-pseudo': Color(0xFFD19A66),
    'number': Color(0xFFD19A66),
    'symbol': Color(0xFF61AFEF),
    'bullet': Color(0xFF61AFEF),
    'link': Color(0xFF61AFEF),
    'meta': Color(0xFF61AFEF),
    'selector-id': Color(0xFF61AFEF),
    'params': Color(0xFFABB2BF),
    'tag': Color(0xFFE06C75),
  };

  static const _light = <String, Color>{
    'root': Color(0xFF383A42),
    'background': Color(0xFFFAFAFA),
    'comment': Color(0xFFA0A1A7),
    'quote': Color(0xFFA0A1A7),
    'doctag': Color(0xFFA626A4),
    'keyword': Color(0xFFA626A4),
    'formula': Color(0xFFA626A4),
    'section': Color(0xFFE45649),
    'name': Color(0xFFE45649),
    'selector-tag': Color(0xFFE45649),
    'deletion': Color(0xFFE45649),
    'subst': Color(0xFFE45649),
    'literal': Color(0xFF0184BB),
    'string': Color(0xFF50A14F),
    'regexp': Color(0xFF50A14F),
    'addition': Color(0xFF50A14F),
    'attribute': Color(0xFF50A14F),
    'meta-string': Color(0xFF50A14F),
    'built_in': Color(0xFFC18401),
    'class': Color(0xFFC18401),
    'title': Color(0xFF4078F2),
    'function': Color(0xFF4078F2),
    'attr': Color(0xFF986801),
    'variable': Color(0xFF986801),
    'template-variable': Color(0xFF986801),
    'type': Color(0xFFC18401),
    'selector-class': Color(0xFF986801),
    'selector-attr': Color(0xFF986801),
    'selector-pseudo': Color(0xFF986801),
    'number': Color(0xFF986801),
    'symbol': Color(0xFF4078F2),
    'bullet': Color(0xFF4078F2),
    'link': Color(0xFF4078F2),
    'meta': Color(0xFF4078F2),
    'selector-id': Color(0xFF4078F2),
    'params': Color(0xFF383A42),
    'tag': Color(0xFFE45649),
  };
}
