import 'package:flutter/material.dart';

import '../../../elpian/elpian.dart';
import '../../miniapps/presentation/miniapp_theme.dart';
import '../data/tools_api.dart';
import '../domain/tool_models.dart';
import '../runtime/tool_frontend_host.dart';
import '../ui_kit/kit.dart' show kitEngine;
import 'a2ui_view.dart';

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
    this.onLoaded,
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
  final ValueChanged<ToolFrontendPayload>? onLoaded;

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
    });
    try {
      final payload = await widget.api.frontend(widget.botId,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          regenerate: widget.regenerate,
          shown: widget.shown,
          template: widget.template);
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

  Future<Map<String, dynamic>?> _action(
          A2UIClientAction action, Map<String, dynamic> data) =>
      widget.api.frontendAction(widget.botId, action.name,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          context: action.context,
          data: data,
          shown: widget.shown,
          template: widget.template);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      // A generated interface takes a moment the first time; it is cached
      // after that.
      final scheme = Theme.of(context).colorScheme;
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
    if (_error != null) {
      return _FrontendError(error: _error!, onRetry: _load);
    }
    final payload = _payload!;
    switch (payload.mode) {
      case FrontendMode.static:
        final host = ToolFrontendHost(widget.api,
            botId: widget.botId,
            spaceId: widget.spaceId,
            roomId: widget.roomId,
            userId: widget.userId);
        final machineId = 'tool-${widget.botId}-${identityHashCode(this)}';
        final stylesheet = MiniappTheme.stylesheet(Theme.of(context));
        if (payload.runtime == ToolRuntime.elpian && payload.bytecode != null) {
          return ElpianVmWidget.fromBytecode(
            machineId: machineId,
            bytecode: payload.bytecode!,
            engine: _engine,
            stylesheet: stylesheet,
            hostHandlers: host.handlers(),
          );
        }
        return ElpianVmWidget.fromCode(
          machineId: machineId,
          code: payload.source,
          runtime: ElpianRuntime.quickJs,
          engine: _engine,
          stylesheet: stylesheet,
          hostHandlers: host.handlers(),
        );
      case FrontendMode.generative:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: A2UIView(
            messages: payload.messages,
            onAction: _action,
            toolFrontend: (context, botId, height, shown) => SizedBox(
              height: height,
              child: ToolFrontendView(
                  api: widget.api,
                  botId: botId,
                  spaceId: widget.spaceId,
                  roomId: widget.roomId,
                  userId: widget.userId,
                  shown: shown),
            ),
          ),
        );
      case FrontendMode.none:
        return const Center(child: Text('This tool has no frontend.'));
    }
  }
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
