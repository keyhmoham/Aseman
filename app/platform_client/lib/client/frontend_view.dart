import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../src/core/theme/aseman_tokens.dart';
import '../src/core/theme/theme_pack.dart';
import '../src/elpian/elpian.dart';
import '../src/features/tools/elpian_app/elpian_app_host.dart';
import '../src/features/tools/presentation/app_frontend_theme.dart';
import '../src/features/tools/ui_kit/kit.dart' show kitEngine;
import '../src/shared/widgets/skeleton.dart';
import 'node_api.dart';
import 'wake.dart';

/// The platform's Elpian frontend, full screen: its program
/// (`<frontend>/<entry>`, served by the app on the platform's computer
/// through the platform's door) runs here on QuickJS, drawn with the Elpian
/// engine and the UI kit — the same engine and host as the Aseman client.
/// When the app answers 503 (its computer fell asleep) the computer is woken
/// and the request sent again.
class FrontendView extends StatefulWidget {
  const FrontendView({
    super.key,
    required this.api,
    required this.wake,
    required this.platform,
  });

  final NodeApi api;
  final WakeController wake;
  final PlatformInfo platform;

  @override
  State<FrontendView> createState() => _FrontendViewState();
}

class _FrontendViewState extends State<FrontendView> {
  final ElpianEngine _engine = kitEngine();
  final ElpianVmController _vm = ElpianVmController();
  ElpianAppHost? _host;
  String? _code;
  Object? _error;
  String _envSent = '';
  Map<String, dynamic> _env = const {};
  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _env = _environment(context);
    _sendEnv();
  }

  @override
  void dispose() {
    _host?.dispose();
    _engine.services.dispose();
    super.dispose();
  }

  void _sendEnv() {
    final encoded = jsonEncode(_env);
    if (_code != null && _envSent.isNotEmpty && encoded != _envSent) {
      _envSent = encoded;
      _vm.callFunction('__asemanEnv', input: encoded);
    }
  }

  void _layoutAt(Size size) {
    if (!size.width.isFinite || !size.height.isFinite) return;
    final rounded = Size(size.width.roundToDouble(), size.height.roundToDouble());
    if (rounded == _viewport) return;
    _viewport = rounded;
    _env = {..._env, 'viewport': _viewportJson()};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sendEnv();
    });
  }

  Map<String, dynamic> _viewportJson() {
    final w = _viewport.width, h = _viewport.height;
    return {
      'width': w,
      'height': h,
      'sizeClass': w < 600 ? 'compact' : (w < 840 ? 'medium' : 'expanded'),
      'orientation': w > h ? 'landscape' : 'portrait',
    };
  }

  String get _page => widget.api.config.frontendPath;

  Future<void> _load() async {
    setState(() {
      _code = null;
      _error = null;
    });
    _host?.dispose();
    _host = ElpianAppHost(
      baseUrl: widget.api.config.node,
      page: _page,
      headers: widget.api.authHeaders,
      env: () => _env,
      settle: (result) => _vm.callFunction('__asemanSettle', input: jsonEncode(result)),
      onAsleep: () => widget.wake.ensureAwake(force: true),
      client: _HostClient(widget.api.httpClient),
    );
    try {
      final entry = widget.platform.entry.replaceFirst(RegExp(r'^/+'), '');
      final url = Uri.parse('${widget.api.config.frontendUrl}$entry');
      final client = widget.api.httpClient;
      var res = await client.get(url, headers: widget.api.authHeaders());
      if (res.statusCode == 503 && await widget.wake.ensureAwake(force: true)) {
        res = await client.get(url, headers: widget.api.authHeaders());
      }
      if (res.statusCode == 401 && widget.api.session != null) {
        // The session ended: open the frontend as a visitor.
        await widget.api.forget();
        res = await client.get(url);
      }
      if (!mounted) return;
      if (res.statusCode != 200) {
        throw StateError('The app did not serve its program ($entry): HTTP ${res.statusCode}');
      }
      setState(() {
        _code = utf8.decode(res.bodyBytes, allowMalformed: true);
        _envSent = jsonEncode(_env);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic> _environment(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    final partColors = <String, String>{};
    if (tokens != null) {
      for (final part in ThemePartId.values) {
        partColors[part.jsonKey] = hex(tokens.partAccent(part));
      }
    }
    final session = widget.api.session;
    return {
      'display': 'full',
      'theme': {
        'mode': theme.brightness == Brightness.dark ? 'dark' : 'light',
        'accent': hex(s.primary),
        'unified': tokens?.unifiedAccent ?? true,
        'packId': tokens?.packId ?? '',
        'parts': partColors,
        'disabled': tokens?.ui.disabled.toList() ?? const <String>[],
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
          if (tokens != null) ...{
            'success': hex(tokens.success),
            'warning': hex(tokens.warning),
            'danger': hex(tokens.danger),
          },
        },
      },
      'user': {'id': session?.accountId ?? '', 'handle': session?.handle ?? ''},
      'platform': {'slug': widget.platform.slug, 'name': widget.platform.name},
      'space': '',
      'room': '',
      'title': widget.platform.title.isEmpty ? widget.platform.name : widget.platform.title,
      if (_viewport != Size.zero) 'viewport': _viewportJson(),
    };
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        _layoutAt(c.biggest);
        return _content(context);
      });

  Widget _content(BuildContext context) {
    final error = _error;
    if (error != null) return _AppError(error: error, onRetry: _load);
    const loading = SkeletonPage(stats: false, rows: 3);
    final code = _code;
    final host = _host;
    if (code == null || host == null) return loading;
    return ElpianVmScope(
      key: ValueKey('elpian-${widget.platform.slug}#${identityHashCode(host)}'),
      controller: _vm,
      machineId: 'platform-${widget.platform.slug}-${identityHashCode(this)}',
      code: code,
      runtime: ElpianRuntime.quickJs,
      engine: _engine,
      stylesheet: AppFrontendTheme.stylesheet(Theme.of(context)),
      hostHandlers: host.handlers(),
      loadingWidget: loading,
      errorBuilder: (e) => _AppError(error: e, onRetry: _load),
    );
  }
}

/// The node's connection, lent to a program's host: the host closes its
/// client when the program goes, and the connection stays open for the next.
class _HostClient extends http.BaseClient {
  _HostClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);
}

class _AppError extends StatelessWidget {
  const _AppError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline_rounded, color: scheme.error),
          const SizedBox(height: 8),
          const Text('Could not open the app', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('$error', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ]),
      ),
    );
  }
}
