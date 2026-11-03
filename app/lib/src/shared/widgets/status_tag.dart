import 'package:flutter/material.dart';

import '../../core/theme/theme_chrome.dart';

class StatusTag extends StatelessWidget {
  const StatusTag(this.text, this.color, {super.key});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.chipRecipe.paddingH.clamp(5, 10),
          vertical: context.chipRecipe.paddingV.clamp(2, 6),
        ),
        decoration: context.metaChipDecoration(accent: color),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 9, fontWeight: FontWeight.w800)),
      );
}
