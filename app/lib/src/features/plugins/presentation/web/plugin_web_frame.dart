import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../tools/mcp_app/mcp_app_frame.dart';
import '../../runtime/plugin_host.dart';
import '../../runtime/plugin_runtime.dart';
import 'open_plugin_page.dart';

/// A web plugin: its HTML document in the app's sandboxed web frame (an
/// iframe with an opaque origin on the web, a web view on Android, iOS and
/// macOS), under a policy that keeps it off the network, with the bridge
/// (`Aseman.plugin`, the person's theme) answered by [host].
///
/// Where no web frame exists (Windows and Linux desktops) it offers to open
/// the page in the browser instead.
class PluginWebFrame extends StatefulWidget {
  const PluginWebFrame({
    super.key,
    required this.html,
    required this.host,
    this.display = 'full',
  });

  /// The plugin's document, as its creator wrote it.
  final String html;
  final PluginHost host;
  final String display;

  @override
  State<PluginWebFrame> createState() => _PluginWebFrameState();
}

class _PluginWebFrameState extends State<PluginWebFrame> {
  String? _bridge;
  Object? _error;

  /// The document handed to the frame, built once (theme changes are sent
  /// to the page, not reloaded).
  String? _document;
  void Function(Map<String, dynamic>)? _send;
  Size _viewport = Size.zero;
  String _envSent = '';

  @override
  void initState() {
    super.initState();
    PluginRuntime.bridge().then((b) {
      if (mounted) setState(() => _bridge = b);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  void didUpdateWidget(PluginWebFrame old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) {
      _document = null;
      _send = null;
      _envSent = '';
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The theme may have changed: tell the page (after this frame).
    WidgetsBinding.instance.addPostFrameCallback((_) => _sendEnv());
  }

  @override
  void dispose() {
    widget.host.dispose();
    super.dispose();
  }

  Map<String, dynamic> _env() => PluginRuntime.env(context,
      viewport: _viewport, display: widget.display);

  void _sendEnv() {
    final send = _send;
    if (!mounted || send == null) return;
    final env = _env();
    final encoded = jsonEncode(env);
    if (encoded == _envSent) return;
    _envSent = encoded;
    send({'aseman': 'env', 'env': env});
  }

  void _onMessage(Object? raw) {
    var message = raw;
    if (message is String) {
      try {
        message = jsonDecode(message);
      } catch (_) {
        return;
      }
    }
    if (message is! Map || message['aseman'] != 'request') return;
    final id = '${message['id'] ?? ''}';
    if (id.isEmpty) return;
    final body = message['body'] is Map
        ? (message['body'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    unawaited(widget.host.perform('${message['op'] ?? ''}', body).then((r) {
      if (!mounted) return;
      _send?.call({
        'aseman': 'settle',
        'id': id,
        'ok': r['ok'] == true,
        if (r.containsKey('data')) 'data': r['data'],
        if (r['error'] != null) 'error': '${r['error']}',
      });
    }));
  }

  Future<void> _openInBrowser() async {
    final bridge = _bridge;
    if (bridge == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final doc = PluginRuntime.webDocument(widget.html, _env(), bridge);
    final ok = await openPluginPageInBrowser(widget.host.plugin.id, doc);
    if (!ok) {
      messenger?.showSnackBar(
          const SnackBar(content: Text('Could not open the browser.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_error != null) {
      return Center(
          child: Text('Could not start this plugin: $_error',
              textAlign: TextAlign.center));
    }
    final bridge = _bridge;
    if (bridge == null) {
      return const Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (!mcpAppFrameSupported) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.public_rounded, size: 36, color: scheme.primary),
            const SizedBox(height: 10),
            Text(widget.host.plugin.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              'This plugin is made with web technology, which Aseman shows '
              'on Android, iOS, macOS and the web. Here it opens in your '
              'browser (without its saved data).',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: _openInBrowser,
              icon: const Icon(Icons.open_in_browser_rounded),
              label: const Text('Open in browser'),
            ),
          ]),
        ),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final size = Size(
          box.maxWidth.isFinite ? box.maxWidth : MediaQuery.sizeOf(context).width,
          box.maxHeight.isFinite
              ? box.maxHeight
              : MediaQuery.sizeOf(context).height);
      if (size != _viewport) {
        _viewport = size;
        WidgetsBinding.instance.addPostFrameCallback((_) => _sendEnv());
      }
      final doc = _document ??=
          PluginRuntime.webDocument(widget.html, _env(), bridge);
      return mcpAppFrame(
        key: ValueKey('plugin-web-${widget.host.plugin.id}-${doc.hashCode}'),
        html: doc,
        onMessage: _onMessage,
        onReady: (send) {
          _send = send;
          WidgetsBinding.instance.addPostFrameCallback((_) => _sendEnv());
        },
      );
    });
  }
}
