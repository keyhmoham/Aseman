import 'package:flutter/widgets.dart';

import 'aseman_tokens.dart';
import 'theme_chrome.dart';

/// Corner radii shared by every surface in the app.
///
/// Prefer [cardOf] / [innerOf] / [controlOf] / [fabOf] in widgets so installed
/// theme packs can reshape chrome. The constants remain as Sky defaults and
/// sentinel values SoftCard remaps through [AsemanTokens].
abstract final class AppShape {
  /// Cards, dialogs, bottom sheets and floating panels.
  static const card = 28.0;
  static const inner = 20.0;
  static const control = 16.0;

  /// Material 3 Expressive FAB container corners (size-adaptive).
  /// Leave [ThemeData.floatingActionButtonTheme.shape] null so Flutter picks
  /// these per size; use the matching constant on hand-rolled FAB circles.
  static const fab = 16.0;
  static const fabSmall = 12.0;
  static const fabLarge = 28.0;

  static double cardOf(BuildContext context) => context.radiusCard;
  static double innerOf(BuildContext context) => context.radiusInner;
  static double controlOf(BuildContext context) => context.radiusControl;
  static double fabOf(BuildContext context) {
    final t = AsemanTokens.maybeOf(context);
    return t?.control('fab').radius ?? t?.radiusFab ?? fab;
  }

  static double fabSmallOf(BuildContext context) {
    final t = AsemanTokens.maybeOf(context);
    return t?.radiusFabSmall ?? fabSmall;
  }

  static double fabLargeOf(BuildContext context) {
    final t = AsemanTokens.maybeOf(context);
    return t?.radiusFabLarge ?? fabLarge;
  }

  /// True when [radius] is one of the shared Sky sentinel constants.
  static bool isSentinel(double radius) =>
      radius == card ||
      radius == inner ||
      radius == control ||
      radius == fab ||
      radius == fabSmall ||
      radius == fabLarge;

  static double _packBase(AsemanTokens t, double base) {
    if (base == card) return t.control('card').radius;
    if (base == inner) return t.radiusInner;
    if (base == control) return t.radiusControl;
    if (base == fab) return t.radiusFab;
    if (base == fabSmall) return t.radiusFabSmall;
    if (base == fabLarge) return t.radiusFabLarge;
    return base;
  }

  /// Maps a sentinel [radius] (or a small offset from one) through the active
  /// pack. Hard-coded literals that match Sky defaults (`12`/`16`/`20`/`28`)
  /// also remap so feature screens that never used [AppShape] still follow
  /// installed themes.
  static double resolve(BuildContext context, double radius) {
    final t = AsemanTokens.maybeOf(context);
    if (t == null) return radius;
    if (isSentinel(radius)) return _packBase(t, radius);

    // Prefer the closest Sky sentinel within ±8 so `AppShape.card - 2` and
    // friends still track the pack. Exact equality already handled above.
    const bases = <double>[card, inner, control, fabLarge, fab, fabSmall];
    double? bestBase;
    var bestDelta = 9.0;
    for (final base in bases) {
      final delta = radius - base;
      final abs = delta.abs();
      if (abs <= 8 && abs < bestDelta) {
        bestDelta = abs;
        bestBase = base;
      }
    }
    if (bestBase != null) {
      return (_packBase(t, bestBase) + (radius - bestBase)).clamp(0.0, 128.0);
    }
    return radius;
  }

  /// Theme-aware [BorderRadius.circular] for any Sky-aligned corner value.
  static BorderRadius borderRadius(BuildContext context, double radius) =>
      BorderRadius.circular(resolve(context, radius));

  /// Resolves every corner of [input] through [resolve].
  static BorderRadius resolveBorderRadius(
    BuildContext context,
    BorderRadius input,
  ) {
    Radius map(Radius r) => Radius.circular(resolve(context, r.x));
    return BorderRadius.only(
      topLeft: map(input.topLeft),
      topRight: map(input.topRight),
      bottomLeft: map(input.bottomLeft),
      bottomRight: map(input.bottomRight),
    );
  }
}
