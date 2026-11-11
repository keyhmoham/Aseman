import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/theme/aseman_tokens.dart';
import '../../core/theme/theme_elpian_host.dart';
import '../../core/theme/theme_elpian_sdk.dart';
import '../../core/theme/theme_pack.dart';
import '../../core/theme/theme_runtime_scope.dart';
import '../../core/theme/theme_ui_spec.dart';
import '../../data/services/aseman_service.dart';
import '../../elpian/elpian.dart';
import '../../features/desk/presentation/frontend_presentation.dart';
import '../../features/tools/presentation/app_frontend_theme.dart';
import '../../features/tools/ui_kit/kit.dart';

/// Renders a theme Elpian source: static JSON tree and/or a live QuickJS
/// program with the full theme host (`Decillion.env` / `Decillion.api` / core API).
class ThemeElpianSurface extends StatefulWidget {
  const ThemeElpianSurface({
    super.key,
    required this.source,
    this.slot = '',
    this.hostChild,
    this.padding,
    this.spaceId = '',
    this.roomId = '',
  });

  final ThemeElpianSource source;
  final String slot;
  final Widget? hostChild;
  final EdgeInsetsGeometry? padding;
  final String spaceId;
  final String roomId;

  @override
  State<ThemeElpianSurface> createState() => _ThemeElpianSurfaceState();
}

class _ThemeElpianSurfaceState extends State<ThemeElpianSurface> {
  late final ElpianEngine _engine = kitEngine();
  final ElpianVmController _vm = ElpianVmController();
  ThemeElpianHost? _host;
  String? _program;
  Object? _error;
  bool _hostRegistered = false;
  bool _programLoadStarted = false;
  String _envSent = '';
  Map<String, dynamic> _env = const {};
  Size _viewport = Size.zero;

  @override
  void didUpdateWidget(covariant ThemeElpianSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.code != widget.source.code ||
        oldWidget.source.program != widget.source.program ||
        oldWidget.source.sdk != widget.source.sdk) {
      _programLoadStarted = false;
      if (widget.source.hasProgram) {
        unawaited(_loadProgram());
      } else {
        setState(() {
          _program = null;
          _error = null;
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureHostChild();
    _engine.loadStylesheet(AppFrontendTheme.stylesheet(Theme.of(context)));
    _env = _environment(context);
    _sendEnv();
    if (widget.source.hasProgram && !_programLoadStarted) {
      _programLoadStarted = true;
      unawaited(_loadProgram());
    }
  }

  @override
  void dispose() {
    _host?.dispose();
    _engine.services.dispose();
    super.dispose();
  }

  void _ensureHostChild() {
    if (_hostRegistered) return;
    _hostRegistered = true;
    Widget buildHost(ElpianNode node, List<Widget> children) {
      final host = widget.hostChild;
      if (host != null) return host;
      if (children.isNotEmpty) {
        return children.length == 1
            ? children.first
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              );
      }
      return const SizedBox.shrink();
    }

    _engine.registerWidget('ThemeHostChild', buildHost);
    _engine.registerWidget('HostChild', buildHost);
    _engine.registerWidget('theme_host_child', buildHost);
  }

  Future<void> _loadProgram() async {
    final service = ThemeRuntimeScope.serviceOf(context);
    setState(() {
      _program = null;
      _error = null;
    });
    _host?.dispose();
    _host = null;
    try {
      var source = widget.source.code.trim();
      final path = widget.source.program.trim();
      if (source.isEmpty && path.isNotEmpty) {
        source = await _fetchProgram(path, service);
      }
      if (source.isEmpty) {
        throw StateError('theme panel has no program source');
      }
      final wrapped =
          await ThemeElpianSdk.wrapProgram(source, sdk: widget.source.sdk);
      if (!mounted) return;
      final svc = service;
      if (svc == null) {
        throw StateError(
          'ThemeRuntimeScope / AsemanService required for live theme panels',
        );
      }
      _host = ThemeElpianHost(
        service: svc,
        slot: widget.slot,
        spaceId: widget.spaceId,
        roomId: widget.roomId,
        env: () => _env,
        settle: (result) =>
            _vm.callFunction('__decillionSettle', input: jsonEncode(result)),
      );
      setState(() {
        _program = wrapped;
        _envSent = jsonEncode(_env);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<String> _fetchProgram(String path, AsemanService? service) async {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final headers = service?.authHeaders() ?? const <String, String>{};
      final res = await http.get(Uri.parse(path), headers: headers);
      if (res.statusCode != 200) {
        throw StateError('theme program HTTP ${res.statusCode}');
      }
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    }
    final asset = path.startsWith('assets/') ? path : 'assets/$path';
    return rootBundle.loadString(asset);
  }

  void _sendEnv() {
    final encoded = jsonEncode(_env);
    if (_program != null && _envSent.isNotEmpty && encoded != _envSent) {
      _envSent = encoded;
      _vm.callFunction('__decillionEnv', input: encoded);
    }
  }

  void _layoutAt(Size size) {
    if (!size.width.isFinite || !size.height.isFinite) return;
    final rounded =
        Size(size.width.roundToDouble(), size.height.roundToDouble());
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
      'sizeClass': w < 600
          ? 'compact'
          : (w < 840 ? 'medium' : 'expanded'),
      'orientation': w > h ? 'landscape' : 'portrait',
    };
  }

  Map<String, dynamic> _environment(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final tokens = AsemanTokens.maybeOf(context);
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    final session = ThemeRuntimeScope.serviceOf(context)?.session;
    final display = FrontendPresentation.displayOf(context);
    final partColors = <String, String>{};
    if (tokens != null) {
      for (final part in ThemePartId.values) {
        partColors[part.jsonKey] = hex(tokens.partAccent(part));
      }
    }
    return {
      'display': display.name,
      'kind': 'theme',
      'slot': widget.slot,
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
          'surface': hex(s.surface),
          'onSurface': hex(s.onSurface),
          'onSurfaceVariant': hex(s.onSurfaceVariant),
          'outline': hex(s.outline),
          'error': hex(s.error),
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
      if (_viewport != Size.zero) 'viewport': _viewportJson(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _layoutAt(constraints.biggest);
      Widget body;
      if (widget.source.hasProgram) {
        body = _programBody(context);
      } else if (widget.source.hasInline) {
        _ensureHostChild();
        body = _engine.renderFromJson(widget.source.inline!);
      } else {
        body = const SizedBox.shrink();
      }
      if (widget.padding == null) return body;
      return Padding(padding: widget.padding!, child: body);
    });
  }

  Widget _programBody(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'Theme panel failed: $error',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
        ),
      );
    }
    final code = _program;
    final host = _host;
    if (code == null || host == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        )),
      );
    }
    return ElpianVmScope(
      key: ValueKey('theme-panel-${widget.slot}-${identityHashCode(host)}'),
      controller: _vm,
      machineId: 'theme-${widget.slot}-${identityHashCode(this)}',
      code: code,
      runtime: ElpianRuntime.quickJs,
      engine: _engine,
      stylesheet: AppFrontendTheme.stylesheet(Theme.of(context)),
      hostHandlers: host.handlers(),
      errorBuilder: (e) => Text(
        e,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}
