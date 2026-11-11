import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/settings/app_settings.dart';
import '../../../data/services/aseman_service.dart';
import 'web/web_page_frame.dart';
import '../../../shared/widgets/glass_surface.dart';

/// The app's theme as desk App UIs take it: brightness, accent seed, Material
/// color-scheme roles, and where the page is shown. Passed on the preview URL
/// (`decillion_theme`, `decillion_accent`, `decillion_scheme`) and live via
/// `decillion:theme` / `__decillionSetTheme` when Settings change.
Map<String, dynamic> webPageTheme(
  ThemeData theme, {
  String embed = 'desk',
  Color? accent,
}) {
  String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  final s = theme.colorScheme;
  return {
    'mode': theme.brightness == Brightness.dark ? 'dark' : 'light',
    'embed': embed,
    'accent': hex(accent ?? s.primary),
    'scheme': {
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
      'error': hex(s.error),
      'onError': hex(s.onError),
      'errorContainer': hex(s.errorContainer),
      'onErrorContainer': hex(s.onErrorContainer),
      'surface': hex(s.surface),
      'onSurface': hex(s.onSurface),
      'onSurfaceVariant': hex(s.onSurfaceVariant),
      'surfaceContainerLowest': hex(s.surfaceContainerLowest),
      'surfaceContainerLow': hex(s.surfaceContainerLow),
      'surfaceContainer': hex(s.surfaceContainer),
      'surfaceContainerHigh': hex(s.surfaceContainerHigh),
      'surfaceContainerHighest': hex(s.surfaceContainerHighest),
      'outline': hex(s.outline),
      'outlineVariant': hex(s.outlineVariant),
      'inverseSurface': hex(s.inverseSurface),
      'onInverseSurface': hex(s.onInverseSurface),
      'inversePrimary': hex(s.inversePrimary),
      'background': hex(theme.scaffoldBackgroundColor),
    },
  };
}

/// The address of [page] (a preview gateway path) as the frame loads it:
/// signed in, with the app's theme for the kit to start in.
String webPageUrl(
  AsemanService service,
  String page,
  Map<String, dynamic> theme,
) {
  final base = Uri.parse(service.proxyUrl(page));
  final scheme = base64Url
      .encode(utf8.encode(jsonEncode(theme['scheme'])))
      .replaceAll('=', '');
  return base
      .replace(
        queryParameters: {
          ...base.queryParameters,
          'decillion_theme': '${theme['mode']}',
          'decillion_embed': '${theme['embed']}',
          'decillion_accent': '${theme['accent']}',
          'decillion_scheme': scheme,
        },
      )
      .toString();
}

/// A web page served from the space's sandbox (an agent's interactive
/// frontend for a tool, a site it built) inside the app: in a desk card
/// window, or full screen. It follows the app's theme live; a slim strip
/// says where it is and reloads it or opens it in the browser.
class WebPageView extends StatefulWidget {
  const WebPageView({
    super.key,
    required this.service,
    required this.page,
    this.embed = 'desk',
    this.showStrip = true,
    this.interactive = true,
    this.claimGestures = false,
  });

  final AsemanService service;

  /// The gateway path: /v1/proxy/<id>/….
  final String page;

  /// Where it is shown (desk, screen): pages may adapt their padding.
  final String embed;
  final bool showStrip;

  /// False: the page is only looked at (a live preview); taps reach the
  /// widgets around it.
  final bool interactive;

  /// Every touch on the page is its own (a remote screen inside a sheet).
  final bool claimGestures;

  @override
  State<WebPageView> createState() => _WebPageViewState();
}

class _WebPageViewState extends State<WebPageView> {
  WebPageHandle? _handle;
  bool _loading = true;
  String? _error;
  String? _url;
  Map<String, dynamic>? _theme;
  String _themeKey = '';
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = webPageTheme(
      Theme.of(context),
      embed: widget.embed,
      accent: AppSettingsScope.maybeOf(context)?.accent,
    );
    final key = jsonEncode(theme);
    if (key == _themeKey) return;
    _themeKey = key;
    _theme = theme;
    if (_url == null) {
      try {
        _url = webPageUrl(widget.service, widget.page, theme);
      } catch (_) {
        _error = 'This is not a page of the space.';
      }
    } else {
      // The page keeps its place; only its colors change.
      _handle?.setTheme(theme);
    }
  }

  void _status({bool loading = false, String? error}) {
    if (!mounted) return;
    setState(() {
      _loading = loading;
      _error = error;
    });
  }

  Future<void> _openExternal([Uri? url]) async {
    final target = url ?? Uri.parse(_url ?? '');
    try {
      if (await launchUrl(target, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not open the browser.')),
      );
    }
  }

  void _reload() {
    setState(() {
      _error = null;
      _loading = true;
    });
    if (_handle == null) {
      setState(() => _generation++);
    } else {
      _handle!.reload();
    }
  }

  /// The page's path inside its preview, for the strip.
  String get _where {
    final rest = widget.page.replaceFirst(
      RegExp(r'^/v1/proxy/[0-9a-fA-F]+'),
      '',
    );
    return rest.isEmpty ? '/' : rest;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = _url;
    Widget body;
    if (url == null || !webPageFrameSupported) {
      body = _Notice(
        icon: Icons.language_rounded,
        title: url == null ? 'Page unavailable' : 'Opens in your browser',
        text:
            _error ??
            'Web pages show in the app on the web, Android, iOS, macOS and Windows.',
        action: url == null ? null : ('Open page', () => _openExternal()),
      );
    } else {
      body = Stack(
        children: [
          Positioned.fill(
            child: webPageFrame(
              key: ValueKey('$url#$_generation'),
              url: url,
              theme: _theme ?? const {},
              onStatus: _status,
              onReady: (h) => _handle = h,
              openExternal: _openExternal,
              interactive: widget.interactive,
              claimGestures: widget.claimGestures,
            ),
          ),
          if (_loading)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(minHeight: 2.5),
            ),
          if (_error != null)
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: AppCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: _reload,
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }
    if (!widget.showStrip) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 34,
          padding: const EdgeInsets.only(left: 12, right: 2),
          color: scheme.surfaceContainer,
          child: Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _where,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Reload',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                onPressed: _reload,
                icon: const Icon(Icons.refresh_rounded),
              ),
              IconButton(
                tooltip: 'Open in the browser',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                onPressed: url == null ? null : () => _openExternal(),
                icon: const Icon(Icons.open_in_new_rounded),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });
  final IconData icon;
  final String title;
  final String text;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: scheme.primary),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: action!.$2,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text(action!.$1),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
