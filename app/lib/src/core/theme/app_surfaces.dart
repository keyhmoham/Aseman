import 'package:flutter/material.dart';

import 'app_shape.dart';

/// Shared surface colour and frost. Overlays (sheets, dialogs, floating
/// panels) use translucent glass; **in-page** cards stay quiet — a single
/// tint and hairline border, no gradient washes or decorative shadows.
///
/// Glass needs a real backdrop: do not put [Opacity] / [FadeTransition]
/// above a [GlassSurface], and keep host [Scaffold] backgrounds transparent
/// so the frost is not painted over an opaque fill.
abstract final class AppSurfaces {
  /// Opacity of in-page cards and panels over the page.
  static const cardAlpha = .55;

  /// Opacity of modal chrome (sheets, dialogs, floating panels, menus).
  static const overlayAlpha = .68;

  /// White veil on light pages. Same translucency as dark glass.
  static const lightTint = Color(0xFFFFFFFF);

  /// Backdrop blur strength for glass surfaces.
  static const blurSigma = 18.0;

  /// Color mixed into glass.
  static Color tint(ColorScheme scheme) => scheme.brightness == Brightness.light
      ? lightTint
      : scheme.surfaceContainerHigh;

  /// How much of [tint] to keep. [overlay] is the modal chrome.
  static double tintAlpha(ColorScheme scheme, {bool overlay = false}) =>
      switch (scheme.brightness) {
        Brightness.dark ||
        Brightness.light => overlay ? overlayAlpha : cardAlpha,
      };

  /// True when [alpha] is one of the shared glass opacities (or unset).
  static bool standardAlpha(double? alpha) =>
      alpha == null || alpha == cardAlpha || alpha == overlayAlpha;

  /// Background of every modal surface.
  static Color overlay(ColorScheme scheme) =>
      tint(scheme).withValues(alpha: tintAlpha(scheme, overlay: true));

  /// Scrim behind every modal surface.
  static const barrier = Colors.black54;

  /// Background of in-page cards and panels.
  static Color card(ColorScheme scheme) =>
      tint(scheme).withValues(alpha: tintAlpha(scheme));

  /// Outline drawn around in-page cards and panels.
  static Color cardBorder(ColorScheme scheme) =>
      scheme.outlineVariant.withValues(alpha: .4);

  static const overlayShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppShape.card)),
  );

  static const sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(AppShape.card)),
  );

  static BorderRadius cardRadius([double radius = AppShape.inner]) =>
      BorderRadius.circular(radius);

  /// Quiet in-page card: flat tint + hairline. Prefer [GlassSurface] /
  /// [AppCard] when the surface should also frost what sits behind it.
  static BoxDecoration cardDecoration(
    BuildContext context, {
    double radius = AppShape.inner,
    Color? accent,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: card(scheme),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: accent?.withValues(alpha: .35) ?? cardBorder(scheme),
      ),
    );
  }
}
