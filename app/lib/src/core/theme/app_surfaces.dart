import 'package:flutter/material.dart';

import 'app_shape.dart';

/// The one place that decides how every surface is coloured and frosted, so
/// cards, sheets, dialogs, floating panels and menus share the same glass
/// look — translucent fill plus backdrop blur — wherever they open.
///
/// Glass needs a real backdrop: do not put [Opacity] / [FadeTransition]
/// above a [GlassSurface], and keep host [Scaffold] backgrounds transparent
/// so the frost is not painted over an opaque fill.
abstract final class AppSurfaces {
  /// Opacity of in-page cards and panels over the page glow.
  static const cardAlpha = .55;

  /// Opacity of modal chrome (sheets, dialogs, floating panels, menus).
  static const overlayAlpha = .68;

  /// White veil on light pages. It uses [cardAlpha] / [overlayAlpha] — the
  /// same translucency as dark glass. A near-opaque white hides the blur
  /// and reads as a solid panel.
  static const lightTint = Color(0xFFFFFFFF);

  /// Backdrop blur strength for glass surfaces.
  static const blurSigma = 18.0;

  /// Color mixed into glass. Dark pages sit well below the container role,
  /// so that role shows through. Light pages sit next to it, so the panel
  /// is white instead.
  static Color tint(ColorScheme scheme) => scheme.brightness == Brightness.light
      ? lightTint
      : scheme.surfaceContainerHigh;

  /// How much of [tint] to keep. [overlay] is the modal chrome.
  /// Both brightnesses share this opacity. A light-only increase toward 1
  /// hides the frost and reads as a solid panel.
  static double tintAlpha(ColorScheme scheme, {bool overlay = false}) =>
      switch (scheme.brightness) {
        Brightness.dark ||
        Brightness.light => overlay ? overlayAlpha : cardAlpha,
      };

  /// True when [alpha] is one of the shared glass opacities (or unset).
  /// A caller that passes its own opacity keeps it in both themes.
  static bool standardAlpha(double? alpha) =>
      alpha == null || alpha == cardAlpha || alpha == overlayAlpha;

  /// Background of every modal surface: bottom sheets, dialogs, floating
  /// panels and popup menus.
  static Color overlay(ColorScheme scheme) =>
      tint(scheme).withValues(alpha: tintAlpha(scheme, overlay: true));

  /// Scrim behind every modal surface.
  static const barrier = Colors.black54;

  /// Background of in-page cards and panels.
  static Color card(ColorScheme scheme) =>
      tint(scheme).withValues(alpha: tintAlpha(scheme));

  /// Outline drawn around in-page cards and panels.
  static Color cardBorder(ColorScheme scheme) =>
      scheme.outlineVariant.withValues(alpha: .45);

  static const overlayShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppShape.card)),
  );

  static const sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(AppShape.card)),
  );

  /// Corner radius used by [cardDecoration] / glass cards.
  static BorderRadius cardRadius([double radius = AppShape.inner]) =>
      BorderRadius.circular(radius);

  /// Tint-only decoration for nested chips inside an already-frosted host.
  /// Prefer [GlassSurface] / [AppCard] for standalone cards and panels.
  static BoxDecoration cardDecoration(
    BuildContext context, {
    double radius = AppShape.inner,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: card(scheme),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: cardBorder(scheme)),
    );
  }
}
