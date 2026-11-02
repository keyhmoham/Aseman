import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_surfaces.dart';
import '../../core/theme/halo_ring_cache.dart';

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

  /// Convenience from a [ColorScheme].
  factory SkyAtmospherePainter.of(ColorScheme scheme) => SkyAtmospherePainter(
        primary: scheme.primary,
        tertiary: scheme.tertiary,
        cyan: AppColors.cyan,
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
    final r = size * .34;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r.clamp(10, 16)),
        color: a.withValues(alpha: .12),
        border: Border.all(color: a.withValues(alpha: .16)),
      ),
      child: Icon(
        icon,
        size: iconSize ?? (size * .48),
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
  });

  final Widget child;

  /// Stable person/agent key; empty uses [accent] instead of the cache.
  final String identity;

  final Color? accent;

  /// Ring stroke width (and inset around [child]).
  final double pad;

  @override
  Widget build(BuildContext context) {
    final colors = identity.trim().isNotEmpty
        ? HaloRingCache.colorsFor(identity)
        : _accentSweep(accent ?? Theme.of(context).colorScheme.primary);
    return CustomPaint(
      painter: _HaloRingPainter(colors: colors, stroke: pad),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: child,
      ),
    );
  }

  static List<Color> _accentSweep(Color accent) => [
        accent,
        accent.withValues(alpha: .22),
        AppColors.cyan.withValues(alpha: .75),
        accent,
      ];
}

class _HaloRingPainter extends CustomPainter {
  const _HaloRingPainter({required this.colors, required this.stroke});
  final List<Color> colors;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - stroke / 2;
    if (radius <= 0 || colors.isEmpty) return;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = SweepGradient(colors: colors).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..isAntiAlias = true;
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _HaloRingPainter old) =>
      old.stroke != stroke || !_sameColors(old.colors, colors);

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
    return HaloRing(
      identity: identity,
      accent: accentColor,
      child: CircleAvatar(
        radius: radius,
        backgroundColor: scheme.surface,
        foregroundImage: foregroundImage,
        onForegroundImageError:
            foregroundImage == null ? null : (_, __) {},
        child: icon != null
            ? Icon(icon, color: accentColor, size: radius)
            : child,
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
    final field = TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: enabled,
      readOnly: readOnly,
      onTap: onTap,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: TextStyle(fontSize: dense ? 13 : 14.5),
      decoration: InputDecoration(
        prefixIcon: Icon(
          Icons.search_rounded,
          size: dense ? 20 : 22,
          color: scheme.onSurfaceVariant,
        ),
        suffixIcon: trailing,
        hintText: hintText,
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: .42),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 8,
          vertical: dense ? 10 : 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: AppSurfaces.cardBorder(scheme)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: AppSurfaces.cardBorder(scheme)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: AppSurfaces.cardBorder(scheme)),
        ),
      ),
    );
    return field;
  }
}

/// Quiet (default) or restrained accent fill for cards.
///
/// Default is flat [AppSurfaces.card] + hairline. Pass [wash] for a light
/// single-accent tint (You-tab stages, selected portals) — not a multi-stop
/// cinematic gradient.
BoxDecoration softSurfaceDecoration(
  ColorScheme scheme, {
  required Color accent,
  Color? secondary,
  double radius = AppShape.inner,
  bool selected = false,
  bool elevated = false,
  bool shadow = true,
  bool wash = false,
}) {
  final Color fill;
  if (selected) {
    fill = accent.withValues(alpha: .14);
  } else if (wash) {
    fill = Color.alphaBlend(
      accent.withValues(alpha: .08),
      AppSurfaces.card(scheme),
    );
  } else {
    fill = AppSurfaces.card(scheme);
  }
  return BoxDecoration(
    color: fill,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: selected
          ? accent.withValues(alpha: .55)
          : AppSurfaces.cardBorder(scheme),
      width: selected ? 1.4 : 1,
    ),
    boxShadow: !shadow || (!elevated && !selected)
        ? null
        : [
            BoxShadow(
              color: Colors.black.withValues(alpha: elevated ? .08 : .05),
              blurRadius: elevated ? 16 : 10,
              offset: const Offset(0, 4),
            ),
          ],
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
    final accentColor = accent ?? scheme.primary;
    final corners = BorderRadius.circular(radius);

    final fill = softSurfaceDecoration(
      scheme,
      accent: accentColor,
      secondary: secondary,
      radius: radius,
      selected: selected,
      elevated: elevated,
      wash: wash,
      shadow: false,
    );
    final shadows = softSurfaceDecoration(
      scheme,
      accent: accentColor,
      secondary: secondary,
      radius: radius,
      selected: selected,
      elevated: elevated,
      wash: wash,
    ).boxShadow;

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
        Padding(padding: padding, child: child),
      ],
    );

    final painted = onTap == null
        ? ClipRRect(
            borderRadius: corners,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              decoration: fill,
              child: content,
            ),
          )
        : Material(
            color: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: corners),
            child: InkWell(
              onTap: onTap,
              child: Ink(decoration: fill, child: content),
            ),
          );

    if (shadows == null || shadows.isEmpty) return painted;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: corners, boxShadow: shadows),
      child: painted,
    );
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
                  borderRadius: BorderRadius.circular(12),
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
      accent: accentColor,
      elevated: false,
      showOrb: false,
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      radius: 22,
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
    return Container(
      decoration: BoxDecoration(
        color: AppSurfaces.card(scheme),
        borderRadius: BorderRadius.circular(AppShape.inner),
        border: Border.all(color: AppSurfaces.cardBorder(scheme)),
      ),
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
    final ink = danger ? AppColors.danger : scheme.onSurface;
    final accentColor =
        danger ? AppColors.danger : (accent ?? scheme.primary);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
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
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(11),
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
                        ? AppColors.danger.withValues(alpha: .7)
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
      trailing: Switch.adaptive(value: value, onChanged: onChanged),
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
Color portalAccentFor(String name, ColorScheme scheme) {
  const extras = [AppColors.cyan, AppColors.success, Color(0xFFFF8F6B)];
  final palette = <Color>[
    scheme.primary,
    scheme.tertiary,
    scheme.secondary,
    ...extras,
  ];
  return palette[name.hashCode.abs() % palette.length];
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(8),
      ),
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
