import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Injects the app's color system into elpian miniapp frontends as a JSON
/// stylesheet of semantic classes. The guest JS uses `className: 'primary'`,
/// `className: 'panel'`, … so the explorer (or any miniapp) automatically
/// follows the host app's theme without baking hex values into the bundle.
class MiniappTheme {
  static String _hex(Color c) {
    final v = (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '#$v';
  }

  /// Semantic classes mapped onto the host [theme] (or [AppColors] when no
  /// theme is given), so a miniapp follows the light/dark mode and accent of
  /// the app around it. Keep the keys stable so guest bundles reference them
  /// by name.
  static Map<String, String> _tokens(ThemeData? theme) {
    final scheme = theme?.colorScheme;
    return {
      'bg': _hex(theme?.scaffoldBackgroundColor ?? AppColors.background),
      'nav': _hex(scheme?.surfaceContainer ?? AppColors.navigation),
      'panel': _hex(scheme?.surfaceContainerHighest ?? AppColors.panel),
      'card': _hex(scheme?.surface ?? AppColors.card),
      'border': _hex(scheme?.outlineVariant ?? AppColors.border),
      'primary': _hex(scheme?.primary ?? AppColors.primary),
      'accent': _hex(AppColors.cyan),
      'success': _hex(AppColors.success),
      'warning': _hex(AppColors.warning),
      'danger': _hex(AppColors.danger),
      'fg': _hex(scheme?.onSurface ?? AppColors.foreground),
      'muted': _hex(scheme?.onSurfaceVariant ?? AppColors.muted),
    };
  }

  /// A JSON stylesheet (rules + shared text/padding helpers) that [ElpianVmWidget]
  /// loads via its `stylesheet` parameter. See JsonStylesheetParser.
  static Map<String, dynamic> stylesheet([ThemeData? theme]) {
    final t = _tokens(theme);
    return {
      'rules': [
        for (final entry in t.entries)
          if (entry.key == 'bg' ||
              entry.key == 'nav' ||
              entry.key == 'panel' ||
              entry.key == 'card')
            {
              'selector': '.${entry.key}',
              'styles': {'backgroundColor': entry.value},
            }
          else
            {
              'selector': '.${entry.key}',
              'styles': {'color': entry.value},
            },
        // Convenience combos used by the file explorer.
        {
          'selector': '.panel-card',
          'styles': {'backgroundColor': t['card'] ?? '', 'borderRadius': '10'},
        },
        {
          'selector': '.chip',
          'styles': {'backgroundColor': t['panel'] ?? '', 'borderRadius': '8'},
        },
        {
          'selector': '.btn-primary',
          'styles': {
            'backgroundColor': t['primary'] ?? '',
            'color': _hex(theme?.colorScheme.onPrimary ?? Colors.white),
            'borderRadius': '8'
          },
        },
        {
          'selector': '.btn-ghost',
          'styles': {
            'backgroundColor': t['panel'] ?? '',
            'color': t['fg'] ?? '',
            'borderRadius': '8'
          },
        },
        {
          'selector': '.divider',
          'styles': {'borderColor': t['border'] ?? '', 'borderWidth': '1'},
        },
      ],
    };
  }
}
