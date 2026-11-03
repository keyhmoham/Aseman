import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_surfaces.dart';
import '../../core/theme/aseman_tokens.dart';
import '../../core/theme/control_look.dart';
import '../../core/theme/design_language.dart';
import '../../core/theme/halo_ring_cache.dart';
import '../../core/theme/theme_chrome.dart';
import '../../core/theme/theme_pack.dart';
import '../../core/theme/theme_roles.dart';
import 'avatar_face.dart';

/// Aseman UI primitives — quiet structure first.
///
/// Everyday pages use flat tinted surfaces, tonal icon wells, and type for
/// hierarchy. Signature atmospheres (workspace switcher portals, auth glow,
/// You-tab stages) opt into [wash] / [SkyAtmospherePainter] deliberately —
/// they are not the default for every card.

/// Soft dual/triple-orb wash — primary, cyan, tertiary. Safe under glass:
/// never wrap this (or its host frost) in [Opacity].
class SkyAtmospherePainter extends CustomPainter {
  const SkyAtmospherePainter({
    required this.primary,
    required this.tertiary,
    this.cyan = AppColors.cyan,
    this.dark = true,
  });

  /// Convenience from a [ColorScheme] (+ optional pack cyan).
  factory SkyAtmospherePainter.of(ColorScheme scheme, {Color? cyan}) =>
      SkyAtmospherePainter(
        primary: scheme.primary,
        tertiary: scheme.tertiary,
        cyan: cyan ?? scheme.secondary,
        dark: scheme.brightness == Brightness.dark,
      );

  final Color primary;
  final Color tertiary;
  final Color cyan;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final a = dark ? .22 : .14;
    final b = dark ? .14 : .09;
    void orb(Offset c, double r, Color color, double alpha) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    orb(Offset(size.width * .12, size.height * .08), size.width * .42,
        primary, a);
    orb(Offset(size.width * .92, size.height * .18), size.width * .34, cyan, b);
    orb(Offset(size.width * .55, size.height * .95), size.width * .4, tertiary,
        b * .85);
    // Soft crown glow so pages without a top sheet still feel lit.
    orb(Offset(size.width * .5, -size.width * .08), size.width * .38, primary,
        a * .7);
  }

  @override
  bool shouldRepaint(covariant SkyAtmospherePainter old) =>
      old.primary != primary ||
      old.tertiary != tertiary ||
      old.cyan != cyan ||
      old.dark != dark;
}

/// Full-bleed atmospheric backdrop. Put content in [child]; the wash is
/// non-interactive.
class SkyBackdrop extends StatelessWidget {
  const SkyBackdrop({super.key, required this.child, this.absorb = true});

  final Widget child;

  /// When true, paints [scaffoldBackgroundColor] under the orbs so pages
  /// that use a transparent [Material] still have a base.
  final bool absorb;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (absorb)
          ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: SkyAtmospherePainter.of(scheme)),
          ),
        ),
        child,
      ],
    );
  }
}

/// Uppercase letterspaced caption used above titles ("NOW", stage eyebrows).
class EyebrowLabel extends StatelessWidget {
  const EyebrowLabel(
    this.text, {
    super.key,
    this.color,
    this.size = 10.5,
  });

  final String text;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: size,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w800,
        color: color ?? scheme.primary,
        height: 1.1,
      ),
    );
  }
}

/// Tonal icon well for section headers — rounded square, no glow wash.
class SkyIconBadge extends StatelessWidget {
  const SkyIconBadge({
    super.key,
    required this.icon,
    this.size = 46,
    this.iconSize,
    this.accent,
    this.secondary,
  });

  final IconData icon;
  final double size;
  final double? iconSize;
  final Color? accent;
  /// Kept for call-site compatibility; unused (no dual-tone wash).
  final Color? secondary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = accent ?? scheme.primary;
    final packIcon = AsemanTokens.maybeOf(context)?.language.iconSize;
    return Container(
      width: size,
      height: size,
      decoration: context.iconWellDecoration(accent: a, size: size),
      child: Icon(
        icon,
        size: iconSize ?? packIcon ?? (size * .48),
        color: a,
      ),
    );
  }
}

/// Soft title + subtitle row with optional [SkyIconBadge] and trailing actions.
class SkySectionHeader extends StatelessWidget {
  const SkySectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.eyebrow,
    this.actions = const [],
    this.dense = false,
    this.onClose,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? eyebrow;
  final List<Widget> actions;
  final bool dense;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final close = onClose == null
        ? null
        : IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            style: IconButton.styleFrom(
              backgroundColor:
                  scheme.surfaceContainerHighest.withValues(alpha: .45),
            ),
            icon: const Icon(Icons.close_rounded),
          );
    final titleStyle = TextStyle(
      fontSize: dense ? 17 : 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -.4,
      height: 1.15,
      color: scheme.onSurface,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          SkyIconBadge(icon: icon!, size: dense ? 36 : 46),
          SizedBox(width: dense ? 10 : 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (eyebrow != null) ...[
                EyebrowLabel(eyebrow!, size: dense ? 9.5 : 10.5),
                const SizedBox(height: 3),
              ],
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: titleStyle),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  maxLines: dense ? 2 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: dense ? 10.5 : 12.5,
                    color: scheme.onSurfaceVariant,
                    height: 1.25,
                  ),
                ),
              ],
            ],
          ),
        ),
        for (final a in actions) ...[
          const SizedBox(width: AppSpacing.xs),
          a,
        ],
        if (close != null) ...[
          const SizedBox(width: AppSpacing.xs),
          close,
        ],
      ],
    );
  }
}

/// Sweep-gradient **ring** around an avatar — stroke only, never a filled
/// disc behind the picture. Applied by shared avatar widgets app-wide.
///
/// Pass [identity] (from [HaloRingCache.person] / [HaloRingCache.agent]) so
/// the same person or agent always gets the same bound colors from the
/// device cache. Without it, [accent] builds a one-off theme-tinted sweep.
class HaloRing extends StatelessWidget {
  const HaloRing({
    super.key,
    required this.child,
    this.identity = '',
    this.accent,
    this.pad = 2.2,
    this.borderRadius,
  });

  final Widget child;

  /// Stable person/agent key; empty uses [accent] instead of the cache.
  final String identity;

  final Color? accent;

  /// Ring stroke width (and inset around [child]).
  final double pad;

  /// When set (or derived from the pack), the halo follows avatar corners
  /// instead of always painting a circle.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    // Unified packs: one halo accent (alpha variants only). Legacy multi-hue
    // identity rings stay only when the pack opts out of unified colouring.
    final tokens = AsemanTokens.maybeOf(context);
    final haloAccent = accent ??
        ThemeRoles.partAccent(context, ThemePartId.halo);
    final haloSecondary =
        ThemeRoles.partSecondary(context, ThemePartId.halo);
    final colors = (tokens != null &&
            !tokens.unifiedAccent &&
            identity.trim().isNotEmpty)
        ? HaloRingCache.colorsFor(identity)
        : _accentSweep(haloAccent, haloSecondary);
    final corners = borderRadius ?? context.avatarBorderRadius(48);
    return CustomPaint(
      painter: _HaloRingPainter(
        colors: colors,
        stroke: pad,
        borderRadius: corners,
      ),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: child,
      ),
    );
  }

  static List<Color> _accentSweep(Color accent, Color cyan) => [
        accent,
        accent.withValues(alpha: .22),
        cyan.withValues(alpha: .75),
        accent,
      ];
}

class _HaloRingPainter extends CustomPainter {
  const _HaloRingPainter({
    required this.colors,
    required this.stroke,
    required this.borderRadius,
  });
  final List<Color> colors;
  final double stroke;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty || size.shortestSide <= stroke) return;
    final inset = stroke / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - stroke,
      size.height - stroke,
    );
    if (rect.width <= 0 || rect.height <= 0) return;
    final circular = borderRadius.topLeft.x >= rect.shortestSide / 2 - 0.5;
    final paint = Paint()
      ..shader = SweepGradient(colors: colors).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..isAntiAlias = true;
    if (circular) {
      canvas.drawCircle(rect.center, rect.shortestSide / 2, paint);
    } else {
      final rrect = borderRadius.toRRect(rect);
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HaloRingPainter old) =>
      old.stroke != stroke ||
      old.borderRadius != borderRadius ||
      !_sameColors(old.colors, colors);

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Sweep-gradient halo around an avatar or icon glyph.
class HaloAvatar extends StatelessWidget {
  const HaloAvatar({
    super.key,
    this.radius = 22,
    this.accent,
    this.identity = '',
    this.foregroundImage,
    this.child,
    this.icon,
  });

  final double radius;
  final Color? accent;

  /// Person/agent cache key (already prefixed via [HaloRingCache]).
  final String identity;
  final ImageProvider? foregroundImage;

  /// When set, used as the circle's label (initials). Prefer [HaloRing] when
  /// wrapping an existing avatar widget such as [AvatarEditor].
  final Widget? child;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentColor = accent ?? scheme.primary;
    final size = radius * 2;
    final corners = context.avatarBorderRadius(size);
    return HaloRing(
      identity: identity,
      accent: accentColor,
      borderRadius: corners,
      child: AvatarFace(
        size: size,
        borderRadius: corners,
        backgroundColor: scheme.surface,
        foregroundImage: foregroundImage,
        child: child ??
            (icon == null
                ? null
                : Icon(icon, color: accentColor, size: radius)),
      ),
    );
  }
}

/// Stadium search / filter field matching the workspace switcher.
class SoftSearchField extends StatelessWidget {
  const SoftSearchField({
    super.key,
    this.controller,
    this.hintText = 'Search…',
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.dense = false,
    this.trailing,
    this.enabled = true,
    this.readOnly = false,
    this.onTap,
  });

  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool dense;
  final Widget? trailing;
  final bool enabled;
  final bool readOnly;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconSz =
        (AsemanTokens.maybeOf(context)?.language.iconSize ?? 22) - (dense ? 2 : 0);
    return TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: enabled,
      readOnly: readOnly,
      onTap: onTap,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: TextStyle(fontSize: dense ? 13 : 14.5),
      decoration: ThemeChrome.searchDecoration(
        context,
        hintText: hintText,
        dense: dense,
        prefixIcon: Icon(
          Icons.search_rounded,
          size: iconSz,
          color: scheme.onSurfaceVariant,
        ),
        suffixIcon: trailing,
      ),
    );
  }
}

/// Quiet (default) or restrained accent fill for cards.
///
/// Default is flat [AppSurfaces.card] + hairline. Pass [wash] for a light
/// single-accent tint (You-tab stages, selected portals) — not a multi-stop
/// cinematic gradient.
BoxDecoration softSurfaceDecoration(
  ColorScheme scheme, {
  Color? accent,
  Color? secondary,
  double radius = AppShape.inner,
  bool selected = false,
  bool elevated = false,
  bool shadow = true,
  bool wash = false,
  AsemanTokens? tokens,
  BorderRadius? borderRadius,
  BuildContext? context,
}) {
  final ink = accent ?? scheme.primary;
  if (context != null) {
    final deco = ThemeChrome.cardDecoration(
      context,
      accent: ink,
      selected: selected,
      elevated: elevated,
      wash: wash,
      radiusOverride: radius,
      borderRadius: borderRadius,
    );
    if (!shadow) {
      return BoxDecoration(
        color: deco.color,
        borderRadius: deco.borderRadius,
        border: deco.border,
      );
    }
    return deco;
  }
  final cardFill = AppSurfaces.card(scheme, tokens: tokens);
  final Color fill;
  if (selected) {
    fill = ink.withValues(alpha: .14);
  } else if (wash) {
    fill = Color.alphaBlend(
      ink.withValues(alpha: .08),
      cardFill,
    );
  } else {
    fill = cardFill;
  }
  final card = tokens?.control('card');
  final shadows = tokens?.language.shadow.resolve(scheme, accent: ink);
  final borderW = selected
      ? math.max(card?.borderWidth ?? 1, 1.4)
      : (card?.borderWidth ?? 1);
  return BoxDecoration(
    color: fill,
    borderRadius: borderRadius ??
        card?.borderRadius ??
        BorderRadius.circular(radius),
    border: borderW > 0
        ? Border.all(
            color: selected
                ? ink.withValues(alpha: .55)
                : AppSurfaces.cardBorder(scheme).withValues(
                    alpha: card != null && card.borderWidth > 0
                        ? card.borderAlpha
                        : 1),
            width: borderW,
          )
        : null,
    boxShadow: !shadow ||
            (!elevated && !selected && (card == null || card.elevation <= 0))
        ? null
        : (shadows ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: elevated ? .08 : .05),
                blurRadius: elevated ? 16 : 10,
                offset: const Offset(0, 4),
              ),
            ]),
  );
}

/// Quiet in-page card. Flat by default; [wash] opts into a light accent tint
/// for signature moments. Corner orbs are off unless [showOrb] is set.
class SoftCard extends StatelessWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.accent,
    this.secondary,
    this.selected = false,
    this.elevated = false,
    this.radius = AppShape.inner,
    this.showOrb = false,
    this.wash = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color? accent;
  final Color? secondary;
  final bool selected;
  final bool elevated;
  final double radius;

  /// Decorative corner glow — prefer false; reserved for rare hero tiles.
  final bool showOrb;

  /// Light accent tint instead of a flat card fill.
  final bool wash;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    final accentColor = _resolveAccent(context, accent) ?? scheme.primary;
    final look = context.controlLook(
      'card',
      selected: selected,
    );
    final card = look.recipe;
    final shape = ThemeChrome.cardShape(
      context,
      accent: accentColor,
      selected: selected,
    );
    // Quiet by default: accent only tints when [wash] / [selected] / orb.
    final fill = ThemeChrome.cardFillColor(
      context,
      accent: accentColor,
      selected: selected,
      wash: wash,
    );
    final wantShadow =
        elevated || selected || card.elevation > 0;
    final shadows = !wantShadow
        ? null
        : (tokens?.language.shadow.resolve(scheme, accent: accentColor) ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: elevated ? .08 : .05),
                blurRadius: elevated ? 16 : 10,
                offset: const Offset(0, 4),
              ),
            ]);

    final pad = identical(padding, const EdgeInsets.all(AppSpacing.md))
        ? look.padding
        : padding;

    final content = Stack(
      fit: StackFit.passthrough,
      children: [
        if (showOrb)
          Positioned(
            right: -18,
            top: -22,
            child: IgnorePointer(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      accentColor.withValues(alpha: selected ? .2 : .08),
                      accentColor.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Padding(padding: pad, child: child),
      ],
    );

    final ink = look.ink;
    Widget painted = Material(
      color: fill,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      clipBehavior: card.clip ? Clip.antiAlias : Clip.none,
      shape: shape,
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              customBorder: shape,
              splashFactory: ThemeChrome.splashFactory(context, ink: ink),
              highlightColor: ThemeChrome.pressHighlight(
                context,
                accent: accentColor,
                ink: ink,
              ),
              splashColor: ThemeChrome.pressSplash(
                context,
                accent: accentColor,
                ink: ink,
              ),
              child: content,
            ),
    );

    if (shadows != null && shadows.isNotEmpty) {
      painted = DecoratedBox(
        decoration: ShapeDecoration(shape: shape, shadows: shadows),
        child: painted,
      );
    }
    return look.decorate(painted);
  }

  /// Remaps legacy [AppColors] status tones onto the active pack.
  static Color? _resolveAccent(BuildContext context, Color? color) {
    if (color == null) return null;
    if (color == AppColors.cyan || color == AppColors.cyanOf(context)) {
      return AppColors.cyanOf(context);
    }
    if (color == AppColors.success || color == AppColors.successOf(context)) {
      return AppColors.successOf(context);
    }
    if (color == AppColors.warning || color == AppColors.warningOf(context)) {
      return AppColors.warningOf(context);
    }
    if (color == AppColors.danger || color == AppColors.dangerOf(context)) {
      return AppColors.dangerOf(context);
    }
    if (color == AppColors.primary || color == AppColors.primaryOf(context)) {
      return AppColors.primaryOf(context);
    }
    return color;
  }
}

/// You-tab destination tile (Store / Wallet). Light accent wash, tonal icon
/// well — the signature moment, not the everyday card style.
class FeatureStageCard extends StatelessWidget {
  const FeatureStageCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.eyebrow,
    this.accent,
    this.secondary,
    this.badges = const [],
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final String? eyebrow;
  final Color? accent;
  final Color? secondary;
  final List<FeatureStageBadge> badges;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentColor = accent ?? scheme.primary;
    return SoftCard(
      onTap: onTap,
      accent: accentColor,
      secondary: secondary,
      wash: true,
      elevated: false,
      showOrb: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: AppShape.borderRadius(context, 12),
                  color: accentColor.withValues(alpha: .12),
                ),
                child: Icon(icon, color: accentColor, size: 22),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (eyebrow != null) ...[
                      EyebrowLabel(eyebrow!, color: accentColor, size: 10),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.3,
                            height: 1.15,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm - 2),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.35,
                ),
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final badge in badges)
                  SoftMetaChip(
                    label: badge.label,
                    icon: badge.icon,
                    accent: accentColor,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class FeatureStageBadge {
  const FeatureStageBadge(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// Accent-gradient "you're here" / callout strip with optional halo.
class DockedBanner extends StatelessWidget {
  const DockedBanner({
    super.key,
    required this.title,
    required this.subtitle,
    this.eyebrow = 'NOW',
    this.accent,
    this.leading,
    this.onTap,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final String eyebrow;
  final Color? accent;
  final Widget? leading;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accentColor = accent ?? scheme.primary;
    return SoftCard(
      onTap: onTap,
      elevated: false,
      showOrb: false,
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                EyebrowLabel(eyebrow, color: accentColor, size: 10),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15.5,
                    letterSpacing: -.2,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          trailing ??
              Icon(Icons.north_east_rounded,
                  size: 18, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// Grouped list chrome — flat fill, hairline, no gradient.
class QuietList extends StatelessWidget {
  const QuietList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = ThemeChrome.cardShape(context);
    final fill = ThemeChrome.cardFillColor(context);
    return Material(
      color: fill,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 52,
                color: AppSurfaces.cardBorder(scheme),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Soft row with tinted icon well — preferred over bare [ListTile].
class QuietTile extends StatelessWidget {
  const QuietTile({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.danger = false,
    this.accent,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = danger ? AppColors.dangerOf(context) : scheme.onSurface;
    final accentColor =
        danger ? AppColors.dangerOf(context) : (accent ?? scheme.primary);
    final tokens = AsemanTokens.maybeOf(context);
    final inkKind = tokens?.control('button').ink ??
        tokens?.language.interaction.ink ??
        InkKind.ripple;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashFactory: ThemeChrome.splashFactory(context, ink: inkKind),
        highlightColor: ThemeChrome.pressHighlight(
          context,
          accent: accentColor,
          ink: inkKind,
        ),
        splashColor: ThemeChrome.pressSplash(
          context,
          accent: accentColor,
          ink: inkKind,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm + 2,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: context.iconWellDecoration(
                  accent: accentColor,
                  size: 34,
                ),
                child: Icon(icon, size: 18, color: accentColor),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              trailing ??
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: danger
                        ? AppColors.dangerOf(context).withValues(alpha: .7)
                        : scheme.onSurfaceVariant,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Soft switch row matching [QuietTile] chrome.
class QuietSwitchTile extends StatelessWidget {
  const QuietSwitchTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return QuietTile(
      icon: icon,
      label: label,
      subtitle: subtitle,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: PackSwitch(value: value, onChanged: onChanged),
    );
  }
}

/// Light stagger — short translate only (no bounce / scale), frost-safe.
class StaggerIn extends StatelessWidget {
  const StaggerIn({
    super.key,
    required this.index,
    required this.child,
    this.reduceMotion,
  });

  final int index;
  final Widget child;
  final bool? reduceMotion;

  @override
  Widget build(BuildContext context) {
    final reduce = reduceMotion ??
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (reduce) return child;
    final delay = math.min(index, 6) * 28;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 280 + delay),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Transform.translate(
          offset: Offset(0, (1 - t) * 8),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// Name-hashed accent from the portal palette (primary / tertiary / cyan / …).
Color portalAccentFor(
  String name,
  ColorScheme scheme, [
  BuildContext? context,
]) {
  if (context != null) {
    return ThemeRoles.identity(context, name);
  }
  return scheme.primary;
}

/// Compact meta chip — tonal fill, no border glow.
class SoftMetaChip extends StatelessWidget {
  const SoftMetaChip({
    super.key,
    required this.label,
    this.icon,
    this.accent,
  });

  final String label;
  final IconData? icon;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = accent ?? scheme.onSurfaceVariant;
    final chip = context.chipRecipe;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: chip.paddingH.clamp(6, 12),
        vertical: chip.paddingV.clamp(2, 8),
      ),
      decoration: context.metaChipDecoration(accent: color),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
