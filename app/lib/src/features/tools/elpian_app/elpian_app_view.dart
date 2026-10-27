import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../data/services/aseman_service.dart';
import '../../../elpian/elpian.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../desk/presentation/frontend_presentation.dart';
import '../presentation/app_frontend_theme.dart';
import '../runtime/tool_media.dart';
import '../ui_kit/kit.dart' show kitEngine;
import 'elpian_app_host.dart';

/// An Elpian app: an App UI whose frontend is an Elpian program. Its program
/// ([entry], e.g. `elpian/app.js`) is served by the app's server through the
/// app's preview ([page], `/v1/proxy/<id>/`), and runs here natively on
/// QuickJS, drawn with the Elpian engine and the UI kit in the person's
/// theme, with [ElpianAppHost] as its host.
class ElpianAppView extends StatefulWidget {
  const ElpianAppView({
    super.key,
    required this.service,
    required this.page,
    required this.entry,
    this.spaceId = '',
    this.roomId = '',
    this.title = '',
  });

  final AsemanService service;
  final String page;
  final String entry;
  final String spaceId;
  final String roomId;
  final String title;

  @override
  State<ElpianAppView> createState() => _ElpianAppViewState();
}

class _ElpianAppViewState extends State<ElpianAppView> {
  final ElpianEngine _engine = kitEngine();
  final ElpianVmController _vm = ElpianVmController();
  ElpianAppHost? _host;
  String? _code;
  Object? _error;
  String _envSent = '';
  Map<String, dynamic> _env = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ElpianAppView old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page || old.entry != widget.entry) _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _env = _environment(context);
    // The program redraws in the new theme or display without restarting.
    final encoded = jsonEncode(_env);
    if (_code != null && _envSent.isNotEmpty && encoded != _envSent) {
      _envSent = encoded;
      _vm.callFunction('__asemanEnv', input: encoded);
    }
  }

  @override
  void dispose() {
    _host?.dispose();
    super.dispose();
  }

  String get _base => widget.service.client.baseUrl;

  Future<void> _load() async {
    setState(() {
      _code = null;
      _error = null;
    });
    _host?.dispose();
    _host = ElpianAppHost(
      baseUrl: _base,
      page: widget.page,
      headers: widget.service.authHeaders,
      env: () => _env,
      settle: (result) =>
          _vm.callFunction('__asemanSettle', input: jsonEncode(result)),
      onCompact: _onCompact,
      onExpand: () => FrontendPresentation.maybeOf(context)?.onExpand?.call(),
    );
    try {
      final page = widget.page.endsWith('/') ? widget.page : '${widget.page}/';
      final entry = widget.entry.replaceFirst(RegExp(r'^/+'), '');
      final res = await http.get(
          Uri.parse('${_base.replaceFirst(RegExp(r'/+$'), '')}$page$entry'),
          headers: widget.service.authHeaders());
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

  void _onCompact(Map<String, dynamic> summary) {
    if (!mounted) return;
    final hint = CompactHint.fromJson(summary);
    FrontendPresentation.maybeOf(context)?.onHint?.call(hint);
  }

  Map<String, dynamic> _environment(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    final session = widget.service.session;
    final presentation = FrontendPresentation.maybeOf(context);
    final display = FrontendPresentation.displayOf(context);
    return {
      'display': display.name,
      if (display == FrontendDisplay.compact)
        'widget': {
          'size': presentation?.size ?? 'medium',
          'shape': presentation?.shape ?? 'card',
        },
      'theme': {
        'mode': theme.brightness == Brightness.dark ? 'dark' : 'light',
        'accent': hex(s.primary),
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
      'user': {
        'id': session?.accountId ?? '',
        'handle': session?.handle ?? '',
      },
      'space': widget.spaceId,
      'room': widget.roomId,
      'title': widget.title,
    };
  }

  @override
  Widget build(BuildContext context) {
    final compact = FrontendPresentation.isCompact(context);
    final error = _error;
    if (error != null) {
      // A widget says it quietly; the full app explains.
      return compact
          ? Center(
              child: Icon(Icons.cloud_off_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant))
          : _AppError(error: error, onRetry: _load);
    }
    final loading = compact
        ? const Padding(
            padding: EdgeInsets.all(12),
            child: SkeletonParagraph(lines: 2, lineHeight: 10))
        : const SkeletonPage(stats: false, rows: 3);
    final code = _code;
    final host = _host;
    if (code == null || host == null) return loading;
    final program = ElpianVmScope(
      key: ValueKey('elpian-${widget.page}${widget.entry}#${identityHashCode(host)}'),
      controller: _vm,
      machineId: 'elpian-app-${widget.page}-${identityHashCode(this)}',
      code: code,
      runtime: ElpianRuntime.quickJs,
      engine: _engine,
      stylesheet: AppFrontendTheme.stylesheet(Theme.of(context)),
      hostHandlers: host.handlers(),
      loadingWidget: loading,
      errorBuilder: (e) => compact
          ? Center(
              child: Icon(Icons.error_outline_rounded,
                  color: Theme.of(context).colorScheme.error))
          : _AppError(error: e, onRetry: _load),
    );
    if (widget.spaceId.isEmpty) return program;
    // Images and media load from the space's files as this person.
    return ElpianMediaScope(
        resolver: ToolMedia.forSpace(widget.service, widget.spaceId).call,
        child: program);
  }
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
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline_rounded, color: scheme.error),
          const SizedBox(height: 8),
          const Text('Could not open the app',
              style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('$error',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ]),
      ),
    );
  }
}
