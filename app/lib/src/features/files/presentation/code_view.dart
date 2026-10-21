import 'package:flutter/material.dart';

import '../../../shared/widgets/code_highlight.dart';

/// Source code with line numbers, highlighted for its [language] (a
/// highlight.js id; empty for plain text). Very large files are shown
/// without highlighting, line by line, so they stay fast.
class CodeView extends StatelessWidget {
  const CodeView({super.key, required this.source, this.language = ''});

  final String source;
  final String language;

  /// Beyond this many characters the code is shown plain.
  static const highlightLimit = 400000;
  static const _fontSize = 12.5;
  static const _lineHeight = 1.55;

  @override
  Widget build(BuildContext context) {
    final palette = CodeHighlight.palette(Theme.of(context).brightness);
    final text = source.replaceAll('\r\n', '\n').replaceAll('\t', '    ');
    final lines = '\n'.allMatches(text).length + 1;
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: _fontSize,
      height: _lineHeight,
      color: palette['root'],
    );
    const strut = StrutStyle(
      fontFamily: 'monospace',
      fontSize: _fontSize,
      height: _lineHeight,
      forceStrutHeight: true,
    );
    final gutter = Theme.of(context).colorScheme.onSurfaceVariant;
    final numbers = Text(
      [for (var i = 1; i <= lines; i++) '$i'].join('\n'),
      textAlign: TextAlign.right,
      strutStyle: strut,
      style: base.copyWith(color: gutter.withValues(alpha: .55)),
    );

    if (text.length > highlightLimit) {
      final rows = text.split('\n');
      return ColoredBox(
        color: palette['background']!,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemCount: rows.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${i + 1}'.padLeft(6),
                    style: TextStyle(color: gutter.withValues(alpha: .55)),
                  ),
                  TextSpan(text: '   ${rows[i]}'),
                ],
              ),
              strutStyle: strut,
              softWrap: false,
              style: base,
            ),
          ),
        ),
      );
    }

    return ColoredBox(
      color: palette['background']!,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 10, right: 12),
              child: numbers,
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: 16),
                child: SelectableText.rich(
                  TextSpan(style: base, children: highlighted(text, palette)),
                  strutStyle: strut,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The highlighted spans of [text], or the text itself when its language
  /// is unknown or the highlighter fails.
  List<TextSpan> highlighted(String text, Map<String, Color> palette) =>
      CodeHighlight.spans(text, language, palette);
}
