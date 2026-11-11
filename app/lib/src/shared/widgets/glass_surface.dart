import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import '../../core/theme/app_surfaces.dart';
import '../../core/theme/aseman_tokens.dart';
import '../../core/theme/design_language.dart';
import '../../core/theme/theme_chrome.dart';

/// Frosted glass fill used across the app: a light blur of whatever sits
/// behind plus a translucent surface tint from [AppSurfaces].
///
/// Packs that use solid / flat / neo-brutal languages skip frost and clip to
/// the card recipe's true shape (sharp / cut / stadium), not a Material RRect.
///
/// When this surface is the body of content shown inside [showAppSheet],
/// pass [embedded] so the sheet owns the frost and this widget stays
/// transparent. Nested cards inside a sheet should leave [embedded] false.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.onTap,
    this.color,
    this.alpha,
    this.blur,
    this.border = true,
    this.embedded = false,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;

  /// Tint under the blur; defaults to `surfaceContainerHigh`.
  final Color? color;

  /// Surface tint opacity over the blur; defaults to [AppSurfaces.cardAlpha].
  final double? alpha;

  /// Backdrop blur strength; defaults to [AppSurfaces.blurSigma].
  final double? blur;

  /// Soft outline matching [AppSurfaces.cardBorder].
  final bool border;

  /// Skip frost/fill — the host ([showAppSheet], [FloatingPanelSurface], …)
  /// already paints glass. Use for content-container bodies shown in a sheet.
  final bool embedded;

  OutlinedBorder _shape(BuildContext context, BorderRadius? radius) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final card = tokens?.control('card');
    if (radius != null) {
      final tl = radius.topLeft.x;
      final uniform = tl == radius.topRight.x &&
          tl == radius.bottomLeft.x &&
          tl == radius.bottomRight.x;
      // Asymmetric radii (sheets / drawers) stay as rounded rects.
      if (!uniform) {
        return RoundedRectangleBorder(
          borderRadius: radius,
          side: border
              ? BorderSide(color: AppSurfaces.cardBorder(scheme))
              : BorderSide.none,
        );
      }
    }
    if (card != null) {
      return ThemeChrome.outlinedBorder(
        card,
        sideColor: border ? AppSurfaces.cardBorder(scheme) : null,
        borderWidth: border ? (card.borderWidth > 0 ? card.borderWidth : 1) : 0,
      );
    }
    final corners = radius ??
        ThemeChrome.softCardCorners(context, AppShape.card - 4);
    return RoundedRectangleBorder(
      borderRadius: corners,
      side: border
          ? BorderSide(color: AppSurfaces.cardBorder(scheme))
          : BorderSide.none,
    );
  }

  BorderRadius _resolveRadius(BuildContext context, BorderRadius? input) {
    if (input == null) {
      return ThemeChrome.softCardCorners(context, AppShape.card - 4);
    }
    final tl = input.topLeft.x;
    final uniform = tl == input.topRight.x &&
        tl == input.bottomLeft.x &&
        tl == input.bottomRight.x;
    if (uniform &&
        (AppShape.isSentinel(tl) ||
            (tl - AppShape.card).abs() <= 8 ||
            (tl - AppShape.inner).abs() <= 8)) {
      return ThemeChrome.softCardCorners(context, tl);
    }
    return AppShape.resolveBorderRadius(context, input);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AsemanTokens.maybeOf(context);
    final card = tokens?.control('card');
    final ink = card?.ink ??
        tokens?.language.interaction.ink ??
        InkKind.ripple;

    if (embedded) {
      if (onTap == null) return child;
      final shape = _shape(context, borderRadius);
      return PackInkWell(
        onTap: onTap,
        shape: shape,
        slot: 'card',
        child: child,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final radius = _resolveRadius(context, borderRadius);
    final shape = _shape(context, borderRadius ?? radius);
    final sigma = blur ?? AppSurfaces.blurSigmaResolved(tokens);
    final overlayA = AppSurfaces.overlayAlphaResolved(tokens);
    final cardA = AppSurfaces.cardAlphaResolved(tokens);
    // Modal chrome (sheets, drawers, floating panels) is asked for with the
    // overlay opacity and follows the pack's sheet recipe; anything else is
    // an in-page card and follows its card recipe. A pack can keep cards
    // quiet and opaque while its overlays stay frosted glass.
    final overlay =
        alpha != null &&
        (alpha == overlayA || alpha == AppSurfaces.overlayAlpha);
    final slot = overlay ? 'sheet' : 'card';
    final recipe = tokens?.control(slot);
    final useBlur =
        (blur != null && blur! > 0) ||
        (blur == null && ThemeChrome.wantsGlassBlur(context, slot: slot));
    final standard = color == null && AppSurfaces.standardAlpha(alpha, tokens);
    final light = scheme.brightness == Brightness.light && standard;
    final solidFill =
        recipe?.fill == FillKind.solid ||
        recipe?.fill == FillKind.outline ||
        !useBlur;
    final fill = solidFill
        ? (color ??
              (recipe?.fill == FillKind.solid
                  ? scheme.surface
                  : AppSurfaces.card(scheme, tokens: tokens)))
        : (light
                  ? AppSurfaces.tint(scheme)
                  : (color ?? scheme.surfaceContainerHigh))
              .withValues(
                alpha: light
                    ? AppSurfaces.tintAlpha(
                        scheme,
                        overlay: overlay,
                        tokens: tokens,
                      )
                    : (alpha ?? cardA),
              );

    Widget body = Material(
      color: fill,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? child
          : InkWell(
              onTap: onTap,
              customBorder: shape,
              splashFactory: ThemeChrome.splashFactory(context, ink: ink),
              highlightColor: ThemeChrome.pressHighlight(
                context,
                ink: ink,
              ),
              splashColor: ThemeChrome.pressSplash(context, ink: ink),
              child: child,
            ),
    );

    if (!useBlur || solidFill) return body;

    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: body,
      ),
    );
  }
}

/// Drop-in glass [Card]: same margins/clipping as Material cards, frosted.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.margin = EdgeInsets.zero,
    this.color,
    this.clipBehavior = Clip.antiAlias,
    this.shape,
    this.embedded = false,
  });

  final Widget child;
  final EdgeInsetsGeometry margin;
  final Color? color;
  final Clip clipBehavior;
  final ShapeBorder? shape;

  /// When true the card body stays clear so a host sheet/panel paints glass.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    BorderRadius? radius;
    if (shape is RoundedRectangleBorder) {
      radius = (shape as RoundedRectangleBorder).borderRadius.resolve(
            Directionality.maybeOf(context) ?? TextDirection.ltr,
          );
    } else if (shape == null) {
      radius = ThemeChrome.softCardCorners(context, AppShape.card);
    }
    return Padding(
      padding: margin,
      child: GlassSurface(
        color: color,
        borderRadius: radius,
        border: !embedded,
        embedded: embedded,
        child: child,
      ),
    );
  }
}

/// Frosted fill for [Drawer] / side rails. Host [Drawer] must be transparent
/// (`backgroundColor: Colors.transparent`) so the blur is not painted over
/// an opaque Material.
class GlassDrawerSurface extends StatelessWidget {
  const GlassDrawerSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = AsemanTokens.maybeOf(context);
    final corners = ThemeChrome.softCardCorners(context, AppShape.card);
    final r = corners.topLeft;
    final side = Directionality.of(context) == TextDirection.rtl
        ? BorderRadius.only(topLeft: r, bottomLeft: r)
        : BorderRadius.only(topRight: r, bottomRight: r);
    return GlassSurface(
      alpha: AppSurfaces.overlayAlphaResolved(tokens),
      blur: AppSurfaces.blurSigmaResolved(tokens),
      borderRadius: side,
      border: false,
      child: child,
    );
  }
}
