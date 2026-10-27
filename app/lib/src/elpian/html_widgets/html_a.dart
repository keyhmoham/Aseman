import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/lenient.dart';
import '../css/css_properties.dart';
import '../models/css_style.dart';
import '../models/elpian_node.dart';

class HtmlA {
  static Widget build(ElpianNode node, List<Widget> children) {
    final text = looseStr(node.props['text']) ?? '';
    final href = looseStr(node.props['href']) ?? '#';

    // Merge defaults with custom style
    final mergedStyle = CSSStyle(
      color: node.style?.color ?? Colors.blue,
      textDecoration: node.style?.textDecoration ?? TextDecoration.underline,
      fontSize: node.style?.fontSize,
      fontWeight: node.style?.fontWeight,
      fontFamily: node.style?.fontFamily,
      letterSpacing: node.style?.letterSpacing,
      lineHeight: node.style?.lineHeight,
      backgroundColor: node.style?.backgroundColor,
      padding: node.style?.padding,
      margin: node.style?.margin,
      opacity: node.style?.opacity,
    );
    final textStyle = CSSProperties.createTextStyle(mergedStyle);

    Widget result = GestureDetector(
      onTap: () async {
        final uri = Uri.tryParse(href);
        if (uri == null) {
          debugPrint('Invalid href: $href');
          return;
        }

        if (!await launchUrl(uri, mode: LaunchMode.platformDefault)) {
          debugPrint('Failed to open link: $href');
        }
      },
      child: children.isNotEmpty
          ? Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (text.isNotEmpty) Text(text, style: textStyle),
                ...children,
              ],
            )
          : Text(text, style: textStyle),
    );

    result = CSSProperties.applyStyle(result, mergedStyle);

    return result;
  }
}
