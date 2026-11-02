import 'package:flutter/painting.dart';

/// Vertical and horizontal rhythm shared by pages and modal panels.
///
/// Prefer these over one-off pixel values so list density, panel chrome and
/// section gaps stay consistent across the app.
abstract final class AppSpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 22.0;
  static const xl = 28.0;
  static const xxl = 36.0;

  /// Outer inset for floating panels / sheets (compact vs wide).
  static EdgeInsets panelPadding(bool compact) => EdgeInsets.fromLTRB(
        compact ? md : lg + 4,
        compact ? md : lg,
        compact ? md : lg + 4,
        0,
      );

  /// Outer inset for full feature pages.
  static EdgeInsets pagePadding(bool compact) => EdgeInsets.fromLTRB(
        compact ? 18 : 30,
        compact ? md : lg + 4,
        compact ? 18 : 30,
        0,
      );
}
