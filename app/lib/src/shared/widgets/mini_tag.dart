import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/theme_chrome.dart';

/// Small uppercase pill label used across the app (tags, badges, chips).
class MiniTag extends StatelessWidget {
  const MiniTag(this.label, this.color, {super.key});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final chip = context.chipRecipe;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: math.max(chip.paddingH * .55, 7),
        vertical: math.max(chip.paddingV * .4, 4),
      ),
      decoration: context.metaChipDecoration(accent: color),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 7,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }
}
