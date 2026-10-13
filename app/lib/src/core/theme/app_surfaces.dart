import 'package:flutter/material.dart';

import 'app_shape.dart';

/// The one place that decides how each kind of surface is coloured, so every
/// bottom sheet, dialog, floating panel, menu and card looks the same no
/// matter which screen opens it. Widgets read these instead of picking their
/// own `ColorScheme` role or radius.
abstract final class AppSurfaces {
  /// Background of every modal surface: bottom sheets, dialogs, floating
  /// panels and popup menus. It is the same `surface` the full-screen panels
  /// (settings, messenger, profile) paint, so a panel opened in a sheet or
  /// dialog blends into its chrome.
  static Color overlay(ColorScheme scheme) => scheme.surface;

  /// Scrim behind every modal surface.
  static const barrier = Colors.black54;

  /// Background of in-page cards and panels.
  static Color card(ColorScheme scheme) => scheme.surface;

  /// Outline drawn around in-page cards and panels.
  static Color cardBorder(ColorScheme scheme) =>
      scheme.outlineVariant.withValues(alpha: .55);

  static const overlayShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(AppShape.card)));

  static const sheetShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppShape.card)));

  /// Decoration for a hand-built card that should match [Card].
  static BoxDecoration cardDecoration(BuildContext context,
      {double radius = AppShape.inner}) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: card(scheme),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: cardBorder(scheme)),
    );
  }
}
