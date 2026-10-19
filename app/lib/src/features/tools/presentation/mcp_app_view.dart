import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/tools_api.dart';
import '../mcp_app/mcp_app_frame.dart';
import '../mcp_app/mcp_app_host.dart';

/// Builds the frame an app runs in (the platform's; tests pass their own).
typedef McpAppFrameBuilder = Widget Function({
  Key? key,
  required String html,
  required void Function(Object? message) onMessage,
  required void Function(void Function(Map<String, dynamic>) send) onReady,
});

/// A tool's result shown with the tool's own app (MCP Apps): the ui://
/// HTML app its microtool declares, run sandboxed on this device, given the
/// call's arguments and its result, its own calls going to its server
/// through the node as this person.
class McpAppView extends StatefulWidget {
  const McpAppView({
    super.key,
    required this.api,
    required this.botId,
    required this.spaceId,
    required this.microtool,
    this.roomId = '',
    this.args = const {},
    this.frame,
  });

  final ToolsApi api;
  final String botId;
  final String spaceId;
  final String roomId;
  final String microtool;
  final Map<String, dynamic> args;
  final McpAppFrameBuilder? frame;

  @override
  State<McpAppView> createState() => _McpAppViewState();
}

class _McpAppViewState extends State<McpAppView> {
  String? _html;
  Object? _error;
  McpAppHost? _host;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(McpAppView old) {
    super.didUpdateWidget(old);
    if (old.botId != widget.botId ||
        old.microtool != widget.microtool ||
        jsonEncode(old.args) != jsonEncode(widget.args)) {
      _load();
    }
  }

  @override
  void dispose() {
    _host?.teardown();
    super.dispose();
  }

  Future<Map<String, dynamic>> _rpc(
          String method, Map<String, dynamic> params) =>
      widget.api.appRpc(widget.botId, method,
          spaceId: widget.spaceId, roomId: widget.roomId, params: params);

  /// The app's HTML from a resources/read result.
  static String? htmlOf(Map<String, dynamic> resource) {
    final contents = resource['contents'];
    if (contents is! List) return null;
    for (final c in contents) {
      if (c is! Map) continue;
      final mime = '${c['mimeType'] ?? ''}';
      if (mime.isNotEmpty && !mime.startsWith('text/html')) continue;
      final text = c['text'];
      if (text is String && text.isNotEmpty) return text;
      final blob = c['blob'];
      if (blob is String && blob.isNotEmpty) {
        return utf8.decode(base64.decode(blob), allowMalformed: true);
      }
    }
    return null;
  }

  Future<void> _load() async {
    _host?.teardown();
    setState(() {
      _html = null;
      _error = null;
      _host = null;
    });
    try {
      final app = await _rpc('app', {'microtool': widget.microtool});
      final resource = app['resource'] is Map
          ? (app['resource'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final html = htmlOf(resource);
      if (html == null) throw StateError('the app sent nothing to show');
      if (!mounted) return;
      setState(() {
        _html = html;
        _attempt++;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _ready(void Function(Map<String, dynamic>) send) {
    final theme = Theme.of(context);
    _host = McpAppHost(
      send: send,
      rpc: _rpc,
      arguments: widget.args,
      // The result the app shows is the call's, made again for this window.
      result: _rpc(
          'tools/call', {'name': widget.microtool, 'arguments': widget.args}),
      theme: theme.brightness == Brightness.dark ? 'dark' : 'light',
      platform: theme.platform == TargetPlatform.android ||
              theme.platform == TargetPlatform.iOS
          ? 'mobile'
          : 'web',
      locale: Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'en',
      openLink: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline_rounded, color: scheme.error),
            const SizedBox(height: 8),
            const Text('The app could not open',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('$_error',
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }
    final html = _html;
    if (html == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final build = widget.frame ?? mcpAppFrame;
    // Apps draw on a light page of their own unless told otherwise.
    return ColoredBox(
      color: Colors.white,
      child: build(
        key: ValueKey(_attempt),
        html: html,
        onMessage: (m) => _host?.receive(m),
        onReady: _ready,
      ),
    );
  }
}
