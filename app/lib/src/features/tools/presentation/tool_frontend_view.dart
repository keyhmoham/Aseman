import 'package:flutter/material.dart';

import '../../../elpian/elpian.dart';
import '../../../genui/genui.dart'
    show
        CompactHint,
        CompactSummary,
        CompactSummaryView,
        FrontendDisplay,
        FrontendPresentation;
import '../../miniapps/presentation/miniapp_theme.dart';
import '../connect/mcp_connect_dialog.dart';
import '../data/tools_api.dart';
import '../domain/tool_models.dart';
import '../runtime/tool_frontend_host.dart';
import '../runtime/tool_media.dart';
import '../ui_kit/kit.dart' show kitEngine;

/// A tool's frontend, in a space: a static frontend runs its program on the
/// Elpian VM (bytecode) or QuickJS (source) with [ToolFrontendHost] as its
/// host; a generative one is the surface the node generated (or took from the
/// component registry) filled with this person's data, its buttons running
/// microtools through the node.
///
/// It is also what a `ToolFrontend` component of a composed widget draws, so
/// one tool's frontend can sit inside another surface.
class ToolFrontendView extends StatefulWidget {
  const ToolFrontendView({
    super.key,
    required this.api,
    required this.botId,
    required this.spaceId,
    this.roomId = '',
    this.userId = '',
    this.regenerate = false,
    this.shown,
    this.template,
    this.request = '',
    this.onLoaded,
    this.onConnected,
  });

  final ToolsApi api;
  final String botId;
  final String spaceId;
  final String roomId;
  final String userId;

  /// Generate the frontend again rather than take it from the registry (the
  /// tool's owner only).
  final bool regenerate;

  /// The result a generated frontend opens on (an agent's frontend_show).
  final ShownResult? shown;

  /// A frontend designed for one request (a desk window's own), shown
  /// instead of the tool's.
  final Map<String, dynamic>? template;

  /// What the person asked for, which a frontend generated for each request
  /// (its tool does not cache it) is designed for.
  final String request;
  final ValueChanged<ToolFrontendPayload>? onLoaded;

  /// Called once the person connected their own account to the tool here.
  final VoidCallback? onConnected;

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
        old.regenerate != widget.regenerate) {
      _load();
    }
  }

  Future<void> _load() async {
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
          if (state.auth == 'user' && !state.connected) {
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
          regenerate: widget.regenerate,
          shown: widget.shown,
          template: widget.template,
          request: widget.request);
      if (!mounted) return;
      setState(() {
        _payload = payload;
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

  Future<Map<String, dynamic>?> _action(
          GenUiAction action, Map<String, dynamic> data) =>
      widget.api.frontendAction(widget.botId, action.name,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          context: action.context,
          data: data,
          shown: widget.shown,
          // A frontend generated for this request only exists here: its
          // actions carry it back to the node.
          template: widget.template ?? _payload?.template);

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

  Widget _content(BuildContext context) {
    final display = FrontendPresentation.displayOf(context);
    final compact = display == FrontendDisplay.compact;
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      if (compact) {
        return const Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4)));
      }
      // A generated interface takes a moment the first time (every time
      // when its tool does not cache it).
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 14),
                Text('Opening…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ])));
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
        final stylesheet = MiniappTheme.stylesheet(Theme.of(context));
        final Widget program =
            payload.runtime == ToolRuntime.elpian && payload.bytecode != null
                ? ElpianVmWidget.fromBytecode(
                    machineId: machineId,
                    bytecode: payload.bytecode!,
                    engine: _engine,
                    stylesheet: stylesheet,
                    hostHandlers: host.handlers(),
                  )
                : ElpianVmWidget.fromCode(
                    machineId: machineId,
                    code: payload.source,
                    runtime: ElpianRuntime.quickJs,
                    engine: _engine,
                    stylesheet: stylesheet,
                    hostHandlers: host.handlers(),
                  );
        if (!compact) return program;
        return _StaticCompact(summary: _summary, program: program);
      case FrontendMode.generative:
        final view = GenUiView(
          messages: payload.messages,
          onAction: _action,
          toolFrontend: (context, botId, height, props) => SizedBox(
            height: height,
            child: ToolFrontendView(
                api: widget.api,
                botId: botId,
                spaceId: widget.spaceId,
                roomId: widget.roomId,
                userId: widget.userId,
                shown: ShownResult.fromProps(props)),
          ),
        );
        if (compact) return view;
        return SingleChildScrollView(
            padding: const EdgeInsets.all(16), child: view);
      case FrontendMode.none:
        if (compact) return const SizedBox.shrink();
        return const Center(child: Text('This tool has no frontend.'));
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
          const Text('Could not open the tool',
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
