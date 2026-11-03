import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/aseman_tokens.dart';
import '../../../core/theme/theme_pack.dart';

/// Injects the app's colour / shape system into Elpian frontends as a JSON
/// stylesheet of semantic classes. Guest JS uses `className: 'primary'`,
/// `className: 'panel'`, … so explorers and theme panels follow the host pack
/// (including unified accent and optional part overrides).
class AppFrontendTheme {
  static String _hex(Color c) {
    final v = (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '#$v';
  }

  /// Semantic classes mapped onto the host [theme] (or [AppColors] when no
  /// theme is given). Keep the keys stable so guest bundles reference them
  /// by name.
  static Map<String, String> _tokens(ThemeData? theme) {
    final scheme = theme?.colorScheme;
    final pack = theme?.extension<AsemanTokens>();
    final bridges = pack?.bridges.elpian ?? const {};
    final accent = pack?.accent ?? scheme?.primary ?? AppColors.primary;
    final secondary = pack?.unifiedAccent == true
        ? accent
        : (pack?.cyan ?? scheme?.secondary ?? AppColors.cyan);
    final controlR = pack?.radiusControl ?? AppShape.control;
    final cardR = pack?.radiusCard ?? AppShape.card;
    final base = <String, String>{
      'bg': _hex(theme?.scaffoldBackgroundColor ?? AppColors.background),
      'nav': _hex(scheme?.surfaceContainer ?? AppColors.navigation),
      'panel': _hex(scheme?.surfaceContainerHighest ?? AppColors.panel),
      'card': _hex(scheme?.surface ?? AppColors.card),
      'border': _hex(scheme?.outlineVariant ?? AppColors.border),
      'primary': _hex(accent),
      'accent': _hex(secondary),
      'secondary': _hex(secondary),
      'success': _hex(pack?.success ?? AppColors.success),
      'warning': _hex(pack?.warning ?? AppColors.warning),
      'danger': _hex(pack?.danger ?? AppColors.danger),
      'fg': _hex(scheme?.onSurface ?? AppColors.foreground),
      'muted': _hex(scheme?.onSurfaceVariant ?? AppColors.muted),
      'onPrimary': _hex(scheme?.onPrimary ?? Colors.white),
      'radiusControl': controlR.toStringAsFixed(0),
      'radiusCard': cardR.toStringAsFixed(0),
    };
    // Part accents — guests can target .part-nav, .part-feed, …
    if (pack != null) {
      for (final part in ThemePartId.values) {
        base['part-${part.jsonKey}'] = _hex(pack.partAccent(part));
      }
    }
    for (final e in bridges.entries) {
      if (e.value.startsWith('#')) base[e.key] = e.value;
    }
    return base;
  }

  /// A JSON stylesheet (rules + shared helpers) that [ElpianVmWidget] loads
  /// via its `stylesheet` parameter. See JsonStylesheetParser.
  static Map<String, dynamic> stylesheet([ThemeData? theme]) {
    final t = _tokens(theme);
    final controlR = t['radiusControl'] ?? '16';
    final cardR = t['radiusCard'] ?? '28';
    return {
      'rules': [
        for (final entry in t.entries)
          if (entry.key.startsWith('radius'))
            {
              'selector': '.${entry.key}',
              'styles': {'borderRadius': entry.value},
            }
          else if (entry.key == 'bg' ||
              entry.key == 'nav' ||
              entry.key == 'panel' ||
              entry.key == 'card' ||
              entry.key.startsWith('part-'))
            {
              'selector': '.${entry.key}',
              'styles': {
                if (entry.key.startsWith('part-'))
                  'color': entry.value
                else
                  'backgroundColor': entry.value,
              },
            }
          else if (!entry.key.startsWith('radius'))
            {
              'selector': '.${entry.key}',
              'styles': {'color': entry.value},
            },
        {
          'selector': '.panel-card',
          'styles': {
            'backgroundColor': t['card'] ?? '',
            'borderRadius': cardR,
          },
        },
        {
          'selector': '.chip',
          'styles': {
            'backgroundColor': t['panel'] ?? '',
            'borderRadius': controlR,
          },
        },
        {
          'selector': '.btn-primary',
          'styles': {
            'backgroundColor': t['primary'] ?? '',
            'color': t['onPrimary'] ?? '#FFFFFF',
            'borderRadius': controlR,
          },
        },
        {
          'selector': '.btn-ghost',
          'styles': {
            'backgroundColor': t['panel'] ?? '',
            'color': t['fg'] ?? '',
            'borderRadius': controlR,
          },
        },
        {
          'selector': '.divider',
          'styles': {'borderColor': t['border'] ?? '', 'borderWidth': '1'},
        },
        // Fill helpers for part accents (background, not ink).
        for (final part in ThemePartId.values)
          {
            'selector': '.fill-${part.jsonKey}',
            'styles': {
              'backgroundColor': t['part-${part.jsonKey}'] ?? t['primary']!,
              'borderRadius': controlR,
            },
          },
      ],
    };
  }
}
