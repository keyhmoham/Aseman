import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';
import '../../core/theme/app_surfaces.dart';

/// Frosted glass fill used across the app: a light blur of whatever sits
/// behind plus a translucent surface tint from [AppSurfaces].
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

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      if (onTap == null) return child;
      final radius = borderRadius ?? BorderRadius.circular(AppShape.card - 4);
      return Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: onTap, borderRadius: radius, child: child),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final radius = borderRadius ?? BorderRadius.circular(AppShape.card - 4);
    final sigma = blur ?? AppSurfaces.blurSigma;
    // Light pages use a white veil at the same opacity as dark glass.
    // The dark container role sits on the light page and the frost vanishes;
    // raising that opacity toward 1 paints a solid panel instead.
    final standard = color == null && AppSurfaces.standardAlpha(alpha);
    final light = scheme.brightness == Brightness.light && standard;
    final fill =
        (light
                ? AppSurfaces.tint(scheme)
                : (color ?? scheme.surfaceContainerHigh))
            .withValues(
              alpha: light
                  ? AppSurfaces.tintAlpha(
                      scheme,
                      overlay: alpha == AppSurfaces.overlayAlpha,
                    )
                  : (alpha ?? AppSurfaces.cardAlpha),
            );
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Material(
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: border
                ? BorderSide(color: AppSurfaces.cardBorder(scheme))
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: onTap == null
              ? child
              : InkWell(onTap: onTap, borderRadius: radius, child: child),
        ),
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
    final radius = shape is RoundedRectangleBorder
        ? (shape as RoundedRectangleBorder).borderRadius.resolve(
            Directionality.maybeOf(context) ?? TextDirection.ltr,
          )
        : AppSurfaces.cardRadius(AppShape.card);
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
    final side = Directionality.of(context) == TextDirection.rtl
        ? const BorderRadius.only(
            topLeft: Radius.circular(AppShape.card),
            bottomLeft: Radius.circular(AppShape.card),
          )
        : const BorderRadius.only(
            topRight: Radius.circular(AppShape.card),
            bottomRight: Radius.circular(AppShape.card),
          );
    return GlassSurface(
      alpha: AppSurfaces.overlayAlpha,
      blur: AppSurfaces.blurSigma,
      borderRadius: side,
      border: false,
      child: child,
    );
  }
}
