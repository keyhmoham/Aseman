import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_shape.dart';

/// What a plugin's screen runs with, the same as the plugin checker on the
/// computer (`deploy/sandbox-computer/appui/elpian/plugin-check.mjs`; the
/// shims are copies of the kit's, kept equal by its tests).
abstract final class PluginRuntime {
  static const sdkAsset = 'assets/elpian/aseman-elpian.js';
  static const shimAsset = 'assets/elpian/aseman-plugin.js';
  static const bridgeAsset = 'assets/elpian/aseman-web-plugin.js';

  /// The web frame's policy: everything inline, nothing from the network.
  /// A web plugin reaches data only through the bridge.
  static const webPolicy =
      "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' blob: data:; "
      "style-src 'unsafe-inline' data:; img-src data: blob:; font-src data:; media-src data: blob:; "
      "worker-src blob: data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'";

  static String? _sdk;
  static String? _bridge;

  /// The Aseman Elpian SDK and the plugin shim, then [program].
  static Future<String> elpianProgram(String program,
      {AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final boot = _sdk ??=
        '${await assets.loadString(sdkAsset)}\n${await assets.loadString(shimAsset)}\n';
    return '$boot$program\n';
  }

  /// The bridge a web plugin is given.
  static Future<String> bridge({AssetBundle? bundle}) async =>
      _bridge ??= await (bundle ?? rootBundle).loadString(bridgeAsset);

  /// [html] with the frame's policy, the starting [env] and [bridge] first
  /// in its head.
  static String webDocument(
      String html, Map<String, dynamic> env, String bridge) {
    final envJson = jsonEncode(env).replaceAll('<', r'<');
    final safeBridge = bridge.replaceAll(RegExp('</script', caseSensitive: false), r'<\/script');
    final inject = '<meta http-equiv="Content-Security-Policy" content="$webPolicy">'
        '<script>window.__asemanInitialEnv=$envJson;</script>'
        '<script>$safeBridge</script>';
    final head = RegExp(r'<head[^>]*>', caseSensitive: false).firstMatch(html);
    if (head != null) return html.replaceRange(head.end, head.end, inject);
    final doc = RegExp(r'<html[^>]*>', caseSensitive: false).firstMatch(html);
    if (doc != null) {
      return html.replaceRange(doc.end, doc.end, '<head>$inject</head>');
    }
    return '<!doctype html><html><head>$inject</head><body>$html</body></html>';
  }

  /// The person's theme, the display and the space the screen is drawn in,
  /// as `Aseman.env()` (Elpian) and `Aseman.env` (web) read them.
  static Map<String, dynamic> env(BuildContext context,
      {required Size viewport, String display = 'full'}) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    final w = viewport.width.isFinite ? viewport.width : 390.0;
    final h = viewport.height.isFinite ? viewport.height : 780.0;
    return {
      'display': display,
      'theme': {
        'mode': theme.brightness == Brightness.dark ? 'dark' : 'light',
        'accent': hex(s.primary),
        'radius': AppShape.cardOf(context),
        'font': theme.textTheme.bodyMedium?.fontFamily ?? 'system-ui',
        'colors': {
          'primary': hex(s.primary),
          'onPrimary': hex(s.onPrimary),
          'primaryContainer': hex(s.primaryContainer),
          'onPrimaryContainer': hex(s.onPrimaryContainer),
          'secondary': hex(s.secondary),
          'onSecondary': hex(s.onSecondary),
          'secondaryContainer': hex(s.secondaryContainer),
          'onSecondaryContainer': hex(s.onSecondaryContainer),
          'tertiary': hex(s.tertiary),
          'onTertiary': hex(s.onTertiary),
          'tertiaryContainer': hex(s.tertiaryContainer),
          'onTertiaryContainer': hex(s.onTertiaryContainer),
          'surface': hex(s.surface),
          'onSurface': hex(s.onSurface),
          'onSurfaceVariant': hex(s.onSurfaceVariant),
          'surfaceContainerLowest': hex(s.surfaceContainerLowest),
          'surfaceContainerLow': hex(s.surfaceContainerLow),
          'surfaceContainer': hex(s.surfaceContainer),
          'surfaceContainerHigh': hex(s.surfaceContainerHigh),
          'surfaceContainerHighest': hex(s.surfaceContainerHighest),
          'inverseSurface': hex(s.inverseSurface),
          'onInverseSurface': hex(s.onInverseSurface),
          'outline': hex(s.outline),
          'outlineVariant': hex(s.outlineVariant),
          'error': hex(s.error),
          'onError': hex(s.onError),
          'errorContainer': hex(s.errorContainer),
          'onErrorContainer': hex(s.onErrorContainer),
        },
      },
      'viewport': {
        'width': w,
        'height': h,
        'sizeClass': w < 600 ? 'compact' : (w < 840 ? 'medium' : 'expanded'),
        'orientation': w > h ? 'landscape' : 'portrait',
      },
    };
  }
}
