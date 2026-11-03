import 'package:flutter/material.dart';

import 'app_shape.dart';
import 'aseman_tokens.dart';
import 'design_language.dart';
import 'theme_chrome.dart';

/// Shared surface colour and frost. Overlays (sheets, dialogs, floating
/// panels) use translucent glass; **in-page** cards stay quiet — a single
/// tint and hairline border, no gradient washes or decorative shadows.
///
/// Glass needs a real backdrop: do not put [Opacity] / [FadeTransition]
/// above a [GlassSurface], and keep host [Scaffold] backgrounds transparent
/// so the frost is not painted over an opaque fill.
///
/// Prefer the `*Of(context)` helpers so installed theme packs can override
/// alphas, blur and radii via [AsemanTokens].
abstract final class AppSurfaces {
  /// Opacity of in-page cards and panels over the page.
  /// High by default so content cards read as quiet surfaces, not tinted glass.
  static const cardAlpha = .94;

  /// Opacity of modal chrome (sheets, dialogs, floating panels, menus).
  static const overlayAlpha = .82;

  /// White veil on light pages. Same translucency as dark glass.
  static const lightTint = Color(0xFFFFFFFF);

  /// Backdrop blur strength for glass surfaces.
  static const blurSigma = 18.0;

  /// Scrim behind every modal surface.
  static const barrier = Colors.black54;

  static AsemanTokens? _tok(AsemanTokens? tokens) => tokens;

  static double cardAlphaResolved([AsemanTokens? tokens]) =>
      _tok(tokens)?.cardAlpha ?? cardAlpha;

  static double overlayAlphaResolved([AsemanTokens? tokens]) =>
      _tok(tokens)?.overlayAlpha ?? overlayAlpha;

  static double blurSigmaResolved([AsemanTokens? tokens]) =>
      _tok(tokens)?.blurSigma ?? blurSigma;

  static Color barrierResolved([AsemanTokens? tokens]) =>
      _tok(tokens)?.barrier ?? barrier;

  static double cardAlphaOf(BuildContext context) =>
      cardAlphaResolved(AsemanTokens.maybeOf(context));

  static double overlayAlphaOf(BuildContext context) =>
      overlayAlphaResolved(AsemanTokens.maybeOf(context));

  static double blurSigmaOf(BuildContext context) =>
      blurSigmaResolved(AsemanTokens.maybeOf(context));

  static Color barrierOf(BuildContext context) =>
      barrierResolved(AsemanTokens.maybeOf(context));

  /// Color mixed into glass.
  static Color tint(ColorScheme scheme) => scheme.brightness == Brightness.light
      ? lightTint
      : scheme.surfaceContainerHigh;

  /// How much of [tint] to keep. [overlay] is the modal chrome.
  static double tintAlpha(
    ColorScheme scheme, {
    bool overlay = false,
    AsemanTokens? tokens,
  }) =>
      overlay
          ? overlayAlphaResolved(tokens)
          : cardAlphaResolved(tokens);

  /// True when [alpha] is one of the shared glass opacities (or unset).
  static bool standardAlpha(double? alpha, [AsemanTokens? tokens]) {
    if (alpha == null) return true;
    final card = cardAlphaResolved(tokens);
    final overlay = overlayAlphaResolved(tokens);
    return alpha == card ||
        alpha == overlay ||
        alpha == cardAlpha ||
        alpha == overlayAlpha;
  }

  /// Background of every modal surface.
  static Color overlay(ColorScheme scheme, {AsemanTokens? tokens}) =>
      tint(scheme).withValues(
          alpha: tintAlpha(scheme, overlay: true, tokens: tokens));

  /// Background of in-page cards and panels.
  static Color card(ColorScheme scheme, {AsemanTokens? tokens}) =>
      tint(scheme)
          .withValues(alpha: tintAlpha(scheme, tokens: tokens));

  /// Outline drawn around in-page cards and panels.
  static Color cardBorder(ColorScheme scheme) =>
      scheme.outlineVariant.withValues(alpha: .4);

  static ShapeBorder overlayShapeOf([AsemanTokens? tokens]) =>
      tokens?.overlayShape ??
      const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppShape.card)),
      );

  static ShapeBorder sheetShapeOf([AsemanTokens? tokens]) =>
      tokens?.sheetShape ??
      const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppShape.card)),
      );

  static const overlayShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppShape.card)),
  );

  static const sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(AppShape.card)),
  );

  static BorderRadius cardRadius(
          [double radius = AppShape.inner, AsemanTokens? tokens]) {
    final card = tokens?.control('card');
    if (card != null) {
      if (card.shape == ShapeKind.sharp) return BorderRadius.zero;
      if (card.shape == ShapeKind.stadium) return BorderRadius.circular(999);
      return card.borderRadius;
    }
    return BorderRadius.circular(radius == AppShape.inner
        ? (tokens?.radiusInner ?? radius)
        : radius);
  }

  /// Quiet in-page card: flat tint + hairline. Prefer [GlassSurface] /
  /// [AppCard] when the surface should also frost what sits behind it.
  static BoxDecoration cardDecoration(
    BuildContext context, {
    double? radius,
    Color? accent,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    return BoxDecoration(
      color: card(scheme, tokens: tokens),
      borderRadius: ThemeChrome.softCardCorners(
        context,
        radius ?? AppShape.inner,
      ),
      border: Border.all(
        color: accent?.withValues(alpha: .35) ?? cardBorder(scheme),
      ),
    );
  }
}
