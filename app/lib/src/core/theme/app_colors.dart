import 'package:flutter/material.dart';

import 'aseman_tokens.dart';

/// Legacy palette constants (Sky defaults) plus context-aware resolvers that
/// prefer the active theme pack's status / secondary accents.
abstract final class AppColors {
  static const background = Color(0xFF07111F);
  static const navigation = Color(0xFF0C1827);
  static const panel = Color(0xFF101D2C);
  static const card = Color(0xFF152536);
  static const border = Color(0xFF26394E);
  static const primary = Color(0xFF8B7BFF);
  static const cyan = Color(0xFF58D7FF);
  static const success = Color(0xFF43D39E);
  static const warning = Color(0xFFFFB648);
  static const danger = Color(0xFFFF6B79);
  static const foreground = Color(0xFFF3F7FC);
  static const muted = Color(0xFF8EA4BD);

  static Color cyanOf(BuildContext context) =>
      AsemanTokens.maybeOf(context)?.cyan ?? cyan;

  static Color successOf(BuildContext context) =>
      AsemanTokens.maybeOf(context)?.success ?? success;

  static Color warningOf(BuildContext context) =>
      AsemanTokens.maybeOf(context)?.warning ?? warning;

  static Color dangerOf(BuildContext context) =>
      AsemanTokens.maybeOf(context)?.danger ?? danger;

  static Color primaryOf(BuildContext context) =>
      Theme.of(context).colorScheme.primary;
}
