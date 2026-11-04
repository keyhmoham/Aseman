import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../elpian/elpian.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../desk/presentation/compact_summary.dart';
import '../../desk/presentation/frontend_presentation.dart';
import '../connect/mcp_connect_dialog.dart';
import '../data/tools_api.dart';
import '../domain/tool_models.dart';
import '../../plugins/data/plugins_api.dart';
import '../../plugins/presentation/web/plugin_web_frame.dart';
import '../../plugins/runtime/plugin_host.dart';
import '../../plugins/runtime/plugin_runtime.dart';
import '../runtime/tool_frontend_host.dart';
import '../runtime/tool_media.dart';
import '../ui_kit/kit.dart' show kitEngine;
import 'app_frontend_theme.dart';

/// A tool's frontend, in a space: a static frontend runs its program on the
/// Elpian VM (bytecode) or QuickJS (source) with [ToolFrontendHost] as its
/// host.
class ToolFrontendView extends StatefulWidget {
  const ToolFrontendView({
    super.key,
    required this.api,
    required this.botId,
    required this.spaceId,
    this.roomId = '',
    this.userId = '',
    this.shown,
    this.onLoaded,
    this.onConnected,
    this.extraHandlers = const {},
  });

  final ToolsApi api;
  final String botId;
  final String spaceId;
  final String roomId;
  final String userId;

  /// The result a static frontend opens on (microtool + args).
  final ShownResult? shown;
  final ValueChanged<ToolFrontendPayload>? onLoaded;

  /// Called once the person connected their own account to the tool here.
  final VoidCallback? onConnected;

  /// Host calls added to (or replacing) the tool host's. A plugin's screen
  /// needs none: it is given its plugin gate here (see [PluginHost]).
  final Map<String, HostCallHandler> extraHandlers;

  @override
  State<ToolFrontendView> createState() => _ToolFrontendViewState();
}

class _ToolFrontendViewState extends State<ToolFrontendView> {
  /// Renders static frontends: every Elpian node plus the UI kit's charts,
  /// tables and data views.
  final ElpianEngine _engine = kitEngine();
  ToolFrontendPayload? _payload;
  Object? _error;
  bool _loading = true;

  /// A plugin's screen: its gate, and (Elpian) its program after the SDK and
  /// the plugin shim, with the controller its answers are delivered through.
  final ElpianVmController _vm = ElpianVmController();
  PluginHost? _pluginHost;
  String? _pluginProgram;
  Map<String, dynamic> _pluginEnv = const {};
  String _pluginEnvSent = '';

  /// The name of a tool each person connects with their own account, while
  /// this person has not connected theirs in the space (null otherwise).
  String? _needsAccount;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ToolFrontendView old) {
    super.didUpdateWidget(old);
    if (old.botId != widget.botId ||
        old.spaceId != widget.spaceId ||
        old.roomId != widget.roomId) {
      _load();
    }
  }

  @override
  void dispose() {
    _pluginHost?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _pluginHost?.dispose();
    _pluginHost = null;
    _pluginProgram = null;
    _pluginEnvSent = '';
    setState(() {
      _loading = true;
      _error = null;
      _needsAccount = null;
    });
    try {
      // Anyone in the space uses a per-person tool with their own account:
      // until they connect it, its frontend would only have nothing to show.
      final service = widget.api.service;
      if (service != null && widget.spaceId.isNotEmpty) {
        try {
          final state =
              await service.toolConnection(widget.botId, widget.spaceId);
          if (personalApp(state.auth) && !state.connected) {
            if (!mounted) return;
            setState(() {
              _needsAccount = state.name.isEmpty ? 'this app' : state.name;
              _loading = false;
            });
            return;
          }
        } catch (_) {
          // Not an MCP tool, or the node could not say: open it as usual.
        }
      }
      final payload = await widget.api.frontend(widget.botId,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          shown: widget.shown);
      // An Elpian plugin runs on the Aseman Elpian SDK and the plugin shim,
      // exactly as the plugin checker ran it before it was created.
      String? program;
      if (payload.plugin != null &&
          payload.mode == FrontendMode.static &&
          payload.runtime != ToolRuntime.web &&
          !(payload.runtime == ToolRuntime.elpian && payload.bytecode != null)) {
        program = await PluginRuntime.elpianProgram(payload.source);
      }
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _pluginProgram = program;
        _loading = false;
      });
      widget.onLoaded?.call(payload);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _connect() async {
    final service = widget.api.service;
    if (service == null) return;
    final ok = await connectMcpTool(context, service,
        botId: widget.botId,
        spaceId: widget.spaceId,
        name: _needsAccount ?? 'this app');
    if (!ok || !mounted) return;
    widget.onConnected?.call();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.api.service;
    final content = _content(context);
    if (service == null || widget.spaceId.isEmpty) return content;
    // Images, videos and audio load from the space's project files, the
    // node's stored files and the node itself as this person.
    return ElpianMediaScope(
        resolver: ToolMedia.forSpace(service, widget.spaceId).call,
        child: content);
  }

  /// What a static program published for its compact widget.
  Map<String, dynamic>? _summary;

  void _onCompact(Map<String, dynamic> summary) {
    if (!mounted) return;
    setState(() => _summary = summary);
    final hint = CompactHint.fromJson(summary);
    if (!hint.isEmpty) {
      FrontendPresentation.maybeOf(context)?.onHint?.call(hint);
    }
  }

  /// The plugin's `Aseman.env()`: the theme, the display and the space it
  /// is drawn in; sent to the running program when it changes.
  void _pluginEnvFor(BuildContext context, BoxConstraints box, String display) {
    final size = Size(
        box.maxWidth.isFinite ? box.maxWidth : MediaQuery.sizeOf(context).width,
        box.maxHeight.isFinite
            ? box.maxHeight
            : MediaQuery.sizeOf(context).height);
    _pluginEnv = {
      ...PluginRuntime.env(context, viewport: size, display: display),
      'user': {'id': widget.userId},
      'space': widget.spaceId,
      'room': widget.roomId,
      'title': _payload?.title ?? '',
    };
    final encoded = jsonEncode(_pluginEnv);
    if (encoded == _pluginEnvSent) return;
    final first = _pluginEnvSent.isEmpty;
    _pluginEnvSent = encoded;
    // The program read the first env itself; later ones are news to it.
    if (!first) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _vm.callFunction('__asemanEnv', input: encoded));
    }
  }

  Widget _content(BuildContext context) {
    final display = FrontendPresentation.displayOf(context);
    final compact = display == FrontendDisplay.compact;
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      if (compact) {
        return const Padding(
            padding: EdgeInsets.all(12),
            child: SkeletonParagraph(lines: 2, lineHeight: 10));
      }
      return const SkeletonPage(stats: false, rows: 3);
    }
    final account = _needsAccount;
    if (account != null) {
      if (compact) {
        return Center(
            child: IconButton.filledTonal(
                tooltip: 'Connect your $account account',
                onPressed: _connect,
                icon: const Icon(Icons.link_off_rounded)));
      }
      return Center(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.link_off_rounded, size: 40, color: scheme.primary),
                const SizedBox(height: 12),
                Text('Connect your $account account',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(
                    'Everyone in this space uses it with their own account. Connect yours to use it here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 14),
                FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('Connect')),
              ])));
    }
    if (_error != null) {
      if (compact) {
        return Center(
            child: Icon(Icons.error_outline_rounded, color: scheme.error));
      }
      return _FrontendError(error: _error!, onRetry: _load);
    }
    final payload = _payload!;
    switch (payload.mode) {
      case FrontendMode.static:
        final host = ToolFrontendHost(widget.api,
            botId: widget.botId,
            spaceId: widget.spaceId,
            roomId: widget.roomId,
            userId: widget.userId,
            display: display.name,
            onCompact: _onCompact,
            onExpand: FrontendPresentation.maybeOf(context)?.onExpand);
        final machineId = 'tool-${widget.botId}-${identityHashCode(this)}';
        final stylesheet = AppFrontendTheme.stylesheet(Theme.of(context));
        // A plugin's screen reaches its backend and the platform through the
        // plugin gate, wherever it is opened (a gadget, a page, a desk window).
        final pluginJson = payload.plugin;
        if (pluginJson != null) {
          final gate = _pluginHost ??= PluginHost(PluginsApi(widget.api.call),
              plugin: PluginInfo.fromJson(pluginJson),
              spaceId: widget.spaceId,
              roomId: widget.roomId,
              userId: widget.userId,
              display: display.name,
              settle: (result) =>
                  _vm.callFunction('__asemanSettle', input: jsonEncode(result)),
              env: () => _pluginEnv);
          if (payload.runtime == ToolRuntime.web) {
            return PluginWebFrame(
                key: ValueKey('plugin-web-${widget.botId}'),
                html: payload.source,
                host: gate,
                display: display.name);
          }
          final program = _pluginProgram;
          if (program != null) {
            final Widget screen = LayoutBuilder(builder: (context, box) {
              _pluginEnvFor(context, box, display.name);
              return ElpianVmScope(
                controller: _vm,
                machineId: machineId,
                code: program,
                runtime: ElpianRuntime.quickJs,
                engine: _engine,
                stylesheet: stylesheet,
                hostHandlers: {
                  ...host.handlers(),
                  ...gate.handlers(),
                  ...widget.extraHandlers,
                },
              );
            });
            if (!compact) return screen;
            return _StaticCompact(summary: _summary, program: screen);
          }
        }
        // A plugin compiled to Elpian bytecode keeps its gate too.
        final bytecodeGate = _pluginHost;
        final extra = bytecodeGate != null
            ? {...bytecodeGate.handlers(), ...widget.extraHandlers}
            : widget.extraHandlers;
        final Widget program =
            payload.runtime == ToolRuntime.elpian && payload.bytecode != null
                ? ElpianVmWidget.fromBytecode(
                    machineId: machineId,
                    bytecode: payload.bytecode!,
                    engine: _engine,
                    stylesheet: stylesheet,
                    hostHandlers: {...host.handlers(), ...extra},
                  )
                : ElpianVmWidget.fromCode(
                    machineId: machineId,
                    code: payload.source,
                    runtime: ElpianRuntime.quickJs,
                    engine: _engine,
                    stylesheet: stylesheet,
                    hostHandlers: {...host.handlers(), ...extra},
                  );
        if (!compact) return program;
        return _StaticCompact(summary: _summary, program: program);
      case FrontendMode.none:
        if (compact) return const SizedBox.shrink();
        return const Center(child: Text('This app has no screen.'));
    }
  }
}

/// A static program as a compact widget: the summary it published, its own
/// render when it draws a compact UI itself (`{"view": "self"}`), else a
/// live miniature of its full render. The program keeps running under a
/// summary, so the summary stays current.
class _StaticCompact extends StatelessWidget {
  const _StaticCompact({required this.summary, required this.program});

  final Map<String, dynamic>? summary;
  final Widget program;

  @override
  Widget build(BuildContext context) {
    final self = summary?['view'] == 'self';
    final shown = summary != null && !self;
    return Stack(fit: StackFit.expand, children: [
      Offstage(
        offstage: shown,
        child: self
            ? program
            : IgnorePointer(
                child: ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                        width: DeskMiniature.width,
                        height: DeskMiniature.height,
                        child: program),
                  ),
                ),
              ),
      ),
      if (shown) CompactSummaryView(summary: CompactSummary.fromJson(summary)),
    ]);
  }
}

/// The size a frontend is drawn at for its miniature (a desk window's).
abstract final class DeskMiniature {
  static const double width = 460;
  static const double height = 560;
}

class _FrontendError extends StatelessWidget {
  const _FrontendError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
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
