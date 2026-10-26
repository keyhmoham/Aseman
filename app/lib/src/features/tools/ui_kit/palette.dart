/// Colors of the data widgets. Categorical hues are assigned in this fixed
/// order (never cycled: a ninth series folds into "Other"); magnitude uses
/// one blue ramp, polarity blue ↔ red through a neutral gray, and status
/// colors are reserved for state and always come with an icon or a label.
/// Light and dark are each their own validated steps, not a flip.
library;

import 'package:flutter/material.dart';

class VizPalette {
  const VizPalette._(this.dark, this.scheme, this.baseText);

  factory VizPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    return VizPalette._(theme.brightness == Brightness.dark, theme.colorScheme,
        DefaultTextStyle.of(context).style);
  }

  final bool dark;
  final ColorScheme scheme;

  /// The ambient text style: canvas text (axes, labels painted by charts)
  /// does not inherit it the way Text widgets do, so it is merged in.
  final TextStyle baseText;

  /// [style] in the app's font.
  TextStyle font(TextStyle style) => baseText
      .copyWith(decoration: TextDecoration.none, letterSpacing: 0)
      .merge(style);

  static const List<Color> _categoricalLight = [
    Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), //
    Color(0xFFEDA100), Color(0xFFE87BA4), Color(0xFF008300),
    Color(0xFF6250D6), Color(0xFFE34948),
  ];
  static const List<Color> _categoricalDark = [
    Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70), //
    Color(0xFFC98500), Color(0xFFD55181), Color(0xFF008300),
    Color(0xFF9085E9), Color(0xFFE66767),
  ];

  /// The blue ramp, light → dark (steps 100…700).
  static const List<Color> sequentialRamp = [
    Color(0xFFCDE2FB), Color(0xFFB7D3F6), Color(0xFF9EC5F4), //
    Color(0xFF86B6EF), Color(0xFF6DA7EC), Color(0xFF5598E7),
    Color(0xFF3987E5), Color(0xFF2A78D6), Color(0xFF256ABF),
    Color(0xFF1C5CAB), Color(0xFF184F95), Color(0xFF104281),
    Color(0xFF0D366B),
  ];

  static const Color _red = Color(0xFFD03B3B);

  static const Color good = Color(0xFF0CA30C);
  static const Color warning = Color(0xFFFAB219);
  static const Color serious = Color(0xFFEC835A);
  static const Color critical = Color(0xFFD03B3B);

  /// The maximum number of categorical series before folding to "Other".
  static const int maxSeries = 8;

  List<Color> get categorical => categoricalOf(dark);

  /// The person's accent: the color of single-valued views (a tag, a
  /// progress bar, a sparkline) so they read as part of the app.
  Color get accent => scheme.primary;

  /// A soft tonal fill of [color] on the surface (tags, callouts, icon
  /// containers).
  Color tonal(Color color, [double strength = 1]) =>
      Color.lerp(scheme.surface, color, (dark ? 0.26 : 0.16) * strength)!;

  /// Ink of [color] that reads on its [tonal] fill.
  Color onTonal(Color color) => Color.lerp(
    color,
    dark ? Colors.white : Colors.black,
    dark ? 0.45 : 0.35,
  )!;


  /// The categorical slots for a light or dark surface.
  static List<Color> categoricalOf(bool dark) =>
      dark ? _categoricalDark : _categoricalLight;

  /// Categorical slot [i] (0-based); past the eighth, the "Other" gray.
  Color series(int i) => i >= 0 && i < maxSeries ? categorical[i] : other;

  Color get other => dark ? const Color(0xFF6F6E69) : const Color(0xFF9A9993);

  Color get surface => dark ? const Color(0xFF1A1A19) : const Color(0xFFFCFCFB);
  Color get textPrimary => scheme.onSurface;
  Color get textSecondary => scheme.onSurfaceVariant;
  Color get textMuted => scheme.onSurfaceVariant.withValues(alpha: 0.72);

  /// Gridlines and axes: one step off the surface, hairline.
  Color get grid => dark ? const Color(0xFF34342F) : const Color(0xFFE6E5E0);
  Color get axis => dark ? const Color(0xFF4A4A44) : const Color(0xFFCFCEC8);

  /// A soft fill behind a hovered band or row.
  Color get hover => scheme.onSurface.withValues(alpha: dark ? 0.08 : 0.05);

  Color get neutral => dark ? const Color(0xFF383835) : const Color(0xFFF0EFEC);

  /// The sequential color of [t] in 0..1 (0 = near zero, recedes).
  Color sequential(double t) {
    final ramp = dark ? sequentialRamp.reversed.toList() : sequentialRamp;
    return _sample(ramp, t);
  }

  /// The diverging color of [t] in -1..1: red ← neutral → blue.
  Color diverging(double t) {
    final c = t.clamp(-1.0, 1.0);
    final pole = c >= 0 ? series(0) : _red;
    return Color.lerp(neutral, pole, c.abs())!;
  }

  Color status(String? name) => switch (name) {
        'good' || 'success' || 'positive' || 'up' => good,
        'warning' || 'warn' => warning,
        'serious' => serious,
        'critical' || 'error' || 'danger' || 'negative' || 'down' => critical,
        _ => scheme.primary,
      };

  /// A color spec: `#RRGGBB` / `#AARRGGBB`, a series slot (`series-3`, `3`),
  /// a hue name of the categorical set, a status name, `primary`, `muted`.
  Color? parse(Object? spec, {int index = 0}) {
    if (spec is! String || spec.isEmpty) return null;
    final s = spec.trim();
    if (s.startsWith('#')) {
      final hex = s.substring(1);
      final n = int.tryParse(hex, radix: 16);
      if (n == null) return null;
      if (hex.length == 6) return Color(0xFF000000 | n);
      if (hex.length == 8) return Color(n);
      if (hex.length == 3) {
        final r = (n >> 8) & 0xF, g = (n >> 4) & 0xF, b = n & 0xF;
        return Color.fromARGB(255, r * 17, g * 17, b * 17);
      }
      return null;
    }
    final slot = int.tryParse(s.replaceFirst('series-', ''));
    if (slot != null) return series(slot - 1);
    const hues = [
      'blue',
      'orange',
      'aqua',
      'yellow',
      'magenta',
      'green',
      'violet',
      'red'
    ];
    final hue = hues.indexOf(s);
    if (hue >= 0) return series(hue);
    return switch (s) {
      'primary' || 'accent' => scheme.primary,
      'muted' || 'gray' || 'grey' || 'other' => other,
      'good' ||
      'success' ||
      'positive' ||
      'warning' ||
      'serious' ||
      'critical' ||
      'error' ||
      'danger' ||
      'negative' =>
        status(s),
      _ => null,
    };
  }

  /// Ink that reads on [fill]: white or near-black by luminance.
  static Color onFill(Color fill) => fill.computeLuminance() > 0.45
      ? const Color(0xFF0B0B0B)
      : const Color(0xFFFFFFFF);

  static Color _sample(List<Color> ramp, double t) {
    final x = t.clamp(0.0, 1.0) * (ramp.length - 1);
    final i = x.floor().clamp(0, ramp.length - 2);
    return Color.lerp(ramp[i], ramp[i + 1], x - i)!;
  }
}

/// Text styles shared by the data widgets: labels and values wear text
/// tokens, never the series color.
class VizText {
  static TextStyle label(VizPalette p) =>
      p.font(TextStyle(fontSize: 11, color: p.textSecondary, height: 1.2));

  static TextStyle value(VizPalette p) => p.font(TextStyle(
      fontSize: 12,
      color: p.textPrimary,
      fontWeight: FontWeight.w500,
      height: 1.2,
      fontFeatures: const [FontFeature.tabularFigures()]));

  static TextStyle title(VizPalette p) => p.font(
    TextStyle(
      fontSize: 16,
      color: p.textPrimary,
      fontWeight: FontWeight.w600,
      height: 1.25,
    ),
  );

  static TextStyle subtitle(VizPalette p) =>
      p.font(TextStyle(fontSize: 12, color: p.textSecondary));
}
