import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/theme/aseman_tokens.dart';
import '../../../core/theme/theme_pack.dart';
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
    this.onAsleep,
  });

  final AsemanService service;
  final String page;
  final String entry;
  final String spaceId;
  final String roomId;
  final String title;

  /// Wakes the app's computer when it answers 503 (a platform's frontend
  /// whose computer fell asleep) and reports whether it is up; the request
  /// is then sent again. Null: the 503 is the program's.
  final Future<bool> Function()? onAsleep;

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

  /// The size the program is drawn at (logical px), from layout.
  Size _viewport = Size.zero;

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
    _sendEnv();
  }

  /// The program redraws in the new theme, display or size without
  /// restarting.
  void _sendEnv() {
    final encoded = jsonEncode(_env);
    if (_code != null && _envSent.isNotEmpty && encoded != _envSent) {
      _envSent = encoded;
      _vm.callFunction('__decillionEnv', input: encoded);
    }
  }

  /// Called from layout with the space the program gets: a new size reaches
  /// the program after the frame (it lays itself out for phones, tablets
  /// and desk windows from `Decillion.env().viewport`).
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

  /// The viewport and its Material 3 window size class (compact < 600 ≤
  /// medium < 840 ≤ expanded).
  Map<String, dynamic> _viewportJson() {
    final w = _viewport.width, h = _viewport.height;
    return {
      'width': w,
      'height': h,
      'sizeClass': w < 600 ? 'compact' : (w < 840 ? 'medium' : 'expanded'),
      'orientation': w > h ? 'landscape' : 'portrait',
    };
  }

  @override
  void dispose() {
    _host?.dispose();
    _engine.services.dispose();
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
          _vm.callFunction('__decillionSettle', input: jsonEncode(result)),
      onCompact: _onCompact,
      onExpand: () => FrontendPresentation.maybeOf(context)?.onExpand?.call(),
      onAsleep: widget.onAsleep,
    );
    try {
      final page = widget.page.endsWith('/') ? widget.page : '${widget.page}/';
      final entry = widget.entry.replaceFirst(RegExp(r'^/+'), '');
      final url =
          Uri.parse('${_base.replaceFirst(RegExp(r'/+$'), '')}$page$entry');
      var res = await http.get(url, headers: widget.service.authHeaders());
      final asleep = widget.onAsleep;
      if (res.statusCode == 503 && asleep != null && await asleep()) {
        res = await http.get(url, headers: widget.service.authHeaders());
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

  void _onCompact(Map<String, dynamic> summary) {
    if (!mounted) return;
    final hint = CompactHint.fromJson(summary);
    FrontendPresentation.maybeOf(context)?.onHint?.call(hint);
  }

  Map<String, dynamic> _environment(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    final session = widget.service.session;
    final presentation = FrontendPresentation.maybeOf(context);
    final display = FrontendPresentation.displayOf(context);
    final partColors = <String, String>{};
    if (tokens != null) {
      for (final part in ThemePartId.values) {
        partColors[part.jsonKey] = hex(tokens.partAccent(part));
      }
    }
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
      'user': {
        'id': session?.accountId ?? '',
        'handle': session?.handle ?? '',
      },
      'space': widget.spaceId,
      'room': widget.roomId,
      'title': widget.title,
      if (_viewport != Size.zero) 'viewport': _viewportJson(),
    };
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        _layoutAt(c.biggest);
        return _content(context);
      });

  Widget _content(BuildContext context) {
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
